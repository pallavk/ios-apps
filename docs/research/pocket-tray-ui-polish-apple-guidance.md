# Pocket Tray UI polish: Apple guidance

Verified 2026-08-17 against current Apple Human Interface Guidelines, SwiftUI documentation, and WWDC25 sessions. This note converts the guidance into constraints for Pocket Tray's iOS 18+ interface; it is not a visual specification.

## Verdict

The proposed direction is aligned with Apple's current design system: keep captured content visually dominant, use a short top-level tab structure with a dedicated Search tab, put one global capture action near the tab bar, and let standard SwiftUI navigation and controls adopt the platform appearance. On iOS 26, Liquid Glass should form a restrained **functional layer** above the content. It should not become the material for tray rows, collection tiles, previews, or decorative cards.

## Product constraints

### Liquid Glass hierarchy

- Build with standard `NavigationStack`, `TabView`, toolbars, sheets, menus, and controls first. Apple says these components automatically gain the current platform treatment and adapt to overlap, focus, Reduce Transparency, and Reduce Motion settings. Remove custom toolbar, tab-bar, and sheet backgrounds that compete with system effects. [Adopting Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass)
- Reserve glass for navigation and interactive controls. Apple's materials guidance explicitly separates the floating Liquid Glass control/navigation layer from the content layer and says not to use Liquid Glass in content. Tray rows, previews, collection covers, and backgrounds should use content, system colors, or standard materials. [Materials](https://developer.apple.com/design/human-interface-guidelines/materials)
- Express hierarchy through layout and grouping rather than borders, background capsules, or many tinted controls. Use tint only for a meaningful primary action or next step; keep other toolbar icons monochrome. [Get to know the new design system](https://developer.apple.com/videos/play/wwdc2025/356/), [Build a SwiftUI app with the new design](https://developer.apple.com/videos/play/wwdc2025/323/)
- If a custom glass control is genuinely necessary, use it sparingly. Group nearby glass elements in one `GlassEffectContainer`; Apple says this is required for consistent sampling and helps rendering performance. Do not stack glass on glass or mix glass variants. [Applying Liquid Glass to custom views](https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views), [Meet Liquid Glass](https://developer.apple.com/videos/play/wwdc2025/219/)

**Pocket Tray implication:** the persistent Add/Save Clipboard control is the one defensible custom or bottom-accessory emphasis. The object cards themselves must remain in the content layer.

### Tabs, Search, and the bottom action

- Use three top-level destinations: Recent, Collections, and Search. Apple describes tabs as persistent top-level navigation and cautions that too many make content harder to locate. [Enhancing your app's content with tab navigation](https://developer.apple.com/documentation/swiftui/enhancing-your-app-content-with-tab-navigation)
- Implement Search as `Tab(role: .search)` and apply `.searchable` at the `TabView` level. On iPhone, selecting the tab replaces the tab bar with the search field; browsing suggestions can remain visible before typing. The role also supplies the expected title, symbol, and pinned trailing placement, including RTL adaptation. [`TabRole.search`](https://developer.apple.com/documentation/swiftui/tabrole/search), [Build a SwiftUI app with the new design](https://developer.apple.com/videos/play/wwdc2025/323/)
- A persistent global Add/Save Clipboard surface is a plausible `tabViewBottomAccessory`. This API is iOS 26+ and iPhone-only. The accessory appears above a normal tab bar and moves inline when the bar collapses, so it needs both full and compact layouts based on `tabViewBottomAccessoryPlacement`. [`tabViewBottomAccessory`](https://developer.apple.com/documentation/swiftui/view/tabviewbottomaccessory%28isenabled%3Acontent%3A%29)
- Tab minimization is opt-in on iPhone. If used, `.tabBarMinimizeBehavior(.onScrollDown)` should expand when the person reverses scroll direction; verify that capture remains obvious in both accessory placements. [`TabBarMinimizeBehavior`](https://developer.apple.com/documentation/swiftui/tabbarminimizebehavior), [Build a SwiftUI app with the new design](https://developer.apple.com/videos/play/wwdc2025/323/)

**Release constraint:** `TabRole.search` is available from iOS 18 and should define the common search structure. Bottom accessory, tab minimization, custom glass, `ToolbarSpacer`, and other iOS 26 APIs must be isolated behind availability. They cannot be allowed to fork the app's information architecture or behavior.

### Toolbars, presentations, and object content

- Group toolbar actions by relationship and keep grouping and placement consistent. The primary content action may be tinted; unrelated actions should be separate, with infrequent actions in More. Avoid extra backgrounds behind toolbars because they interfere with the automatic scroll-edge legibility effect. [Adopting Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass), [Build a SwiftUI app with the new design](https://developer.apple.com/videos/play/wwdc2025/323/)
- Let sheets, menus, alerts, and popovers use their standard presentation. Apple recommends reconsidering custom sheet backgrounds; partial sheets become inset glass on iOS 26 and naturally become opaque at full height. [Build a SwiftUI app with the new design](https://developer.apple.com/videos/play/wwdc2025/323/)
- Use a list for the mixed, text-heavy Recent feed and a standard grid for visual collection covers. Apple says lists are generally easier for textual information, while collections suit image-based content and should normally use expected row/grid layouts. [Lists and tables](https://developer.apple.com/design/human-interface-guidelines/lists-and-tables), [Collections](https://developer.apple.com/design/human-interface-guidelines/collections)
- Preserve a content-first object detail: large preview first, one clear bottom action, metadata subordinate, and edit/secondary actions outside the primary reading path. This follows Apple's broader requirement that Liquid Glass elevate rather than compete with underlying content. [Materials](https://developer.apple.com/design/human-interface-guidelines/materials)

### Accessibility acceptance gate

- Use semantic system text styles and layouts that reflow at every Dynamic Type size. Apple asks apps to preserve useful content at the largest accessibility sizes, avoid truncation, and scale meaningful SF Symbols with text. [Typography](https://developer.apple.com/design/human-interface-guidelines/typography)
- Meet at least 4.5:1 contrast for normal text up to 17 pt and 3:1 for 18 pt or bold text; check light, dark, and Increase Contrast appearances. Prefer system colors. Never communicate pin, expiry, sensitivity, selection, or success by color alone—pair color with text, shape, or symbol. [Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility), [Color](https://developer.apple.com/design/human-interface-guidelines/color)
- With Reduce Motion, replace spatial/zoom/depth transitions with fades, reduce bounce, and avoid animations into or out of blur. Custom effects must also be checked with Reduce Transparency. Standard system components adapt automatically, but custom Add morphs and insertion/move animations do not get a free pass. [Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility), [Testing system accessibility features](https://developer.apple.com/documentation/accessibility/testing-system-accessibility-features-in-your-app)
- Every object and control needs a concise, accurate VoiceOver label; meaningful images need descriptions. The complete capture, find, copy/open/share, move, trash, restore, and permanent-delete workflows must be operable with VoiceOver, not merely discoverable. [VoiceOver](https://developer.apple.com/design/human-interface-guidelines/voiceover), [VoiceOver evaluation criteria](https://developer.apple.com/help/app-store-connect/manage-app-accessibility/voiceover-evaluation-criteria)
- Maintain at least a 44 by 44 point hit region for buttons and icon-only controls, including row actions and the compact Add accessory. [Buttons](https://developer.apple.com/design/human-interface-guidelines/buttons)
- Test the airy and compact prototypes at standard and largest accessibility text sizes, light/dark, Increase Contrast, Reduce Transparency, Reduce Motion, Differentiate Without Color, RTL, and VoiceOver on both simulator and a physical iPhone.

### App icon

- Keep the agreed pocket/tray symbol simple, distinctive, front-facing, and recognizable at small sizes. Avoid text, screenshots, thin lines, sharp corners, baked-in bevels, shadows, blur, or specular effects. Apple's current icon workflow expects simple source layers and applies dynamic material effects later. [App icons](https://developer.apple.com/design/human-interface-guidelines/app-icons), [Say hello to the new look of app icons](https://developer.apple.com/videos/play/wwdc2025/220/)
- Create the 1024 x 1024 source with Apple's current template/grid, export vector layers where practical, and use Icon Composer to preview default, dark, clear, and tinted appearances over varied backgrounds and lighting. Keep group count low and verify the symbol survives mono/tinted rendering. [Creating your app icon using Icon Composer](https://developer.apple.com/documentation/xcode/creating-your-app-icon-using-icon-composer), [Icon Composer](https://developer.apple.com/icon-composer/)
- The ink-blue field and warm off-white pocket symbol are compatible with Apple's recommendation to favor a colored background for better distinction between appearance modes. The icon should not use interface-style glass pills or AI-associated decorative motifs.

### iOS 18 fallback

- Maintain one app anatomy and behavior across iOS 18 and iOS 26. Use standard SwiftUI components everywhere; the system supplies the appearance appropriate to the installed OS. Do not imitate Liquid Glass on iOS 18. [Adopting Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass)
- Wrap iOS 26-only modifiers and declarations in `#available(iOS 26, *)` or `@available`. Apple recommends one multi-version app and runtime availability checks, typically targeting one or two older OS versions while people transition. [Running code on a specific platform or OS version](https://developer.apple.com/documentation/xcode/running-code-on-a-specific-version)
- Provide a native iOS 18 composition using the same Recent, Collections, and Search destinations, standard `.searchable`, and a bottom-reachable labeled Add control using established toolbar/safe-area patterns. Capability, labels, state, and accessibility behavior must match; only material and platform-owned motion may differ.
- Do not enable `UIDesignRequiresCompatibility` for this polish direction. Apple documents it as an escape hatch for keeping the pre-new-SDK appearance; the intended strategy here is progressive adoption and explicit fallback testing. [Adopting Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass)

## Prototype decision gate

Neither airy nor compact wins on screenshots alone. Both must use the same deterministic mixed-content dataset and pass three physical-device tasks—capture an object, find an object, and reuse an object—plus the accessibility matrix above. Choose the densest version that retains readable hierarchy, comfortable targets, full Dynamic Type reflow, and an unmistakable Add action in normal and collapsed tab-bar states.
