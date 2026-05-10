import Foundation
import SwiftData

@Model
final class SavedScan {
    var id: UUID
    var createdAt: Date
    var title: String
    var ocrText: String
    var imageReference: String?
    var imageFileName: String?
    var summary: String

    init(
        id: UUID = UUID(),
        createdAt: Date = .now,
        title: String,
        ocrText: String,
        imageReference: String? = nil,
        imageFileName: String? = nil,
        summary: String
    ) {
        self.id = id
        self.createdAt = createdAt
        self.title = title
        self.ocrText = ocrText
        self.imageReference = imageReference
        self.imageFileName = imageFileName
        self.summary = summary
    }

    var storedImageURL: URL? {
        guard let imageFileName else { return nil }
        return LabelImageStore.url(for: imageFileName)
    }
}

enum AppTab: String, CaseIterable, Identifiable {
    case home
    case scan
    case results
    case preferences
    case history

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "Home"
        case .scan: "Scan"
        case .results: "Results"
        case .preferences: "Preferences"
        case .history: "History"
        }
    }

    var systemImage: String {
        switch self {
        case .home: "house"
        case .scan: "camera.viewfinder"
        case .results: "list.bullet.rectangle"
        case .preferences: "slider.horizontal.3"
        case .history: "clock"
        }
    }
}

struct AnalysisDraft {
    var ocrText = ""
    var ocrDiagnostics: OCRDiagnostics?
    var summary = "Analyze a corrected OCR label to see nutrition, ingredients, and warnings."
    var isLoading = false
    var errorMessage: String?
    var imageReference: String?
    var imageData: Data?
    var savedCaptureDraftID: UUID?
    var analysis: LabelAnalysis?
}

struct OCRDiagnostics {
    var engine: String
    var documentCount: Int = 0
    var tableCount: Int = 0
    var tableRowCount: Int = 0
    var fallbackReason: String?

    var displayRows: [(String, String)] {
        var rows = [
            ("Engine", engine),
            ("Documents", "\(documentCount)"),
            ("Tables", "\(tableCount)"),
            ("Table rows", "\(tableRowCount)"),
        ]
        if let fallbackReason {
            rows.append(("Fallback", fallbackReason))
        }
        return rows
    }
}

enum ScanTitleFormatter {
    static func title(prefix: String, date: Date = .now) -> String {
        "\(prefix) \(date.formatted(.dateTime.month(.abbreviated).day().hour().minute()))"
    }
}

enum LabelImageStore {
    static func saveJPEGData(_ data: Data, id: UUID = UUID()) throws -> String {
        let fileName = "\(id.uuidString).jpg"
        let url = try imageDirectoryURL().appending(path: fileName)
        try data.write(to: url, options: [.atomic])
        return fileName
    }

    static func url(for fileName: String) -> URL? {
        try? imageDirectoryURL().appending(path: fileName)
    }

    private static func imageDirectoryURL() throws -> URL {
        let baseURL = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directoryURL = baseURL.appending(path: "LabelImages", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return directoryURL
    }
}

enum LabelExportStore {
    static func writeOCRText(for scan: SavedScan) throws -> URL {
        let safeTitle = scan.title
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        let fileName = "\(safeTitle.isEmpty ? "label-scan" : safeTitle)-\(scan.id.uuidString).txt"
        let url = FileManager.default.temporaryDirectory.appending(path: fileName)
        try scan.ocrText.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
