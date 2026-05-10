import PhotosUI
import SwiftUI
import UIKit
import Vision

struct CameraCaptureView: UIViewControllerRepresentable {
    var onImage: (UIImage) -> Void
    var onCancel: () -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onImage: onImage, onCancel: onCancel)
    }

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        private let onImage: (UIImage) -> Void
        private let onCancel: () -> Void

        init(onImage: @escaping (UIImage) -> Void, onCancel: @escaping () -> Void) {
            self.onImage = onImage
            self.onCancel = onCancel
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage {
                onImage(image)
            } else {
                onCancel()
            }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onCancel()
        }
    }
}

enum OCRScanner {
    struct ScanResult {
        var text: String
        var diagnostics: OCRDiagnostics
    }

    static func text(from image: UIImage) async throws -> String {
        try await scan(image: image).text
    }

    static func scan(image: UIImage) async throws -> ScanResult {
        guard let cgImage = image.cgImage else {
            throw OCRScannerError.invalidImage
        }

        if #available(iOS 26.0, *) {
            do {
                let result = try await documentText(from: cgImage)
                if !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return result
                }
                return try await legacyText(from: cgImage, fallbackReason: "Vision document OCR returned no text.")
            } catch {
                return try await legacyText(from: cgImage, fallbackReason: error.localizedDescription)
            }
        }

        return try await legacyText(from: cgImage, fallbackReason: "iOS 26 Vision document OCR is unavailable.")
    }

    private static func legacyText(from cgImage: CGImage, fallbackReason: String?) async throws -> ScanResult {
        return try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                let observations = request.results as? [VNRecognizedTextObservation] ?? []
                let lines = observations.compactMap(OCRTextLine.init(observation:))
                let text = OCRLayoutFormatter.formattedText(from: lines)
                continuation.resume(
                    returning: ScanResult(
                        text: text,
                        diagnostics: OCRDiagnostics(
                            engine: "VNRecognizeTextRequest",
                            fallbackReason: fallbackReason
                        )
                    )
                )
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true

            let handler = VNImageRequestHandler(cgImage: cgImage)
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    @available(iOS 26.0, *)
    private static func documentText(from cgImage: CGImage) async throws -> ScanResult {
        var request = RecognizeDocumentsRequest()
        request.textRecognitionOptions.automaticallyDetectLanguage = true
        request.textRecognitionOptions.useLanguageCorrection = true
        request.textRecognitionOptions.maximumCandidateCount = 1

        let observations = try await ImageRequestHandler(cgImage).perform(request)
        return OCRDocumentFormatter.formattedResult(from: observations)
    }
}

struct OCRTextLine {
    var text: String
    var boundingBox: CGRect

    init?(observation: VNRecognizedTextObservation) {
        guard let candidate = observation.topCandidates(1).first else { return nil }
        let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        self.text = text
        self.boundingBox = observation.boundingBox
    }
}

enum OCRLayoutFormatter {
    static func formattedText(from lines: [OCRTextLine]) -> String {
        let rows = groupedRows(from: lines)
        return rows
            .map(formatRow)
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private static func groupedRows(from lines: [OCRTextLine]) -> [[OCRTextLine]] {
        let sorted = lines.sorted { lhs, rhs in
            let lhsMidY = lhs.boundingBox.midY
            let rhsMidY = rhs.boundingBox.midY
            if abs(lhsMidY - rhsMidY) > 0.015 {
                return lhsMidY > rhsMidY
            }
            return lhs.boundingBox.minX < rhs.boundingBox.minX
        }

        var rows: [[OCRTextLine]] = []
        for line in sorted {
            if let index = rows.firstIndex(where: { isSameRow(line, row: $0) }) {
                rows[index].append(line)
                rows[index].sort { $0.boundingBox.minX < $1.boundingBox.minX }
            } else {
                rows.append([line])
            }
        }
        return rows
    }

    private static func isSameRow(_ line: OCRTextLine, row: [OCRTextLine]) -> Bool {
        guard let first = row.first else { return false }
        let rowHeight = max(first.boundingBox.height, line.boundingBox.height, 0.015)
        return abs(first.boundingBox.midY - line.boundingBox.midY) <= rowHeight * 0.65
    }

    private static func formatRow(_ row: [OCRTextLine]) -> String {
        let sorted = row.sorted { $0.boundingBox.minX < $1.boundingBox.minX }
        guard sorted.count > 1 else {
            return sorted.first?.text ?? ""
        }

        let spread = (sorted.last?.boundingBox.maxX ?? 0) - (sorted.first?.boundingBox.minX ?? 0)
        if spread > 0.45 {
            return sorted.map(\.text).joined(separator: " | ")
        }
        return sorted.map(\.text).joined(separator: " ")
    }
}

@available(iOS 26.0, *)
enum OCRDocumentFormatter {
    static func formattedText(from observations: [DocumentObservation]) -> String {
        formattedResult(from: observations).text
    }

    static func formattedResult(from observations: [DocumentObservation]) -> OCRScanner.ScanResult {
        let tableCount = observations.reduce(0) { $0 + $1.document.tables.count }
        let tableRowCount = observations.reduce(0) { total, observation in
            total + observation.document.tables.reduce(0) { $0 + $1.rows.count }
        }

        let text = formattedTextOnly(from: observations)
        return OCRScanner.ScanResult(
            text: text,
            diagnostics: OCRDiagnostics(
                engine: "RecognizeDocumentsRequest",
                documentCount: observations.count,
                tableCount: tableCount,
                tableRowCount: tableRowCount
            )
        )
    }

    private static func formattedTextOnly(from observations: [DocumentObservation]) -> String {
        observations
            .map { formattedDocument($0.document) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    private static func formattedDocument(_ document: DocumentObservation.Container) -> String {
        let transcript = document.text.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let tables = document.tables
            .map(formatTable)
            .filter { !$0.isEmpty }

        if tables.isEmpty {
            return transcript
        }

        return ([transcript] + tables)
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private static func formatTable(_ table: DocumentObservation.Container.Table) -> String {
        table.rows
            .map { row in
                row.map { text(from: $0.content) }
                    .filter { !$0.isEmpty }
                    .joined(separator: " | ")
            }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private static func text(from container: DocumentObservation.Container) -> String {
        container.text.transcript
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
    }
}

enum OCRScannerError: LocalizedError {
    case invalidImage

    var errorDescription: String? {
        "The selected image could not be prepared for OCR."
    }
}
