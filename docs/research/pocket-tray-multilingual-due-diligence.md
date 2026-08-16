# Pocket Tray multilingual input and operations due diligence

Verified 2026-08-16 against the Pocket Tray working tree atop `761357f`, Apple platform documentation, and Unicode specifications. This audit distinguishes three different promises: storing multilingual content, understanding it, and localizing Pocket Tray's own interface.

## Verdict

Pocket Tray can safely claim **Unicode text capture, display, persistence, copy, and literal search across scripts**. It should **not yet claim uniformly multilingual OCR, entity/action detection, or a localized interface**.

### Implementation update — 2026-08-17

Issue #15 added app, share-extension, and controls string catalogs; routed generated action titles, UIKit share status/plural messages, authentication copy, errors, and feedback through localization APIs; retained up to three language hypotheses with backward-compatible decoding; and made OCR preference order follow the device's Language & Region order intersected with Vision's runtime-supported set while automatic detection remains enabled. Settings now reports the runtime OCR language count and the effective preference order.

The regression matrix now covers Korean, Hindi, Simplified and Traditional Chinese, Arabic, Hebrew, accented/decomposed Latin, mixed scripts and numerals, emoji grapheme sequences, and exact multilingual export filenames. Forced RTL at the largest accessibility text size was visually checked in Simulator. The interface still ships only English source copy: a non-English locale must not ship until an actual user selects it and native-speaker copy is reviewed.

The architecture is sound: it uses Swift `String`, `Codable`/`JSONEncoder`, high-level Foundation URLs, native SwiftUI text controls, on-device Vision, and Natural Language. Apple explicitly says Vision OCR runs on device, and the current request enables accurate recognition, language correction, and automatic language detection. However, OCR languages vary by request revision and recognition level; Natural Language tag schemes vary by language and device; and Apple does not publish a comprehensive language guarantee for `NSDataDetector`. Those capabilities must be presented as best-effort and tested by capability, not inferred from the device language.

## What works today

| Area | Current implementation | Assessment |
| --- | --- | --- |
| Text input/display | Native `TextField`, `TextEditor`, `Text`, `List`, and SwiftUI layouts | Good base. SwiftUI supplies bidirectional layout and standard-control accessibility behavior automatically. |
| Persistence | `TrayItem` stores Swift `String`; `FileTrayRepository` round-trips it through `JSONEncoder`/`JSONDecoder`; assets retain `originalFilename` | Good base for Unicode. JSON text is UTF-8-compatible, and APFS accepts valid UTF-8 filenames while preserving case and normalization. |
| Search | Searches text, metadata, OCR, entities, and action values with case-, diacritic-, and width-insensitive comparison using `Locale.current` | Good user-locale substring search. It handles exact CJK/RTL substrings and common Latin accent/full-width variants. It does not provide transliteration, stemming, word segmentation, or simplified/traditional Chinese equivalence. |
| OCR | `VNRecognizeTextRequest`, `.accurate`, `usesLanguageCorrection = true`, `automaticallyDetectsLanguage = true` | Correct baseline, private/on-device. Actual supported languages remain request/device/revision-dependent. |
| Language ID | `NLLanguageRecognizer` stores one dominant BCP-47-like language code | Useful metadata, but one dominant language loses mixed-language information and may be `nil` or uncertain for short text. |
| Entities | `NLTagger(.nameType)` over the complete combined text | Best-effort only. The code does not check whether `.nameType` is available for the detected language on this device. |
| Links/phones/addresses/dates | `NSDataDetector` over natural-language text | Appropriate Apple API, but not a validator and not a documented all-language guarantee. |
| RTL/Dynamic Type | Native layout and semantic font styles, but several horizontal rows, fixed thumbnails, and line limits | Likely functional, not release-proven. There are no RTL, bidirectional-text, or accessibility-size UI tests. |
| App localization | No `.xcstrings`, `.strings`, or non-English region in the project; UIKit share-extension messages and generated action titles are English literals | English-only interface. `SWIFT_EMIT_LOC_STRINGS` alone does not ship translations. |

## Framework findings and limits

### Vision OCR on iOS 18+

Apple describes `VNRecognizeTextRequest` as multilingual and on-device. `automaticallyDetectsLanguage` asks Vision to choose the appropriate recognition/language-correction model, but it does not make every language supported. Apple says the supported set depends on recognition level and request revision and provides `supportedRecognitionLanguages()` as the authoritative runtime query. Language order matters when `recognitionLanguages` is supplied; Apple also warns that unspecified recognition is otherwise biased toward English and documents special constraints for Chinese/language-correction combinations.

Implications:

- Keep automatic language detection as the default.
- Query and record the request's supported languages in diagnostics/tests on the minimum iOS 18 runtime and current OS; do not hard-code a marketing list from a later SDK.
- For a future OCR-language preference, intersect the person's preferred languages with `supportedRecognitionLanguages()` and preserve ordering. Do not replace auto-detection with a single app-locale language.
- Treat mixed-script images, handwriting, low-resolution text, and languages outside the runtime set as expected partial/no-result cases. The original object already survives analysis failure, which is correct.
- `usesLanguageCorrection` is not universally available/equivalent across languages; OCR tests should verify raw capture remains useful even when correction does not help.

Sources: [Apple: Recognizing Text in Images](https://developer.apple.com/documentation/vision/recognizing-text-in-images), [`automaticallyDetectsLanguage`](https://developer.apple.com/documentation/vision/vnrecognizetextrequest/automaticallydetectslanguage), and [`supportedRecognitionLanguages()`](https://developer.apple.com/documentation/vision/vnrecognizetextrequest/supportedrecognitionlanguages()).

### Natural Language identification and entities

`NLLanguageRecognizer` first identifies script and then language. Apple exposes multiple hypotheses and probabilities because a single answer can be uncertain; dominant language is optional. Apple's language tag operates at sentence/paragraph/document level rather than reliably word-by-word. This matters for clips such as an English message containing a Japanese address.

`NLTagger` supports many languages and scripts, not every scheme for every language. Apple provides `availableTagSchemes(for:language:)` specifically to determine whether `.nameType` is available on the current device and `setLanguage(_:range:)` when the language of a range is known.

Concrete gap: `AppleContentAnalyzer.namedEntities` always runs `.nameType` and neither checks availability nor assigns languages to ranges. This is safe as best-effort, but empty results must not mean "no entities exist." Before presenting entity support as multilingual, gate tagging by `availableTagSchemes`, retain multiple language hypotheses (or per-paragraph language), and add fixtures for supported and unsupported languages.

Sources: [Apple: Identifying the language in text](https://developer.apple.com/documentation/naturallanguage/identifying-the-language-in-text), [`NLLanguageRecognizer`](https://developer.apple.com/documentation/naturallanguage/nllanguagerecognizer), [`NLTagger`](https://developer.apple.com/documentation/naturallanguage/nltagger), and [`availableTagSchemes(for:language:)`](https://developer.apple.com/documentation/naturallanguage/nltagger/availabletagschemes(for:language:)).

### Search, normalization, CJK, and case folding

Foundation's locale-aware folding is important: Apple uses Turkish `I`/`i` as an example where case folding changes by locale. Pocket Tray now passes `Locale.current`, which is the correct default for a user-facing search. Width-insensitive matching is useful for half-width/full-width East Asian forms. Diacritic-insensitive matching covers common accent searches.

No single locale is linguistically correct for every mixed-language tray. Current search remains substring matching, so it intentionally does not provide:

- romanized/transliterated lookup (`tokyo` -> `東京`);
- simplified/traditional Chinese equivalence;
- morphology/stemming or language-aware token search;
- confusable-character matching across scripts.

Unicode requires canonically equivalent strings to compare equivalently in conformant collation, while storage systems may preserve different normalization forms. Keep original text byte-for-byte at the application level; normalize/fold only an internal search key if search performance later requires indexing. Do not apply compatibility normalization to the stored clip because it can lose meaningful distinctions.

Concrete gap: the new unit coverage checks Arabic substring, Japanese characters, Latin diacritics, and full-width Latin, but it does not cover canonical composed/decomposed forms, Turkish casing under different locales, Hebrew/Arabic mixed with Latin/numerals, emoji grapheme sequences, or Chinese variants. Add those as table-driven search tests and explicitly document the non-goals above.

Sources: [Apple: `localizedStandardContains`](https://developer.apple.com/documentation/foundation/nsstring/localizedstandardcontains(_:)), [Apple: `folding(options:locale:)`](https://developer.apple.com/documentation/foundation/nsstring/folding(options:locale:)), [Apple: `widthInsensitive`](https://developer.apple.com/documentation/foundation/nsstring/compareoptions/widthinsensitive), [Unicode normalization FAQ](https://www.unicode.org/faq/normalization.html), and [Unicode Collation Algorithm](https://www.unicode.org/reports/tr10/).

### Data detectors and contextual operations

Apple documents `NSDataDetector` for natural-language dates, addresses, links, phone numbers, and transit data. Apple also says it is not validation, discards uncertain matches, and should only run over natural-language text. The API offers no language-support inventory or locale parameter comparable to Vision/Natural Language.

Therefore contextual actions are **best-effort suggestions**, not multilingual extraction guarantees. The app correctly preserves the source substring and generally makes the user invoke the resulting action. Remaining gaps:

- Tests cover English/Singapore-shaped fixtures only, not Arabic/Eastern Arabic digits, international phone punctuation, non-Latin domains, or date/address ambiguity under several regions.
- Tracking-number regex keywords are English (`fedex`, `tracking number/no.`); numeric carrier formats work only where the pattern is distinctive. Do not translate the regex label list ad hoc and risk false positives. Prefer carrier-format rules plus an explicit manual "track/copy" action later.
- Suggested action titles and share-extension status/plural messages are constructed as English `String` values, so SwiftUI's automatic `LocalizedStringKey` extraction will not cover them.

Source: [Apple: `NSDataDetector`](https://developer.apple.com/documentation/foundation/nsdatadetector).

### RTL, text input, Dynamic Type, and accessibility

Apple says system UI frameworks and SwiftUI standard layouts support RTL automatically, and SwiftUI derives `layoutDirection` from locale. Pocket Tray largely benefits because it uses standard components and leading alignment rather than hard-coded left/right positions. Native text controls accept installed keyboards and bidirectional text.

Automatic mirroring is not proof of a good layout. Apple recommends aligning long paragraphs by their content language and testing every localization and accessibility size. Pocket Tray's row-level `HStack`s combine content, URL/action buttons, fixed-size thumbnails, and line-limited text. At accessibility sizes or with long Arabic/Hebrew content, those controls may crowd or truncate. Combined accessibility elements also need VoiceOver verification with mixed-direction text and numerals.

Must test at minimum:

- Arabic and Hebrew app RTL layouts, plus English UI containing Arabic/Hebrew clips;
- mixed Arabic/Hebrew + Latin URL + phone-number rows (digits must not be reversed);
- all accessibility Dynamic Type sizes, VoiceOver reading order, Switch Control, and Voice Control names;
- long translated button, alert, menu, and share-extension status strings.

Sources: [Apple HIG: Right to left](https://developer.apple.com/design/human-interface-guidelines/right-to-left), [SwiftUI `LayoutDirection`](https://developer.apple.com/documentation/swiftui/layoutdirection), [Apple HIG: Typography/Dynamic Type](https://developer.apple.com/design/human-interface-guidelines/typography), and [SwiftUI accessibility fundamentals](https://developer.apple.com/documentation/swiftui/accessibility-fundamentals).

### Unicode persistence and filenames

The JSON store and model use Unicode-capable Foundation types and do not perform lossy transcoding. APFS accepts valid UTF-8 filenames, preserves their case/normalization, and on supported iOS versions performs normalization-insensitive lookup. Apple recommends high-level `FileManager`/`URL` APIs, which Pocket Tray uses. The asset's internal stored filename is digest-based ASCII, which avoids Unicode collision and path issues; the original filename is only recreated in a digest-scoped export directory.

Concrete gap: no test round-trips multilingual/emoji text, metadata, OCR output, or original filenames through the real file repository and export path. Add fixtures containing NFC/NFD equivalents, CJK, Arabic/Hebrew, supplementary-plane emoji, and bidi controls. Preserve the original filename for display, but consider a separate export-name safety policy for control characters, invisible bidi controls, platform separators, length, and collisions. Normalization should not silently rewrite the user's stored display name.

Sources: [Apple APFS FAQ: filenames](https://developer.apple.com/library/archive/documentation/FileManagement/Conceptual/APFS_Guide/FAQ/FAQ.html), [Apple File System Programming Guide](https://developer.apple.com/library/archive/documentation/FileManagement/Conceptual/FileSystemProgrammingGuide/AccessingFilesandDirectories/AccessingFilesandDirectories.html), [Apple: `JSONEncoder`](https://developer.apple.com/documentation/foundation/jsonencoder), and [Unicode normalization FAQ](https://www.unicode.org/faq/normalization.html).

## Must fix before claiming multilingual support

1. **Define the promise precisely.** For the current release say "captures and searches Unicode text; on-device OCR and suggestions vary by language and device." Do not say "supports all languages."
2. **Add capability-aware intelligence.** Query Vision OCR languages and `NLTagger` scheme availability; treat missing support as normal, never as analysis failure or absence of content.
3. **Add a multilingual regression matrix.** Real repository round trips, search equivalence, OCR fixtures/device probes, detector fixtures, RTL layouts, Dynamic Type, and VoiceOver. Include English, Simplified and Traditional Chinese, Japanese, Korean, Arabic, Hebrew, Hindi or another Indic script, accented Latin, and mixed-script samples; select the final matrix from the actual iOS 18 runtime capability results.
4. **Localize generated operations before calling the UI multilingual.** Add a string catalog and localize app/share-extension strings, action titles, errors, accessibility labels/hints, and plurals. The project currently declares only English/Base and contains no string catalog.
5. **Keep contextual detections labeled as suggestions.** Provide copy/manual fallbacks when a phone, address, date, or tracking value is not detected or cannot form a valid target.

## Later enhancements

- Per-item language hypotheses and per-paragraph language/script metadata for mixed-language clips.
- User OCR-language preferences intersected with the runtime-supported set.
- Optional transliteration aliases for search, stored separately from original content and clearly documented; do not silently conflate Chinese variants or cross-script confusables.
- Locale-aware date/phone presentation and richer regional detector fixtures.
- A safe export-filename layer that removes invisible/control characters while preserving a separate original display name.
- Localized interface rollout driven by actual users, beginning with English plus the languages used in the regression matrix rather than an untested large translation set.

## Recommended release gate

For issue #8, ship the current on-device analysis only after the capability checks and multilingual data/search persistence tests pass. UI translation can be a separate issue if the product copy remains explicit that the **content** may be multilingual while the **interface** is English. Full multilingual operations require the string catalog and RTL/Dynamic Type device matrix before the claim changes.
