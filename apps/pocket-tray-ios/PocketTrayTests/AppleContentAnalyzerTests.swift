import UIKit
import NaturalLanguage
import XCTest
@testable import PocketTray

final class AppleContentAnalyzerTests: XCTestCase {
    func testVisionRequestAutomaticallyDetectsLanguage() {
        let request = AppleContentAnalyzer.makeRecognitionRequest()

        XCTAssertTrue(request.automaticallyDetectsLanguage)
        XCTAssertTrue(request.usesLanguageCorrection)
        XCTAssertEqual(request.recognitionLevel, .accurate)
    }

    func testRuntimeReportsOCRLanguagesAndEntityCapabilities() throws {
        let request = AppleContentAnalyzer.makeRecognitionRequest()
        let languages = try request.supportedRecognitionLanguages()
        let englishSchemes = NLTagger.availableTagSchemes(for: .word, language: .english)

        XCTAssertTrue(languages.allSatisfy { !$0.isEmpty })
        XCTAssertEqual(
            AppleContentAnalyzer.supportsNamedEntities(languageCode: "en"),
            englishSchemes.contains(.nameType)
        )
        XCTAssertFalse(AppleContentAnalyzer.supportsNamedEntities(languageCode: nil))
    }

    func testFixtureTranslationCoversOCRLanguageEntitiesAndActions() throws {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let fixture = AppleAnalysisFixture(
            recognizedText: ["Receipt from Orchard Cafe", "Call +65 6123 4567"],
            languageCode: "en",
            entities: [
                AppleEntityFixture(kind: .organization, value: "Orchard Cafe"),
                AppleEntityFixture(kind: .person, value: "Pallav"),
                AppleEntityFixture(kind: .place, value: "Singapore")
            ],
            detectedValues: [
                AppleDetectedValue(kind: .url, value: "https://example.com"),
                AppleDetectedValue(kind: .phone, value: "+65 6123 4567"),
                AppleDetectedValue(kind: .address, value: "1 Orchard Road, Singapore"),
                AppleDetectedValue(kind: .date, value: "15 January 2027", date: date),
                AppleDetectedValue(kind: .trackingNumber, value: "1Z999AA10123456784")
            ]
        )

        let result = AppleAnalysisTranslator.translate(
            fixture,
            itemText: "Receipt photo"
        )

        XCTAssertEqual(
            result.searchableText,
            "Receipt photo\nReceipt from Orchard Cafe\nCall +65 6123 4567"
        )
        XCTAssertEqual(result.languageCode, "en")
        XCTAssertEqual(result.entities, [
            ContentEntity(kind: .organization, value: "Orchard Cafe"),
            ContentEntity(kind: .person, value: "Pallav"),
            ContentEntity(kind: .place, value: "Singapore")
        ])
        XCTAssertEqual(result.actions.map(\.kind), [
            .url, .phone, .address, .date, .trackingNumber
        ])
        XCTAssertEqual(result.actions[0].target, "https://example.com")
        XCTAssertEqual(result.actions[1].target, "tel:+6561234567")
        XCTAssertTrue(try XCTUnwrap(result.actions[2].target).hasPrefix("http://maps.apple.com/"))
        XCTAssertEqual(result.actions[3].target, "calshow:821692800")
        XCTAssertTrue(try XCTUnwrap(result.actions[4].target).contains("1Z999AA10123456784"))
    }

    func testTranslationNormalizesAndDeduplicatesFrameworkResults() {
        let fixture = AppleAnalysisFixture(
            recognizedText: ["  Hello   world  ", "Hello world"],
            languageCode: nil,
            entities: [
                AppleEntityFixture(kind: .person, value: "  Jane Doe "),
                AppleEntityFixture(kind: .person, value: "Jane Doe")
            ],
            detectedValues: [
                AppleDetectedValue(kind: .url, value: "https://example.com"),
                AppleDetectedValue(kind: .url, value: "https://example.com")
            ]
        )

        let result = AppleAnalysisTranslator.translate(fixture, itemText: "Title")

        XCTAssertEqual(result.searchableText, "Title\nHello world")
        XCTAssertEqual(result.entities.count, 1)
        XCTAssertEqual(result.actions.count, 1)
    }

    func testImageAdapterKeepsBaseTextInSearchIndex() async throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 160)).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 400, height: 160))
            ("Pocket Tray" as NSString).draw(
                at: CGPoint(x: 30, y: 50),
                withAttributes: [.font: UIFont.systemFont(ofSize: 42)]
            )
        }
        let data = try XCTUnwrap(image.pngData())

        let result = try await AppleContentAnalyzer().analyze(
            ContentAnalysisInput(
                itemID: UUID(),
                kind: .image,
                text: "Reference image",
                assetData: data,
                assetTypeIdentifier: "public.png"
            )
        )

        XCTAssertTrue(result.searchableText?.contains("Reference image") == true)
        XCTAssertTrue(
            result.searchableText?.localizedCaseInsensitiveContains("Pocket Tray") == true
        )
    }
}
