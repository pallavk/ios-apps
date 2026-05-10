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
    static func text(from image: UIImage) async throws -> String {
        guard let cgImage = image.cgImage else {
            throw OCRScannerError.invalidImage
        }

        return try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                let observations = request.results as? [VNRecognizedTextObservation] ?? []
                let lines = observations.compactMap(OCRTextLine.init(observation:))
                let text = OCRLayoutFormatter.formattedText(from: lines)
                continuation.resume(returning: text)
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

enum OCRScannerError: LocalizedError {
    case invalidImage

    var errorDescription: String? {
        "The selected image could not be prepared for OCR."
    }
}
