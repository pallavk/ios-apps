import Foundation
import SwiftData

@Model
final class SavedScan {
    var id: UUID
    var createdAt: Date
    var title: String
    var ocrText: String
    var imageReference: String?
    var summary: String

    init(
        id: UUID = UUID(),
        createdAt: Date = .now,
        title: String,
        ocrText: String,
        imageReference: String? = nil,
        summary: String
    ) {
        self.id = id
        self.createdAt = createdAt
        self.title = title
        self.ocrText = ocrText
        self.imageReference = imageReference
        self.summary = summary
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
    var summary = "Analyze a corrected OCR label to see nutrition, ingredients, and warnings."
    var isLoading = false
    var errorMessage: String?
    var imageReference: String?
    var analysis: LabelAnalysis?
}
