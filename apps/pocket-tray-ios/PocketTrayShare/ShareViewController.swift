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
        statusLabel.text = String(localized: "Saving to Pocket Tray…")

        actionButton.configuration = .borderedProminent()
        actionButton.configuration?.title = String(localized: "Cancel")
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
            let inputItems = extensionContext?.inputItems as? [NSExtensionItem]
        else {
            showFailure(ShareCaptureError.unsupported)
            return
        }
        let providers = inputItems
            .flatMap { $0.attachments ?? [] }
            .map(NSItemProviderShareItem.init(provider:))
        guard !providers.isEmpty else {
            showFailure(ShareCaptureError.unsupported)
            return
        }

        captureTask = Task {
            defer { captureTask = nil }
            do {
                let repository = try FileTrayRepository.sharedContainer()
                let tray = Tray(repository: repository)
                let result = try await ShareCapture(tray: tray).captureAll(
                    providers,
                    willCommit: { [weak self] in
                        guard let self else { return }
                        captureState = .committing
                        actionButton.isEnabled = false
                    }
                )
                try Task.checkCancellation()
                captureState = .finished
                actionButton.isEnabled = true
                let saved = result.accepted.count
                let rejected = result.rejected.count
                let sensitive = result.rejected.count { $0 == .sensitive }
                if saved == 0, sensitive > 0 {
                    statusLabel.text = String(localized: "Possible sensitive content wasn't saved. Paste it in Pocket Tray to review it first.")
                    actionButton.configuration?.title = String(localized: "Close")
                } else if saved == 0 {
                    statusLabel.text = String(localized: "No items saved. \(rejected) couldn't be saved.")
                    actionButton.configuration?.title = String(localized: "Close")
                } else if rejected == 0 {
                    statusLabel.text = saved == 1
                        ? String(localized: "Saved \(saved) item to Pocket Tray")
                        : String(localized: "Saved \(saved) items to Pocket Tray")
                    actionButton.configuration?.title = String(localized: "Done")
                } else if sensitive > 0 {
                    statusLabel.text = sensitive == 1
                        ? String(localized: "Saved \(saved). \(sensitive) possible sensitive item needs in-app review.")
                        : String(localized: "Saved \(saved). \(sensitive) possible sensitive items need in-app review.")
                    actionButton.configuration?.title = String(localized: "Done")
                } else {
                    statusLabel.text = String(localized: "Saved \(saved); \(rejected) couldn't be saved.")
                    actionButton.configuration?.title = String(localized: "Done")
                }
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
        actionButton.configuration?.title = String(localized: "Close")
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
