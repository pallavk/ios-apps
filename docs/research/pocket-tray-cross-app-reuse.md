# Pocket Tray cross-app reuse on iPhone

Verified 2026-08-18 against current Apple documentation, Human Interface Guidelines, Apple Support documentation, and WWDC sessions. The question is narrow: while composing in another app such as Telegram, how can someone find and reuse an object saved in Pocket Tray?

## Verdict

There is no supported iOS equivalent of a desktop clipboard-manager overlay. Pocket Tray cannot float its own window above Telegram, inspect Telegram's UI, or keep monitoring the clipboard while suspended. The best native design is a small set of explicit, user-invoked paths:

1. **Custom keyboard for direct text and URL insertion.** This is the only reviewed mechanism that can write saved text at another app's current insertion point.
2. **App Intents/App Shortcuts for system-wide retrieval and automation.** Return text, URLs, images, and files to Shortcuts; a user can compose these with Copy to Clipboard, Share, or another app's actions.
3. **Standard clipboard and share sheet for universal handoff.** Clipboard plus manual Paste is best for text/URLs and sometimes images; the share sheet is the reliable path for images and PDFs.
4. **Spotlight and Control Center for discovery/launch, not insertion.** They can find an item, run a constrained action, or deep-link into Pocket Tray, but they don't control Telegram's insertion point.

## Capability matrix

| Surface | Access while another app is open | Text/URL in-place | Image/PDF | Setup and constraints | Recommendation |
| --- | --- | --- | --- | --- | --- |
| Custom keyboard | Switch with the keyboard/globe control while a text field is focused | **Yes.** `textDocumentProxy.insertText` inserts an unattributed string at the current cursor. | **No direct insertion.** The keyboard text proxy accepts text, not image or file objects. | User enables the keyboard in Settings; apps can reject third-party keyboards, and secure/phone-pad fields use the system keyboard. | Build later as the fastest power-user path for text and URLs. |
| App Intents/App Shortcuts | Siri, Shortcuts, Spotlight-supported surfaces, Action button, or a user-configured automation | No direct host-field access. An intent can return `String`/`URL`; a shortcut can then use Copy to Clipboard, followed by manual Paste. | Return an `IntentFile`, `FileEntity`, or `Transferable` image/PDF, then use Share/Open In or another app's action. | App Shortcuts are installed with the app; a custom multi-step shortcut requires user setup. Availability depends on the receiving app exposing useful actions. | Implement a reusable system integration layer first. |
| Spotlight | Pull down Search, find an indexed Pocket Tray entity, then open its detail | No | Can find metadata/deep-link; it isn't a file-insertion surface. | Indexing makes content visible to system search, Siri, and potentially Apple Intelligence. Sensitive items need exclusion or a protected index. | Index only explicitly eligible, nonsensitive items. |
| Control Center / Action button | Open Control Center over the current app and tap a configured control | No direct insertion | No picker or general attachment UI; can run an intent or open Pocket Tray. | User must add/configure the control. Controls are compact buttons/toggles and may require authentication/redaction. | Offer Open Pocket Tray or a small fixed action; don't position it as the tray browser. |
| iOS 26 interactive snippet | A Siri/Spotlight/App Intent result appears temporarily above the current context | No direct host-field access | Can show item information and follow-up buttons; transferable output can continue into Shortcuts/system actions. | System-invoked, compact, temporary UI; not an app-owned persistent overlay. | Useful retrieval confirmation, not a replacement keyboard or share sheet. |
| Share/action extension | User opens the host app's share sheet | No general insertion path | Receives or transforms the **host's selected content** using declared types. | Host decides what input/context to provide. Extensions are short, user-invoked tasks in system UI. | Keep Pocket Tray's incoming Save extension. Do not misuse it as an outbound stored-item picker. |
| Clipboard / Paste | Copy in Pocket Tray or a shortcut, return to the host, then Paste | Manual Paste only | Images may paste if the host accepts them; PDF/file support is host-dependent, so prefer Share. | Pasteboard reads without established user intent can show system notifications/permission UI. | Provide explicit Copy; never poll or silently read. |
| Share sheet from Pocket Tray | Open an item in Pocket Tray and choose Share | Not in-place | **Yes**, when the selected destination advertises support for the item's type. | Leaves the original app and presents system activity UI. Destination options vary by data type and installed apps. | Primary outbound path for images and PDFs. |

## Findings by mechanism

### Custom keyboard: the only direct text insertion path

Apple's custom keyboard API gives a `UIInputViewController` a `textDocumentProxy`; calling `insertText(_:)` adds an **unattributed string** at the current insertion point. A Pocket Tray keyboard can therefore show search/recent/pinned text objects and insert text or a URL directly into Telegram's compose field. It cannot use this API to insert an image, PDF, rich attachment, or arbitrary `NSItemProvider`. [Creating a custom keyboard](https://developer.apple.com/documentation/uikit/creating-a-custom-keyboard), [`UIInputViewController`](https://developer.apple.com/documentation/uikit/uiinputviewcontroller), [`textDocumentProxy`](https://developer.apple.com/documentation/uikit/uiinputviewcontroller/textdocumentproxy)

This convenience has real setup and coverage costs:

- The person must enable the extension in Settings and select it from the keyboard switcher. [Creating a custom keyboard](https://developer.apple.com/documentation/uikit/creating-a-custom-keyboard)
- A host app can disable third-party keyboards; iOS also substitutes the system keyboard for secure text and phone-pad fields. [Configuring a custom keyboard interface](https://developer.apple.com/documentation/uikit/configuring-a-custom-keyboard-interface)
- The extension runs in an isolated, memory-limited process. Pocket Tray and the keyboard need an App Group to share a carefully scoped, read-optimized item snapshot. [App Groups Entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.application-groups), [Creating a custom keyboard](https://developer.apple.com/documentation/uikit/creating-a-custom-keyboard)
- Without Full Access, Apple restricts networking and write access to the containing app's shared container; with Full Access, the person explicitly acknowledges that keystrokes are available to the keyboard developer. Pocket Tray should design for **no Full Access** if a read-only shared snapshot is sufficient, keep all processing on device, and never read surrounding typed text for analytics. [Configuring open access for a custom keyboard](https://developer.apple.com/documentation/uikit/configuring-open-access-for-a-custom-keyboard)

Privacy gate: exclude sensitive items from the keyboard by default. Do not render a protected item's text merely because the main app was unlocked earlier; require a deliberate main-app policy/unlock flow.

### App Intents, App Shortcuts, Spotlight, and Control Center

Model a saved object as an `AppEntity` and expose focused intents such as **Find Tray Items**, **Get Tray Item Content**, and **Open Tray Item**. App Intents support primitive results including `String` and `URL`; `IntentFile`, `FileEntity`, and `Transferable` representations support images, PDFs, and other files. Returned values can feed later Shortcuts actions or another app's intent, but an intent receives no API to mutate the insertion point in the app currently on screen. [`IntentResult`](https://developer.apple.com/documentation/appintents/intentresult), [`IntentFile`](https://developer.apple.com/documentation/appintents/intentfile), [Adopting App Intents to support system experiences](https://developer.apple.com/documentation/appintents/adopting-app-intents-to-support-system-experiences), [What's new in App Intents](https://developer.apple.com/videos/play/wwdc2024/10134/)

App Shortcuts are available immediately after installation and appear through Siri, Spotlight, Shortcuts, and supported hardware/system surfaces. For a reliable reuse workflow, let the intent return the selected object, then document optional user-created shortcuts:

- `Find/Get Pocket Tray Item` -> `Copy to Clipboard` -> return to Telegram and Paste.
- `Find/Get Pocket Tray Item` -> `Share` for images or PDFs.
- `Find/Get Pocket Tray Item` -> a destination app's own action, if that app exposes one.

Apple's Shortcuts guide explicitly describes Copy to Clipboard as producing content to paste in another app and Share/Open In actions as passing content or files to compatible apps. [App Shortcuts](https://developer.apple.com/design/human-interface-guidelines/app-shortcuts), [Clipboard actions in Shortcuts](https://support.apple.com/en-gb/guide/shortcuts/apd081d9d61f/ios), [Share actions in Shortcuts](https://support.apple.com/en-nz/guide/shortcuts/apdaf74d75a5/ios)

Spotlight indexing improves retrieval, but selecting a result normally opens the app at that entity; it doesn't paste it. Indexing also makes entity content available to system search and related Siri/Apple Intelligence experiences. Pocket Tray should never index sensitive objects by default, should remove index entries when items are trashed/deleted, and should use a named protected on-device index for any personal content that is eligible. [Making app entities available in Spotlight](https://developer.apple.com/documentation/appintents/making-app-entities-available-in-spotlight), [Adding your app's content to Spotlight indexes](https://developer.apple.com/documentation/corespotlight/adding-your-app-s-content-to-spotlight-indexes), [`CSSearchableIndex`](https://developer.apple.com/documentation/corespotlight/cssearchableindex)

Control Center controls are intentionally narrow buttons or toggles. They run an App Intent or open a specific app view; the person must add and optionally configure them. A configurable **Open Pocket Tray** or future fixed favorite-slot action is valid, but Control Center isn't a dynamic recent-items browser and doesn't grant access to another app's input field. Sensitive labels/state should be redacted while locked and sensitive actions can require authentication. [Controls](https://developer.apple.com/documentation/widgetkit/controls-collection), [Creating controls to perform actions across the system](https://developer.apple.com/documentation/widgetkit/creating-controls-to-perform-actions-across-the-system), [Adding refinements and configuration to controls](https://developer.apple.com/documentation/widgetkit/adding-refinements-and-configuration-to-controls)

On iOS 26, an App Intent can display a compact interactive snippet over the current context in Siri/Spotlight-supported flows. Snippets can show selected item information and simple follow-up buttons without opening Pocket Tray. They remain system-presented, bounded, and temporary; they do not become a floating tray and still cannot edit Telegram's text field. [Displaying static and interactive snippets](https://developer.apple.com/documentation/appintents/displaying-static-and-interactive-snippets), [Design interactive snippets](https://developer.apple.com/videos/play/wwdc2025/281/)

### Extensions, clipboard, and media

Share and Action extensions work on content explicitly supplied by the host's share sheet. A Share extension is primarily a destination for posting/saving the current content; an Action extension performs a targeted transform and can return an edited `NSExtensionItem` to a cooperative host. This supports **Telegram -> Save to Pocket Tray**, not a dependable **Pocket Tray -> Telegram compose** picker. The host controls the context and supported types. [Activity views](https://developer.apple.com/design/human-interface-guidelines/activity-views), [Share extensions](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/Share.html), [Action extensions](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/Action.html)

For outbound media, Pocket Tray should vend the original image/PDF through `ShareLink`/`UIActivityViewController` and `NSItemProvider`; the system displays only destinations that accept the supplied representation. This is the most compatible attachment path, though it begins inside Pocket Tray rather than injecting into a compose field in place. [`UIActivityViewController`](https://developer.apple.com/documentation/uikit/uiactivityviewcontroller), [Collaborating and sharing copies of your data](https://developer.apple.com/documentation/uikit/collaborating-and-sharing-copies-of-your-data), [`NSItemProvider`](https://developer.apple.com/documentation/foundation/nsitemprovider)

The general pasteboard can carry multiple data types across apps. Pocket Tray may write an item when the person explicitly chooses Copy, after which the person invokes Paste in Telegram. A destination-provided `UIPasteControl` expresses user intent, but Pocket Tray cannot add that control to Telegram. Starting in iOS 14, reading another app's pasteboard data without established intent causes a system notification; Apple recommends type/pattern checks that don't retrieve contents until needed. [`UIPasteboard`](https://developer.apple.com/documentation/uikit/uipasteboard), [Documents, data, and pasteboard](https://developer.apple.com/documentation/uikit/documents-data-and-pasteboard)

## What iOS does not permit

- **No persistent floating Pocket Tray above other apps.** Apps and extensions are sandboxed; extensions appear only through system-defined extension points and UI. iOS 26 snippets are system-owned transient results, not permission for an arbitrary overlay. [App Extension Programming Guide](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/), [Shared data](https://developer.apple.com/documentation/technologyoverviews/shared-data)
- **No background clipboard watcher.** An ordinary iOS app is normally suspended shortly after entering the background, and the limited background modes do not include continuous clipboard monitoring. Pasteboard reads without user intent are surfaced by the system. [Configuring background execution modes](https://developer.apple.com/documentation/xcode/configuring-background-execution-modes), [Extending your app's background execution time](https://developer.apple.com/documentation/uikit/extending-your-app-s-background-execution-time), [`UIPasteboard`](https://developer.apple.com/documentation/uikit/uipasteboard)
- **No arbitrary cross-app insertion API.** Pocket Tray can't obtain Telegram's text view, selection, attachment picker, or process storage. Only the keyboard's text proxy can insert plain text, and only while the host accepts that keyboard and a text field is active.
- **No guaranteed media paste.** Copying an image or file doesn't require the destination to accept it. Use the share sheet and declared item-provider types for images and PDFs.

## Recommended delivery order

1. **App Intents foundation:** `TrayItemEntity`, find/get/open intents, plain-text/URL and image/PDF transfer representations. Exclude sensitive items from discovery by default.
2. **Shortcut recipes:** publish Copy Item and Share Item recipes, with clear manual-Paste expectations.
3. **Spotlight:** opt-in indexing of pinned or explicitly searchable nonsensitive items using protected indexes.
4. **Custom keyboard prototype:** text/URL only, local search over a read-only App Group snapshot, no Full Access, then validate Telegram plus common messaging/mail/note apps and all keyboard exclusions.
5. **iOS 26 enhancement:** concise find-item interactive snippet and a configurable Open Pocket Tray control. Treat these as access accelerators, not insertion mechanisms.

Do not build an outbound Action extension or a simulated floating overlay. Neither matches Apple's extension model, and neither solves cross-app reuse as reliably as keyboard + App Intents + standard share/clipboard flows.
