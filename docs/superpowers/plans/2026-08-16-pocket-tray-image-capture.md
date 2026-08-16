# Pocket Tray Image Capture Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Capture shared images and screenshots, preserve and export their original bytes, show safe previews, enforce a 25 MB limit, and deduplicate identical images.

**Architecture:** Extend `TrayItem` with immutable asset metadata and keep original bytes in a content-addressed `assets` directory beside `tray.json`. The repository writes and verifies assets before committing metadata; the share extension and later camera/photo adapters feed the same `ImagePayload` boundary. The app reads verified assets through `Tray` and generates bounded ImageIO thumbnails for SwiftUI.

**Tech Stack:** Swift 6, SwiftUI, UIKit share extension, Foundation, CryptoKit, ImageIO, UniformTypeIdentifiers, XCTest, coordinated JSON persistence.

## Global Constraints

- iOS deployment target remains 18.0.
- Original image bytes are immutable and must be exported byte-for-byte.
- Reject payloads larger than exactly 25,000,000 bytes before durable mutation.
- Only final files named by their SHA-256 digest are readable assets; temporary files are never records.
- Metadata must never point to a missing asset because of a failed capture transaction.
- Existing text/URL data and behavior remain backward compatible.
- Direct camera/photo-library UI, OCR, compression, editing, AI, video, audio, cloud sync, and orphan cleanup are out of scope.

---

## File Structure

- Create `apps/pocket-tray-ios/PocketTray/ImageAsset.swift`: image payload, immutable asset metadata, validation, digesting, and asset-resource types shared by app and extension.
- Create `apps/pocket-tray-ios/PocketTray/AssetStore.swift`: atomic content-addressed file writes and verified reads shared by repositories.
- Create `apps/pocket-tray-ios/PocketTray/TrayImageViews.swift`: bounded thumbnail loading, image row content, full preview, and original-file export UI for the app target.
- Create `apps/pocket-tray-ios/PocketTrayTests/ImageCaptureTests.swift`: image-specific domain, persistence, share, and failure tests.
- Modify `apps/pocket-tray-ios/PocketTray/Tray.swift`: image kind/capture, asset-aware deduplication, repository mutation, and asset access.
- Modify `apps/pocket-tray-ios/PocketTray/TrayPersistence.swift`: asset store composition and failure-safe metadata ordering.
- Modify `apps/pocket-tray-ios/PocketTray/ShareCapture.swift`: image-capable provider contract and image-first capture routing.
- Modify `apps/pocket-tray-ios/PocketTrayShare/ShareViewController.swift`: `NSItemProvider` image loading without app-side transcoding.
- Modify `apps/pocket-tray-ios/PocketTrayShare/Info.plist`: advertise one shared image.
- Modify `apps/pocket-tray-ios/PocketTray/RootView.swift`: route image rows to preview/export and keep metadata editing safe.
- Modify `apps/pocket-tray-ios/PocketTray.xcodeproj/project.pbxproj`: add shared and target-specific source files.

---

### Task 1: Image Domain, Validation, and Deduplication

**Files:**
- Create: `apps/pocket-tray-ios/PocketTray/ImageAsset.swift`
- Modify: `apps/pocket-tray-ios/PocketTray/Tray.swift`
- Create: `apps/pocket-tray-ios/PocketTrayTests/ImageCaptureTests.swift`
- Modify: `apps/pocket-tray-ios/PocketTray.xcodeproj/project.pbxproj`

**Interfaces:**
- Produces: `ImagePayload`, `TrayAsset`, `TrayAssetWrite`, `TrayAssetResource`, `ImageAssetFactory.makeWrite(from:)`, `CaptureContent.image`, `TrayItem.asset`, and `Tray.assetResource(for:)`.
- Consumes: existing `TrayMutation.capture`, `TrayItem` lifecycle/dedup behavior, and `TrayRepository`.

- [ ] **Step 1: Add a valid image fixture and write failing validation tests**

Use a deterministic one-pixel PNG fixture and explicit boundary cases:

```swift
private let onePixelPNG = Data(base64Encoded:
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
)!

func testImagePayloadProducesImmutableDigestMetadata() throws {
    let write = try ImageAssetFactory.makeWrite(
        from: ImagePayload(data: onePixelPNG, typeIdentifier: "public.png", filename: "shot.png")
    )
    XCTAssertEqual(write.asset.byteCount, onePixelPNG.count)
    XCTAssertEqual(write.asset.typeIdentifier, "public.png")
    XCTAssertEqual(write.asset.fileExtension, "png")
    XCTAssertEqual(write.data, onePixelPNG)
    XCTAssertEqual(write.asset.digest.count, 64)
}

func testImagePayloadRejectsMoreThanTwentyFiveMillionBytes() {
    let payload = ImagePayload(
        data: Data(repeating: 0, count: 25_000_001),
        typeIdentifier: "public.png",
        filename: nil
    )
    XCTAssertThrowsError(try ImageAssetFactory.makeWrite(from: payload)) {
        XCTAssertEqual($0 as? TrayAssetError, .tooLarge(maximumBytes: 25_000_000))
    }
}

func testImagePayloadAcceptsExactlyTwentyFiveMillionBytes() throws {
    var paddedPNG = onePixelPNG
    paddedPNG.append(Data(repeating: 0, count: 25_000_000 - onePixelPNG.count))
    let write = try ImageAssetFactory.makeWrite(
        from: ImagePayload(data: paddedPNG, typeIdentifier: "public.png", filename: "limit.png")
    )
    XCTAssertEqual(write.asset.byteCount, 25_000_000)
}

func testImagePayloadRejectsDeclaredImageWithInvalidBytes() {
    XCTAssertThrowsError(try ImageAssetFactory.makeWrite(
        from: ImagePayload(data: Data("not an image".utf8), typeIdentifier: "public.png", filename: nil)
    )) {
        XCTAssertEqual($0 as? TrayAssetError, .invalidImage)
    }
}
```

- [ ] **Step 2: Add the new test file and shared source reference to the Xcode project, then run red tests**

Run:

```bash
xcodebuild test -quiet \
  -project apps/pocket-tray-ios/PocketTray.xcodeproj \
  -scheme PocketTray \
  -destination 'platform=iOS Simulator,id=1BAC358A-1B96-4132-870E-FF7A3DC29791' \
  -only-testing:PocketTrayTests/ImageCaptureTests \
  CODE_SIGNING_ALLOWED=NO
```

Expected: compilation fails because the image domain types do not exist.

- [ ] **Step 3: Implement image payload validation and immutable metadata**

Create these concrete types in `ImageAsset.swift`:

```swift
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct ImagePayload: Equatable, Sendable {
    let data: Data
    let typeIdentifier: String
    let filename: String?
}

struct TrayAsset: Codable, Equatable, Sendable {
    let digest: String
    let byteCount: Int
    let typeIdentifier: String
    let fileExtension: String
    let originalFilename: String?
}

struct TrayAssetWrite: Equatable, Sendable {
    let asset: TrayAsset
    let data: Data
}

struct TrayAssetResource: Equatable, Sendable {
    let asset: TrayAsset
    let url: URL
    let data: Data
}

enum TrayAssetError: Error, Equatable, LocalizedError {
    case corrupt
    case invalidImage
    case missing
    case tooLarge(maximumBytes: Int)
    case unsupportedType
}

enum ImageAssetFactory {
    static let maximumByteCount = 25_000_000
    static func makeWrite(from payload: ImagePayload) throws -> TrayAssetWrite
    static func digest(of data: Data) -> String
    static func validate(_ data: Data, as asset: TrayAsset) throws
}
```

`makeWrite` must check non-empty data, `UTType(...).conforms(to: .image)`, `data.count <= maximumByteCount`, and a non-empty `CGImageSource`. Use lowercase hexadecimal SHA-256 and `UTType.preferredFilenameExtension ?? "img"`.

- [ ] **Step 4: Extend the Tray domain and write failing dedup tests**

Add `.image(ImagePayload)` to `CaptureContent`, `.image` to `TrayItemKind`, and `asset: TrayAsset?` to `TrayItem` with backward-compatible decoding. Change the mutation case to `case capture(TrayItem, assetWrite: TrayAssetWrite?)`, while `TrayStore.apply` continues to persist only the item metadata.

Write:

```swift
func testIdenticalImagesDeduplicateAndPreserveMetadata() async throws {
    let repository = InMemoryTrayRepository()
    let firstTray = Tray(repository: repository, now: { Date(timeIntervalSince1970: 1_000) })
    let original = try await firstTray.capture(.image(
        ImagePayload(data: onePixelPNG, typeIdentifier: "public.png", filename: "first.png")
    ))
    let collection = try await firstTray.createCollection(named: "Screenshots")
    _ = try await firstTray.edit(
        original.id,
        text: original.text,
        title: "Keep title",
        note: "Keep note",
        collectionID: collection.id
    )
    _ = try await firstTray.setPinned(original.id, to: true)

    let secondTray = Tray(repository: repository, now: { Date(timeIntervalSince1970: 2_000) })
    let recaptured = try await secondTray.capture(.image(
        ImagePayload(data: onePixelPNG, typeIdentifier: "public.png", filename: "second.png")
    ))

    XCTAssertEqual(recaptured.id, original.id)
    XCTAssertEqual(recaptured.title, "Keep title")
    XCTAssertEqual(recaptured.note, "Keep note")
    XCTAssertEqual(recaptured.collectionID, collection.id)
    XCTAssertTrue(recaptured.isPinned)
    XCTAssertEqual((try await secondTray.recent()).count, 1)
}
```

For image items, use the asset digest as the initial deduplication key. `TrayItem.applying` must preserve `.image`, its display text, and its asset while still updating title, note, and collection.

- [ ] **Step 5: Run the image tests and full regression suite**

Run the targeted command from Step 2, then run the same command without `-only-testing`. Expected: all prior 34 tests plus the new image tests pass.

- [ ] **Step 6: Commit the independently working domain slice**

```bash
git add apps/pocket-tray-ios/PocketTray/ImageAsset.swift \
  apps/pocket-tray-ios/PocketTray/Tray.swift \
  apps/pocket-tray-ios/PocketTrayTests/ImageCaptureTests.swift \
  apps/pocket-tray-ios/PocketTray.xcodeproj/project.pbxproj
git commit -m 'Add Pocket Tray image domain (#6)'
```

---

### Task 2: Durable Content-Addressed Asset Storage

**Files:**
- Create: `apps/pocket-tray-ios/PocketTray/AssetStore.swift`
- Modify: `apps/pocket-tray-ios/PocketTray/Tray.swift`
- Modify: `apps/pocket-tray-ios/PocketTray/TrayPersistence.swift`
- Modify: `apps/pocket-tray-ios/PocketTrayTests/ImageCaptureTests.swift`
- Modify: `apps/pocket-tray-ios/PocketTray.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `TrayAssetWrite`, `TrayAssetResource`, `ImageAssetFactory.validate`, and `TrayMutation.capture(TrayItem, assetWrite: TrayAssetWrite?)`.
- Produces: `AssetStore.persist(_:)`, `AssetStore.resource(for:)`, and repository `resource(for:)` support.

- [ ] **Step 1: Write failing relaunch, over-limit, and missing/corrupt asset tests**

Use a temporary `tray.json` and its sibling `assets` directory:

```swift
func testOriginalImageBytesSurviveRepositoryRelaunch() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let fileURL = root.appending(path: "tray.json")
    let first = Tray(repository: FileTrayRepository(fileURL: fileURL))
    let item = try await first.capture(.image(
        ImagePayload(data: onePixelPNG, typeIdentifier: "public.png", filename: "original.png")
    ))

    let second = Tray(repository: FileTrayRepository(fileURL: fileURL))
    let resource = try await second.assetResource(for: item)
    XCTAssertEqual(resource.data, onePixelPNG)
    XCTAssertEqual((try await second.recent()).first?.id, item.id)
}

func testMissingAndCorruptAssetsRemainRecordsButCannotBeRead() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let tray = Tray(repository: FileTrayRepository(fileURL: root.appending(path: "tray.json")))
    let item = try await tray.capture(.image(
        ImagePayload(data: onePixelPNG, typeIdentifier: "public.png", filename: "shot.png")
    ))
    let asset = try XCTUnwrap(item.asset)
    let assetURL = root.appending(path: "assets/\(asset.digest).\(asset.fileExtension)")

    try FileManager.default.removeItem(at: assetURL)
    do {
        _ = try await tray.assetResource(for: item)
        XCTFail("Expected a missing-asset error")
    } catch {
        XCTAssertEqual(error as? TrayAssetError, .missing)
    }
    XCTAssertEqual((try await tray.recent()).map(\.id), [item.id])

    try onePixelPNG.write(to: assetURL)
    try Data(onePixelPNG.prefix(8)).write(to: assetURL)
    do {
        _ = try await tray.assetResource(for: item)
        XCTFail("Expected a corrupt-asset error")
    } catch {
        XCTAssertEqual(error as? TrayAssetError, .corrupt)
    }
    XCTAssertEqual((try await tray.recent()).map(\.id), [item.id])
}
```

Add a `RejectingAssetWriter` that throws `CocoaError(.fileWriteOutOfSpace)` and assert capture throws, `recent()` is empty, and no final digest file exists. Add an `InterruptedAssetWriter` that creates only a `.tmp` sibling then throws; assert the same no-record/no-final-file outcome.

- [ ] **Step 2: Run targeted tests and verify red behavior**

Run the Task 1 targeted test command. Expected: compile failures for `AssetStore`, repository asset reads, and writer injection.

- [ ] **Step 3: Implement atomic writes and verified reads**

Create:

```swift
protocol AssetDataWriting: Sendable {
    func write(_ data: Data, to finalURL: URL) throws
}

struct AtomicAssetDataWriter: AssetDataWriting {
    func write(_ data: Data, to finalURL: URL) throws {
        let temporaryURL = finalURL.deletingLastPathComponent()
            .appending(path: ".\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        try data.write(to: temporaryURL, options: .withoutOverwriting)
        try FileManager.default.moveItem(at: temporaryURL, to: finalURL)
    }
}

struct AssetStore: Sendable {
    let directoryURL: URL
    let writer: any AssetDataWriting
    func persist(_ write: TrayAssetWrite) throws
    func resource(for asset: TrayAsset) throws -> TrayAssetResource
    func url(for asset: TrayAsset) -> URL
}
```

`persist` creates the directory, treats an already-valid final digest file as success, writes a new file atomically otherwise, then verifies byte count, digest, and image decodability. If a write races and fails because another process created the final file, accept only a valid final file; otherwise propagate the original error.

- [ ] **Step 4: Compose the asset store into repositories with safe ordering**

Add to `TrayRepository`:

```swift
func resource(for asset: TrayAsset) async throws -> TrayAssetResource
```

In both file and in-memory repositories, intercept `.capture(_, assetWrite: .some(let write))`, call `assetStore.persist(write)` first, and only then call `store.apply(mutation)`. `FileTrayRepository` defaults the asset directory to `fileURL.deletingLastPathComponent().appending(path: "assets")`; allow writer injection in tests. `UnavailableTrayRepository` throws the existing storage-unavailable error.

Implement:

```swift
func assetResource(for item: TrayItem) async throws -> TrayAssetResource {
    guard let asset = item.asset else { throw TrayAssetError.missing }
    return try await repository.resource(for: asset)
}
```

- [ ] **Step 5: Run targeted and complete tests**

Expected: relaunch bytes compare exactly, missing/corrupt reads fail without deleting metadata, simulated out-of-space and interrupted writes create no records, and all text-only persistence tests remain green.

- [ ] **Step 6: Commit the durable storage slice**

```bash
git add apps/pocket-tray-ios/PocketTray/AssetStore.swift \
  apps/pocket-tray-ios/PocketTray/Tray.swift \
  apps/pocket-tray-ios/PocketTray/TrayPersistence.swift \
  apps/pocket-tray-ios/PocketTrayTests/ImageCaptureTests.swift \
  apps/pocket-tray-ios/PocketTray.xcodeproj/project.pbxproj
git commit -m 'Persist Pocket Tray image assets (#6)'
```

---

### Task 3: Share Extension Image Input

**Files:**
- Modify: `apps/pocket-tray-ios/PocketTray/ShareCapture.swift`
- Modify: `apps/pocket-tray-ios/PocketTrayShare/ShareViewController.swift`
- Modify: `apps/pocket-tray-ios/PocketTrayShare/Info.plist`
- Modify: `apps/pocket-tray-ios/PocketTrayTests/ImageCaptureTests.swift`

**Interfaces:**
- Consumes: `ImagePayload` and `ShareCapture.capture(_:)`.
- Produces: `ShareItemProviding.canLoadImage` and `loadImage()` with image-first routing.

- [ ] **Step 1: Write failing share-provider tests**

```swift
private struct ImageShareProvider: ShareItemProviding {
    let payload: ImagePayload
    var canLoadImage: Bool { true }
    var canLoadURL: Bool { true }
    var canLoadText: Bool { true }
    func loadImage() async throws -> ImagePayload { payload }
    func loadURL() async throws -> URL { URL(string: "https://wrong.example")! }
    func loadText() async throws -> String { "wrong" }
}

func testShareCapturePrefersImageRepresentation() async throws {
    let tray = Tray(repository: InMemoryTrayRepository())
    let item = try await ShareCapture(tray: tray).capture(ImageShareProvider(
        payload: ImagePayload(data: onePixelPNG, typeIdentifier: "public.png", filename: "shot.png")
    ))
    XCTAssertEqual(item.kind, .image)
    XCTAssertEqual(item.asset?.typeIdentifier, "public.png")
}
```

Also test that PNG and JPEG payloads route as images, and that a provider image-load failure maps to `ShareCaptureError.unreadable` and creates no object. Generate the JPEG fixture in the test with `UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).image { UIColor.red.setFill(); $0.fill(CGRect(x: 0, y: 0, width: 2, height: 2)) }.jpegData(compressionQuality: 1)!`; exported bytes must still equal that generated fixture exactly.

- [ ] **Step 2: Run the targeted tests and verify failure**

Expected: the provider protocol and image route are missing.

- [ ] **Step 3: Extend the provider abstraction and image-first routing**

Add `canLoadImage` and `loadImage()` to `ShareItemProviding`. Provide default protocol-extension implementations returning `false` and throwing `.unsupported` so existing text stubs remain concise. In `ShareCapture.capture`, check image, then URL, then text.

- [ ] **Step 4: Implement `NSItemProvider` image loading and activation**

Select the first registered type identifier whose `UTType` conforms to `.image`. Load that representation with `loadDataRepresentation(forTypeIdentifier:)`, retain the registered identifier and suggested name, and pass bytes directly into `ImagePayload`. Do not create a `UIImage`, render, compress, or re-encode in the extension.

Add to `NSExtensionActivationRule`:

```xml
<key>NSExtensionActivationSupportsImageWithMaxCount</key>
<integer>1</integer>
```

Update unsupported copy to mention images, text, and web links.

- [ ] **Step 5: Run tests and build both app and extension**

Run the full test suite, then:

```bash
xcodebuild build -quiet \
  -project apps/pocket-tray-ios/PocketTray.xcodeproj \
  -scheme PocketTray \
  -destination 'platform=iOS Simulator,id=1BAC358A-1B96-4132-870E-FF7A3DC29791' \
  CODE_SIGNING_ALLOWED=NO
```

Expected: tests and both targets build.

- [ ] **Step 6: Commit the share adapter slice**

```bash
git add apps/pocket-tray-ios/PocketTray/ShareCapture.swift \
  apps/pocket-tray-ios/PocketTrayShare/ShareViewController.swift \
  apps/pocket-tray-ios/PocketTrayShare/Info.plist \
  apps/pocket-tray-ios/PocketTrayTests/ImageCaptureTests.swift
git commit -m 'Capture shared images in Pocket Tray (#6)'
```

---

### Task 4: Safe Preview and Full-Fidelity Export

**Files:**
- Create: `apps/pocket-tray-ios/PocketTray/TrayImageViews.swift`
- Modify: `apps/pocket-tray-ios/PocketTray/RootView.swift`
- Modify: `apps/pocket-tray-ios/PocketTray/Tray.swift`
- Modify: `apps/pocket-tray-ios/PocketTrayTests/ImageCaptureTests.swift`
- Modify: `apps/pocket-tray-ios/PocketTray.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `Tray.assetResource(for:)`, `TrayAssetResource`, and existing item metadata/lifecycle actions.
- Produces: `TrayImageLoader.thumbnail(for:tray:maxPixelSize:)`, `TrayImageRow`, and `TrayImageDetailView`.

- [ ] **Step 1: Write failing bounded-thumbnail and original-export tests**

Test that the loader returns a non-zero `UIImage` whose largest pixel dimension is no greater than the requested bound. Test that the detail/export resource's `Data(contentsOf: resource.url)` equals `onePixelPNG` exactly. Test missing and corrupt resources produce the unavailable state through a small, testable loader state enum rather than crashing.

- [ ] **Step 2: Run targeted tests and verify red behavior**

Expected: loader/view support types are absent.

- [ ] **Step 3: Implement bounded ImageIO loading outside the main actor**

Create:

```swift
enum TrayImageLoadState {
    case loading
    case loaded(UIImage, URL)
    case unavailable(String)
}

enum TrayImageLoader {
    static func thumbnail(
        for item: TrayItem,
        tray: Tray,
        maxPixelSize: Int
    ) async throws -> (UIImage, URL)
}
```

Read and verify through `tray.assetResource(for:)`, then use `CGImageSourceCreateThumbnailAtIndex` with `kCGImageSourceThumbnailMaxPixelSize`, `kCGImageSourceCreateThumbnailFromImageAlways`, and transform options inside `Task.detached`. Never decode a full-resolution image merely to draw a row thumbnail.

- [ ] **Step 4: Add image row, preview, export, and metadata-safe editing**

For `.image` rows, show a 72-point aspect-fill thumbnail, title or source filename, note, collection, pin, and lifecycle label. Tapping opens `TrayImageDetailView`, which loads a larger bounded preview and exposes `ShareLink(item: originalURL)` only after verified loading. Missing/corrupt assets show `ContentUnavailableView("Image unavailable", ...)` and no share action.

Keep pin/trash/restore/delete actions identical to text objects. The editor hides the content `TextEditor` for images and edits only title, note, and collection. At the domain boundary, `TrayItem.applying` preserves image kind, display text, and asset even if a caller supplies text edits.

- [ ] **Step 5: Run tests, install on Simulator, and visually inspect**

Build to a fresh DerivedData directory, install with `simctl`, launch, seed an image through a test/debug route or share sheet, and inspect a screenshot with `view_image`. Verify recognizable thumbnail, preview, Share action, Dynamic Type layout, and unavailable placeholder.

- [ ] **Step 6: Commit the UI slice**

```bash
git add apps/pocket-tray-ios/PocketTray/TrayImageViews.swift \
  apps/pocket-tray-ios/PocketTray/RootView.swift \
  apps/pocket-tray-ios/PocketTray/Tray.swift \
  apps/pocket-tray-ios/PocketTrayTests/ImageCaptureTests.swift \
  apps/pocket-tray-ios/PocketTray.xcodeproj/project.pbxproj
git commit -m 'Preview and export Pocket Tray images (#6)'
```

---

### Task 5: Final Verification, Review, Push, and Closure

**Files:**
- Modify only files required by review findings.

**Interfaces:**
- Consumes: all prior tasks and GitHub issue #6 acceptance criteria.
- Produces: verified remote commit and closed issue #6.

- [ ] **Step 1: Run the fresh complete test suite with an xcresult bundle**

```bash
result_root=$(mktemp -d /private/tmp/PocketTrayIssue6Tests.XXXXXX)
xcodebuild test -quiet \
  -project apps/pocket-tray-ios/PocketTray.xcodeproj \
  -scheme PocketTray \
  -destination 'platform=iOS Simulator,id=1BAC358A-1B96-4132-870E-FF7A3DC29791' \
  -resultBundlePath "$result_root/Tests.xcresult" \
  CODE_SIGNING_ALLOWED=NO
xcrun xcresulttool get test-results summary \
  --path "$result_root/Tests.xcresult" --format json
```

Expected: zero failed or skipped tests.

- [ ] **Step 2: Build signed app bundles for Zeus and Simulator**

Use device destination `00008120-000E542A0A40201E`, install with `devicectl` device `C6EFA610-2CC2-5143-82C3-D445C2F6CBCD`, build/install on the named simulator, and visually inspect the settled UI.

- [ ] **Step 3: Run two-axis review**

Request a spec reviewer against every issue #6 acceptance criterion and a standards reviewer against repository boundaries, cross-process safety, memory behavior, error mapping, and Swift concurrency. Fix all spec findings and hard standards findings, then rerun tests/builds and both reviews.

- [ ] **Step 4: Verify scope and commit any review fixes**

```bash
git status -sb
git diff --check
git diff --stat
git add apps/pocket-tray-ios docs/superpowers
git diff --cached --check
git commit -m 'Complete Pocket Tray image capture (#6)'
```

Skip the final commit if no review fix remains. Confirm the worktree contains no unrelated files.

- [ ] **Step 5: Push and verify the remote head**

```bash
git push origin main
git rev-parse HEAD
git ls-remote origin refs/heads/main
gh api repos/pallavk/ios-apps/commits/main --jq '.sha + " " + .commit.message'
```

All three SHA values must match.

- [ ] **Step 6: Close issue #6 with evidence and continue automatically**

Comment with the test count, signed build/install results, review outcome, and commit SHA; close the issue; verify its state through `gh issue view 6 --json state,closedAt,url`; then claim the next ready dependency without waiting for user instruction.
