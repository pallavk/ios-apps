# Pocket Tray Local Intelligence Design

## Status

Approved by the Pocket Tray product decisions and tracked by GitHub issue #8.

## Goal

Make saved objects searchable and actionable offline using Apple frameworks. Durable capture must finish before analysis begins, and analysis failure must never remove, corrupt, or make the original object unusable.

## Architecture

Each `TrayItem` gains optional, backward-compatible `ContentAnalysis` metadata containing searchable extracted text, a dominant language, named entities, and contextual actions. Actions use a small stable domain model for URL, phone, address, date, and shipment-tracking values rather than persisting framework objects.

`ContentAnalyzing` is the deterministic adapter boundary. It accepts normalized text plus optional exact asset bytes and returns domain metadata. Production uses `AppleContentAnalyzer`; tests inject fixtures or a deterministic analyzer. Framework output is first translated into a framework-neutral fixture value, then mapped into the durable domain, so integration tests verify our translation without testing Vision, Natural Language, or Foundation internals.

Capture commits the original item and asset first. Only after repository success does a scheduler start analysis. Opening the app also reschedules objects whose analysis is absent, making share-extension termination recoverable. The scheduler deduplicates in-flight item IDs. Analysis errors are swallowed after recording no metadata; the original remains readable and can be retried on a later app activation.

## Apple Framework Work

- Vision performs accurate, language-corrected OCR for image assets.
- Natural Language identifies dominant language and supported person, place, and organization names from item text plus OCR.
- `NSDataDetector` recognizes URLs, phone numbers, postal addresses, and dates.
- Conservative deterministic carrier patterns recognize common shipment tracking numbers because no general first-party secret/tracking classifier is assumed.

No model, content, telemetry, or prompt leaves the device. PDF OCR/text extraction, generative summaries, and Apple Intelligence-only features remain out of scope.

## Search and Actions

Local search adds OCR text, entity values, and action display values to the existing title/text/note/collection index. Rows with recognized actions expose a context menu/details section:

- URL: open through the system
- phone: call after the normal iOS confirmation path
- address: open Maps search
- date: open an EventKit-free calendar day URL when supported, otherwise copy the value
- tracking number: open the carrier/system web lookup when a recognized URL is available, otherwise copy

Actions are suggestions only and never affect retention, sensitivity, or deletion.

## Testing and Release Gate

Tests prove capture is visible before a blocked analyzer completes, analyzer failure preserves the object, pending analysis retries, persistence survives relaunch, OCR text participates in search, fixture translation covers every action/entity type, and deterministic analyzer outputs drive behavior. Final gates are the full suite, signed simulator/device builds where available, visual inspection, and zero spec/standards findings.
