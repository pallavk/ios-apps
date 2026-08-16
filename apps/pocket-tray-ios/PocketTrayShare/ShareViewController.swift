import UIKit
import UniformTypeIdentifiers

@MainActor
final class ShareViewController: UIViewController {
    private let statusLabel = UILabel()
    private let actionButton = UIButton(type: .system)
    private var hasStarted = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        statusLabel.font = .preferredFont(forTextStyle: .headline)
        statusLabel.numberOfLines = 0
        statusLabel.textAlignment = .center
        statusLabel.text = "Saving to Pocket Tray…"

        actionButton.configuration = .borderedProminent()
        actionButton.configuration?.title = "Cancel"
        actionButton.addTarget(self, action: #selector(finish), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [statusLabel, actionButton])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 24
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24)
        ])
        preferredContentSize = CGSize(width: 360, height: 220)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !hasStarted else { return }
        hasStarted = true
        captureSharedItem()
    }

    private func captureSharedItem() {
        guard
            let item = extensionContext?.inputItems.first as? NSExtensionItem,
            let provider = item.attachments?.first
        else {
            showFailure(ShareCaptureError.unsupported)
            return
        }

        Task {
            do {
                let repository = try FileTrayRepository.sharedContainer()
                let tray = Tray(repository: repository)
                _ = try await ShareCapture(tray: tray).capture(
                    NSItemProviderShareItem(provider: provider)
                )
                statusLabel.text = "Saved to Pocket Tray"
                actionButton.configuration?.title = "Done"
            } catch {
                showFailure(error)
            }
        }
    }

    private func showFailure(_ error: Error) {
        statusLabel.text = error.localizedDescription
        actionButton.configuration?.title = "Close"
    }

    @objc private func finish() {
        extensionContext?.completeRequest(returningItems: nil)
    }
}

private final class NSItemProviderShareItem: @unchecked Sendable, ShareItemProviding {
    private let provider: NSItemProvider

    init(provider: NSItemProvider) {
        self.provider = provider
    }

    var canLoadImage: Bool {
        imageTypeIdentifier != nil
    }

    var canLoadURL: Bool {
        provider.hasItemConformingToTypeIdentifier(UTType.url.identifier)
    }

    var canLoadText: Bool {
        provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier)
            || provider.hasItemConformingToTypeIdentifier(UTType.text.identifier)
    }

    func loadImage() async throws -> ImagePayload {
        guard let typeIdentifier = imageTypeIdentifier else {
            throw ShareCaptureError.unsupported
        }
        let data = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Data, Error>) in
            provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: ShareCaptureError.unreadable)
                }
            }
        }
        return ImagePayload(
            data: data,
            typeIdentifier: typeIdentifier,
            filename: provider.suggestedName
        )
    }

    func loadURL() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(
                forTypeIdentifier: UTType.url.identifier,
                options: nil
            ) { item, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let url = item as? URL {
                    continuation.resume(returning: url)
                } else if let string = item as? String, let url = URL(string: string) {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(throwing: ShareCaptureError.unreadable)
                }
            }
        }
    }

    func loadText() async throws -> String {
        let typeIdentifier = provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier)
            ? UTType.plainText.identifier
            : UTType.text.identifier
        return try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { item, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let string = item as? String {
                    continuation.resume(returning: string)
                } else if let attributedString = item as? NSAttributedString {
                    continuation.resume(returning: attributedString.string)
                } else if let data = item as? Data, let string = String(data: data, encoding: .utf8) {
                    continuation.resume(returning: string)
                } else {
                    continuation.resume(throwing: ShareCaptureError.unreadable)
                }
            }
        }
    }

    private var imageTypeIdentifier: String? {
        provider.registeredTypeIdentifiers.first { identifier in
            UTType(identifier)?.conforms(to: .image) == true
        }
    }
}
