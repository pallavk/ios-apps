# iOS clipboard manager landscape

Verified 2026-08-16 from Apple documentation, Apple Support, and Singapore App Store listings. Prices can change.

## Verdict

Try an existing app before building. **PastePal** is the closest complete match; **Yoink** is the strongest inexpensive object shelf; **copycopy** is the best local-only option. Building our own is feasible, but it cannot honestly behave like a Mac clipboard daemon: iOS normally suspends background apps and requires user intent/permission to read content copied in another app.

## Strongest non-subscription options

| App | Singapore price | Strengths | Important limitation |
| --- | ---: | --- | --- |
| [PastePal](https://apps.apple.com/sg/app/clipboard-manager-pastepal/id1503446680) | Free download; **S$19.98 Pro** one-time IAP | Universal purchase for iPhone, iPad, and Mac; text/images/files; collections, search, keyboard, share/action extensions, Shortcuts, widgets, optional iCloud sync; developer says no subscriptions and no external server | Its continuous background monitor uses a visible Picture-in-Picture session. This is a workaround for iOS suspension, not an invisible daemon. Singapore rating count is very small. |
| [Yoink](https://apps.apple.com/sg/app/yoink-improved-drag-and-drop/id1260915283) | **S$8.98** upfront | Mature file/snippet shelf; accepts text, URLs, images, documents and other file types; Share extension, keyboard, Shortcuts, Files integration, Handoff and iCloud sync | More of an object shelf than a focused clipboard-history UI; continuous monitoring also uses Picture-in-Picture. Mac Yoink is a separate purchase. |
| [copycopy](https://apps.apple.com/sg/app/copycopy-clipboard-history/id6758018622) | Free download; **S$9.98 Paid** one-time IAP | Local-only, no subscription/account/cloud/analytics; text, images, files, OCR, search, tags, sensitive-item handling, keyboard and Quick Capture via Back Tap/Action Button/Control Center | New in 2026 with little rating history; deliberately has no cloud sync. It captures via the app/keyboard/Quick Capture rather than silently monitoring in the background. |

Also worth knowing: [Copy & Clip](https://apps.apple.com/us/app/copy-clip-clipboard-manager/id964026081) is a simpler free, on-device option with ads and an optional “Support Us” purchase. It supports explicit paste/share/Control Center/Shortcuts capture and expressly says it does not silently read the clipboard in the background. [Copy 'Em](https://apps.apple.com/us/app/copy-em-paste-keyboard/id1457458191) is not a fit for the stated requirement: its current App Store purchase is a yearly subscription.

### Recommendation

1. Buy **PastePal** if cross-device sync and broad integrations matter most.
2. Buy **Yoink** if the main job is temporarily holding mixed media/files and drag-and-drop, especially on iPad.
3. Buy **copycopy** if local-only privacy matters more than sync.

Use each for a few days specifically through Share Sheet capture and its keyboard. If those two interactions feel right, there is little reason to build. Build only if we want a materially simpler interface, stricter privacy/lifecycle rules, or specialized object processing.

## Apple platform constraints

### Pasteboard privacy and prompts

[`UIPasteboard`](https://developer.apple.com/documentation/uikit/uipasteboard) is the system API. Since iOS 14, the system notifies a person when an app reads general-pasteboard content originating in another app without established user intent. Apple says type checks such as `hasStrings`, `hasImages`, `hasURLs`, `types`, and pattern detection can inspect availability without pulling the data and causing the notification/alert.

On iOS 16 and later, direct programmatic reads can raise a modal permission prompt. Apple recommends ordinary Paste menu actions, Command-V, or [`UIPasteControl`](https://developer.apple.com/documentation/uikit/uipastecontrol), which is a system Paste button that establishes user intent and pastes without the prompt. Apple’s [WWDC22 privacy session](https://developer.apple.com/videos/play/wwdc2022/10096/) explicitly describes this change.

Design consequence: make “Save clipboard” an explicit system Paste control or clearly invoked action. Do not poll clipboard values merely to discover their type.

### Background monitoring

Apple states that an iOS app is [typically suspended in the background](https://developer.apple.com/documentation/xcode/configuring-background-execution-modes); only limited purpose-specific modes such as audio, location, and scheduled processing receive background execution. There is no general clipboard-monitor background mode.

[`UIPasteboard.changeCount`](https://developer.apple.com/documentation/uikit/uipasteboard/changecount) and change notifications work while the process runs, but Apple notes that the count is updated when the app reactivates if another app changed the clipboard. Therefore a suspended app cannot reconstruct every intervening clipboard value; at best it sees the current value when it resumes.

PastePal and Yoink advertise monitoring while backgrounded by keeping a Picture-in-Picture overlay active. If we copy that approach, it must be an explicit, visible session with battery/review risk. It should not be the MVP’s core promise.

### Keyboard extension

A [custom keyboard extension](https://developer.apple.com/documentation/uikit/creating-a-custom-keyboard) can show saved clips and insert text through `textDocumentProxy`. It is a separate, memory-limited process and never gets direct access to the host text field. Secure fields, phone-pad fields, and apps that disable third-party keyboards will use the system keyboard instead.

Apple’s [open-access documentation](https://developer.apple.com/documentation/uikit/configuring-open-access-for-a-custom-keyboard) says a default keyboard may read, but not write, the containing app’s shared group container. “Allow Full Access” is required for writing to that container, network access, or direct iCloud participation. We can avoid requesting Full Access for an MVP by having the containing app/share extension write clips while the keyboard only reads and inserts them. This is a meaningful trust advantage.

### Share extension and shared storage

A Share extension is the most dependable capture path for text, URLs, images, video and files offered by another app. Apple’s [Share extension guide](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/Share.html) describes invocation from the system Share sheet, and `NSExtensionActivationRule` declares supported semantic content types.

Use an [App Group](https://developer.apple.com/documentation/xcode/configuring-app-groups) so the main app, Share extension and keyboard can access one shared container. Extensions remain separate binaries/processes.

### Shortcuts, Action Button and controls

[App Intents](https://developer.apple.com/documentation/appintents) expose actions to Shortcuts, Siri, Spotlight, widgets/controls, Apple Pencil and the iPhone Action Button. Provide at least `Save Clipboard`, `Copy Recent Clip`, and `Search Clips`. These are excellent explicit capture triggers, but paste permission behavior still needs device testing; an intent is not a blanket entitlement to inspect the clipboard.

### Cross-device sync

Use the app’s own iCloud data store for persistent history. Apple supports [Core Data mirrored with CloudKit](https://developer.apple.com/documentation/coredata/mirroring-a-core-data-store-with-cloudkit), giving each device a local replica and the same user access across devices. Keep large media as files/assets and define retention and quota limits.

[Universal Clipboard](https://support.apple.com/en-us/102430) is not history sync. It makes only the current item available briefly on nearby devices signed into the same Apple Account with Wi-Fi, Bluetooth, and Handoff enabled.

## A sensible app we could build

Build an explicit-capture, privacy-first object shelf:

- SwiftUI main app with a searchable timeline, favorites, tags/collections, preview, copy/share, retention rules and duplicate suppression.
- Typed clip model for plain/rich text, URL, image, video/audio and file references, preserving UTType representations where practical.
- Share extension for the primary mixed-media capture flow.
- System Paste control in the app; App Intents for Action Button, Back Tap, Shortcuts and Control Center workflows.
- Read-only custom keyboard for fast search and text insertion without requesting Full Access in version 1.
- App Group local store, optional CloudKit sync, Face ID lock, on-device sensitive-item detection, automatic expiry, and no third-party analytics.
- No promise of silent, continuous background history. A visible, user-started Picture-in-Picture monitor can be evaluated later as an optional experiment.

The technically risky parts are extension/store concurrency, rich representation fidelity, CloudKit media/conflict handling, keyboard memory limits, and reliable device-level paste-permission UX—not the basic SwiftUI list. A functional personal prototype is realistic; App Store polish across all extensions and content types is a substantially larger project.
