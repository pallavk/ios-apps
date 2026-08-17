# Pocket Tray world-class UI direction

Status: accepted on 2026-08-17 after a Matt Pocock grill-me session and physical comparison on Zeus.

## Product feeling

Pocket Tray should feel like a calm, premium native utility with subtle tactile delight. Captured content is the visual focus. Identity comes from hierarchy, spacing, previews, motion, haptics, and a restrained ink-blue palette—not decorative glass, gradients, or fashionable AI motifs.

## Chosen prototype

The **Airy** density variant won over Compact on Zeus.

- Larger media previews
- More breathing room between objects
- Stronger separation between content and quiet metadata
- Fewer simultaneous objects, accepted in exchange for calmer scanning

The throwaway comparison is preserved on branch prototype/pocket-tray-airy-ui at commit 0e5e095. It is not production code.

## Information architecture

- Primary destinations: Recent, Collections, Search
- Pinned is a prominent filter inside Recent
- Trash moves into Settings
- A labeled, bottom-reachable Add action is persistent across primary destinations
- When supported clipboard content is available, the same capture surface may become Save Clipboard
- Search is a useful landing page before typing, with recent objects, local recent searches, type filters, and collection shortcuts

## Object experience

- Recent remains one mixed-content list grouped by Today, Yesterday, and Earlier
- Each object type gets a purpose-built preview and hierarchy
- Collection, pin, sensitivity, and expiry are compact secondary metadata
- Tapping an object opens a consistent content-first detail view
- Detail has one persistent primary action: Copy, Open, or Share Original
- Quick Copy on Tap is an optional setting, off by default, for text and links
- Collections use a two-column grid with generated covers from recent contents

## Interaction

- Contextual onboarding replaces a multi-page introduction
- The first launch contains no fake saved objects
- Reversible actions happen immediately and offer Undo
- Confirmation is reserved for permanent deletion and security-sensitive changes
- Motion is restrained and functional: capture presentation, insertion, copy confirmation, and visible lifecycle movement
- Reduce Motion replaces spatial effects with fades
- App-switcher snapshots use a branded privacy cover whenever Face ID Lock is enabled

## Visual identity

- Ink/cobalt blue interactive accent with warm-neutral character
- System semantic colors remain reserved for success, warning, and destruction
- No purple gradients, sparkles, glowing borders, or AI-associated styling
- San Francisco semantic text styles only; personality comes from hierarchy rather than a custom font
- Avoid excessive centered layouts, rounded cards, pills, bold text, and decorative blur
- App icon direction: a simple open pocket/tray holding two offset objects, using an ink-blue field and warm off-white symbol

## Platform strategy

- One information architecture and feature set across iOS 18 and iOS 26
- Standard SwiftUI components supply platform-native appearance
- iOS 26 uses system Liquid Glass only for navigation and control surfaces
- iOS 18 uses native standard materials and never imitates glass
- Current Apple constraints and acceptance checks are captured in docs/research/pocket-tray-ui-polish-apple-guidance.md

## Cross-app reuse

Pocket Tray should support system-wide reuse rather than integrations tailored to individual destination apps.

- Strengthen the existing saved-object App Entity and App Shortcuts so a person can find an eligible object from Siri, Spotlight, Shortcuts, the Action button, or a configured system control, copy it, and paste it into the current app
- Return transferable text, URLs, images, and PDFs from App Intents so people can compose their own Copy, Share, Mail, or destination-app workflows
- Use Copy followed by manual Paste as the universal text and link fallback
- Use Share Original as the reliable outbound route for images and PDFs; destination apps decide which representations they accept
- Treat a Pocket Tray custom keyboard as a later, opt-in power-user feature for direct text and URL insertion only; it must work without Full Access, exclude sensitive objects by default, and clearly explain its system setup and host-app limitations
- Never promise a floating overlay, automatic background clipboard watcher, or direct media insertion into another app; iOS provides no supported general mechanism for those behaviors
- The detailed capability and privacy analysis is captured in docs/research/pocket-tray-cross-app-reuse.md

## Prototype acceptance matrix

The production implementation must be checked with deterministic mixed content across:

- Empty, populated, Search, Collections, detail, sensitive, loading, and error states
- Light and dark appearance
- Every Dynamic Type size
- Increase Contrast, Reduce Transparency, Reduce Motion, and Differentiate Without Color
- RTL and mixed-language content
- VoiceOver capture, find, reuse, organize, trash, restore, and permanent-delete workflows
- Physical iPhone capture, find, and reuse timing

## Delivery slices

The accepted direction is decomposed into issues #19 through #27. Issue #24 covers system-wide reuse of saved objects; issue #27 is the later opt-in text and URL keyboard prototype.
