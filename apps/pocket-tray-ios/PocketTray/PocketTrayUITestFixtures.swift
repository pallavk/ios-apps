import Foundation
import UIKit
import UniformTypeIdentifiers

enum PocketTrayUITestFixtures {
    @MainActor
    static func repository() -> InMemoryTrayRepository {
        let now = Date.now
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
        let earlier = calendar.date(byAdding: .day, value: -3, to: today)!
        let secondsIntoToday = now.timeIntervalSince(today)
        func todayDate(secondsAgo: TimeInterval) -> Date {
            today.addingTimeInterval(max(0, secondsIntoToday - secondsAgo))
        }
        let assetDirectory = FileManager.default.temporaryDirectory
            .appending(path: "PocketTrayUITestContent", directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: assetDirectory)
        let assetStore = AssetStore(directoryURL: assetDirectory)
        let imageWrite = try! ImageAssetFactory.makeWrite(
            from: ImagePayload(
                data: imageData(),
                typeIdentifier: UTType.png.identifier,
                filename: "coastline.png"
            )
        )
        let pdfWrite = try! PDFAssetFactory.makeWrite(
            from: PDFPayload(
                data: pdfData(),
                typeIdentifier: UTType.pdf.identifier,
                filename: "trip-notes.pdf"
            )
        )
        try! assetStore.persist(imageWrite)
        try! assetStore.persist(pdfWrite)
        let collectionID = UUID(uuidString: "C011EC71-0000-4000-8000-000000000001")!
        let collection = TrayCollection(
            id: collectionID,
            name: "Projects",
            createdAt: calendar.date(byAdding: .day, value: -10, to: today)!
        )
        let travelID = UUID(uuidString: "C011EC71-0000-4000-8000-000000000002")!
        let travel = TrayCollection(
            id: travelID,
            name: "Travel",
            createdAt: calendar.date(byAdding: .day, value: -8, to: today)!
        )
        let inbox = TrayCollection(
            id: UUID(uuidString: "C011EC71-0000-4000-8000-000000000003")!,
            name: "Inbox",
            createdAt: calendar.date(byAdding: .day, value: -6, to: today)!
        )
        let items = [
            TrayItem(
                id: UUID(uuidString: "17E00000-0000-4000-8000-000000000001")!,
                text: "Book the morning ferry, pack sunscreen, and check the weather before leaving.",
                capturedAt: todayDate(secondsAgo: 720),
                title: "Ideas for the weekend"
            ),
            TrayItem(
                id: UUID(uuidString: "17E00000-0000-4000-8000-000000000002")!,
                kind: .url,
                text: "https://developer.apple.com/design/human-interface-guidelines/",
                capturedAt: todayDate(secondsAgo: 3_600),
                title: "SwiftUI design guidance"
            ),
            TrayItem(
                id: UUID(uuidString: "17E00000-0000-4000-8000-000000000003")!,
                kind: .image,
                text: "coastline.png",
                capturedAt: todayDate(secondsAgo: 20_000),
                title: "Bintan coastline",
                collectionID: travelID,
                asset: imageWrite.asset
            ),
            TrayItem(
                id: UUID(uuidString: "17E00000-0000-4000-8000-000000000004")!,
                kind: .pdf,
                text: "trip-notes.pdf",
                capturedAt: yesterday.addingTimeInterval(12 * 3_600),
                title: "Trip notes",
                collectionID: travelID,
                asset: pdfWrite.asset
            ),
            TrayItem(
                id: UUID(uuidString: "17E00000-0000-4000-8000-000000000005")!,
                text: "Temporary marker layout over the tennis court",
                capturedAt: yesterday.addingTimeInterval(10 * 3_600),
                isPinned: true,
                title: "Pickleball court setup",
                collectionID: collectionID
            ),
            TrayItem(
                id: UUID(uuidString: "17E00000-0000-4000-8000-000000000006")!,
                text: "Verification code: 739201",
                capturedAt: earlier.addingTimeInterval(14 * 3_600),
                title: "Account verification",
                sensitivity: SensitivityAssessment(reasons: [.oneTimeCode])
            ),
            TrayItem(
                id: UUID(uuidString: "17E00000-0000-4000-8000-000000000007")!,
                kind: .image,
                text: "missing-receipt.png",
                capturedAt: earlier.addingTimeInterval(12 * 3_600),
                title: "Missing receipt",
                asset: TrayAsset(
                    digest: String(repeating: "0", count: 64),
                    byteCount: 1,
                    typeIdentifier: UTType.png.identifier,
                    fileExtension: "png",
                    originalFilename: "missing-receipt.png"
                )
            ),
            TrayItem(
                id: UUID(uuidString: "17E00000-0000-4000-8000-000000000008")!,
                text: "护照、充电器、药品、耳机 · Passport, charger, medication, headphones",
                capturedAt: earlier.addingTimeInterval(10 * 3_600),
                title: "Travel checklist · 旅行清单",
                collectionID: travelID
            )
        ]
        return InMemoryTrayRepository(
            items: items,
            collections: [collection, travel, inbox],
            assetDirectoryURL: assetDirectory
        )
    }

    @MainActor
    private static func imageData() -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 360, height: 240))
        return renderer.image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 360, height: 150))
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 150, width: 360, height: 90))
            UIColor.systemYellow.setFill()
            context.cgContext.fillEllipse(in: CGRect(x: 250, y: 28, width: 58, height: 58))
        }.pngData()!
    }

    @MainActor
    private static func pdfData() -> Data {
        let bounds = CGRect(x: 0, y: 0, width: 420, height: 594)
        return UIGraphicsPDFRenderer(bounds: bounds).pdfData { context in
            context.beginPage()
            NSString(string: "Pocket Tray\nTrip notes")
                .draw(
                    in: CGRect(x: 36, y: 44, width: 348, height: 120),
                    withAttributes: [.font: UIFont.preferredFont(forTextStyle: .title1)]
                )
        }
    }
}
