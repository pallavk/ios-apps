import AVFoundation
import Foundation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct DirectCaptureDetails: Equatable, Sendable {
    static let empty = DirectCaptureDetails()

    let title: String?
    let note: String?
    let collectionID: UUID?

    init(title: String? = nil, note: String? = nil, collectionID: UUID? = nil) {
        self.title = Self.nonBlank(title)
        self.note = Self.nonBlank(note)
        self.collectionID = collectionID
    }

    private static func nonBlank(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return value
    }
}

struct DirectCaptureService: Sendable {
    let tray: Tray

    func capture(
        _ content: CaptureContent?,
        details: DirectCaptureDetails = .empty,
        acknowledgingSensitiveContent: Bool = false
    ) async throws -> TrayItem? {
        guard let content else { return nil }
        let prepared = try tray.prepareCapture(content)
        let item = prepared.item.applying(
            TrayItemEdits(
                kind: prepared.item.kind,
                text: prepared.item.text,
                title: details.title,
                note: details.note,
                collectionID: details.collectionID,
                sensitivity: prepared.item.sensitivity
            )
        )
        return try await tray.commit(
            PreparedTrayCapture(item: item, assetWrite: prepared.assetWrite),
            acknowledgingSensitiveContent: acknowledgingSensitiveContent
        )
    }
}

enum DirectPhotoLoader {
    static func load(_ selection: PhotosPickerItem) async throws -> CaptureContent {
        guard let data = try await selection.loadTransferable(type: Data.self) else {
            throw TrayAssetError.invalidImage
        }
        let type = selection.supportedContentTypes.first(where: { $0.conforms(to: .image) }) ?? .image
        return .image(
            ImagePayload(data: data, typeIdentifier: type.identifier, filename: nil)
        )
    }
}

@MainActor
enum CameraAccess {
    static var isAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }

    static func requestIfNeeded() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            true
        case .notDetermined:
            await AVCaptureDevice.requestAccess(for: .video)
        case .denied, .restricted:
            false
        @unknown default:
            false
        }
    }
}

struct DirectTextComposer: View {
    @Environment(\.dismiss) private var dismiss

    let service: DirectCaptureService
    let collections: [TrayCollection]
    let onSaved: (TrayItem) async -> Void

    @State private var text = ""
    @State private var title = ""
    @State private var note = ""
    @State private var collectionID: UUID?
    @State private var showsDetails = false
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var isConfirmingSensitiveContent = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Text") {
                    TextEditor(text: $text)
                        .frame(minHeight: 160)
                        .accessibilityLabel("New text")
                }
                Section {
                    DisclosureGroup("Add details", isExpanded: $showsDetails) {
                        TextField("Title", text: $title)
                        TextField("Note", text: $note, axis: .vertical)
                            .lineLimit(2...5)
                        Picker("Collection", selection: $collectionID) {
                            Text("None").tag(UUID?.none)
                            ForEach(collections) { collection in
                                Text(collection.name).tag(Optional(collection.id))
                            }
                        }
                    }
                }
            }
            .navigationTitle("New Text")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Saving…" : "Save") {
                        Task { await save() }
                    }
                    .disabled(
                        isSaving || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                }
            }
        }
        .alert("Couldn't save that text", isPresented: isShowingError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "Please try again.")
        }
        .confirmationDialog(
            "Save possible sensitive content?",
            isPresented: $isConfirmingSensitiveContent,
            titleVisibility: .visible
        ) {
            Button("Save Anyway") { Task { await save(acknowledgingSensitiveContent: true) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Pocket Tray found a possible secret. Save it only if you intend to keep it here.")
        }
    }

    private var isShowingError: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    }

    private func save(acknowledgingSensitiveContent: Bool = false) async {
        isSaving = true
        defer { isSaving = false }
        do {
            let item = try await service.capture(
                .text(text),
                details: DirectCaptureDetails(
                    title: title,
                    note: note,
                    collectionID: collectionID
                ),
                acknowledgingSensitiveContent: acknowledgingSensitiveContent
            )
            if let item {
                await onSaved(item)
                dismiss()
            }
        } catch TrayError.sensitiveContentRequiresAcknowledgment(_) {
            isConfirmingSensitiveContent = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct CameraCaptureView: UIViewControllerRepresentable {
    let onComplete: (CaptureContent?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onComplete: onComplete)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.mediaTypes = [UTType.image.identifier]
        picker.allowsEditing = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onComplete: (CaptureContent?) -> Void

        init(onComplete: @escaping (CaptureContent?) -> Void) {
            self.onComplete = onComplete
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onComplete(nil)
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let url = info[.imageURL] as? URL,
               let data = try? Data(contentsOf: url) {
                let type = UTType(filenameExtension: url.pathExtension) ?? .image
                onComplete(
                    .image(
                        ImagePayload(
                            data: data,
                            typeIdentifier: type.identifier,
                            filename: url.lastPathComponent
                        )
                    )
                )
                return
            }
            if let image = info[.originalImage] as? UIImage,
               let data = image.jpegData(compressionQuality: 1) {
                onComplete(
                    .image(
                        ImagePayload(
                            data: data,
                            typeIdentifier: UTType.jpeg.identifier,
                            filename: "Camera Photo.jpg"
                        )
                    )
                )
                return
            }
            onComplete(nil)
        }
    }
}
