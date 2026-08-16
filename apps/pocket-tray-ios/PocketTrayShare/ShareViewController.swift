import UIKit

@MainActor
final class ShareViewController: UIViewController {
    private enum CaptureState {
        case capturing
        case committing
        case finished
    }

    private let statusLabel = UILabel()
    private let actionButton = UIButton(type: .system)
    private var hasStarted = false
    private var captureState = CaptureState.capturing
    private var captureTask: Task<Void, Never>?

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

        captureTask = Task {
            defer { captureTask = nil }
            do {
                let repository = try FileTrayRepository.sharedContainer()
                let tray = Tray(repository: repository)
                _ = try await ShareCapture(tray: tray).capture(
                    NSItemProviderShareItem(provider: provider),
                    willCommit: { [weak self] in
                        guard let self else { return }
                        captureState = .committing
                        actionButton.isEnabled = false
                    }
                )
                try Task.checkCancellation()
                captureState = .finished
                actionButton.isEnabled = true
                statusLabel.text = "Saved to Pocket Tray"
                actionButton.configuration?.title = "Done"
            } catch is CancellationError {
                return
            } catch {
                showFailure(error)
            }
        }
    }

    private func showFailure(_ error: Error) {
        captureState = .finished
        actionButton.isEnabled = true
        statusLabel.text = error.localizedDescription
        actionButton.configuration?.title = "Close"
    }

    @objc private func finish() {
        if captureState == .capturing {
            captureState = .finished
            captureTask?.cancel()
            captureTask = nil
            extensionContext?.cancelRequest(withError: CancellationError())
        } else if captureState == .committing {
            return
        } else {
            extensionContext?.completeRequest(returningItems: nil)
        }
    }
}
