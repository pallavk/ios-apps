# Pocket Tray PDF and Multi-Object Share Design

## Status

Approved by the existing Pocket Tray MVP decisions and tracked by GitHub issue #7.

## Goal

Capture full-fidelity PDFs and make a share containing several attachments deterministic: every attachment is attempted independently, every accepted attachment becomes one tray object, failures do not roll back successes, and the completion UI reports both counts.

## Architecture

The content-addressed asset store introduced for images remains the single binary-storage seam. `TrayAsset` continues to describe exact bytes; validation dispatches from its concrete UTI so image assets must decode through ImageIO and PDF assets must open as a non-empty, unlocked PDF document. The common 25,000,000-byte ceiling is applied to each payload before its asset or metadata is written.

`CaptureContent` and `TrayItemKind` gain `pdf`. `PDFPayload` carries exact provider bytes, a type hint, and an optional source filename. Its SHA-256 digest is the deduplication identity, so byte-identical PDFs refresh the existing object and retain title, note, collection, pin, lifecycle, and stable ID.

The share adapter gains PDF loading and a sequential batch operation. Sequential processing bounds memory to one provider payload at a time and gives every attachment an independent transaction. The batch returns accepted objects plus a typed rejection for every failed provider. Cancellation is allowed while providers are loading; once the first accepted attachment reaches commit, the sheet becomes non-cancellable until the batch completes.

## Storage and Validation

PDF capture follows the existing asset transaction:

1. Reject a non-PDF UTI or payload over 25,000,000 bytes.
2. Verify the bytes open as an unlocked PDF with at least one page.
3. Compute SHA-256 and atomically publish the immutable digest file.
4. Validate final size, digest, and PDF readability.
5. Commit only that attachment's metadata through the coordinated repository.

An attachment failure cannot create a visible record. An asset orphan after a metadata failure remains harmless and follows the issue #6 policy.

## Preview and Export

PDF rows show a bounded first-page thumbnail plus filename/page information. Opening a PDF presents a read-only `PDFView` with paging and zoom. The Share sheet receives the independently validated export copy, preserving bytes and a filename whose extension agrees with `public.pdf`. Missing, digest-mismatched, encrypted, empty, or unreadable files retain metadata but show an unavailable state and block export.

## Multi-Object Results

The extension flattens attachments from every `NSExtensionItem` in source order. Each provider produces exactly one outcome:

- accepted: a saved or deduplicated tray object
- unsupported: no supported image, PDF, URL, or text representation
- unreadable: the advertised representation could not be loaded or validated
- oversized: the individual binary exceeds 25 MB

The final sheet reports `Saved N` and, when relevant, `M could not be saved`. A batch with zero accepted inputs is a failure state; mixed success is a completed state with an explicit rejection count.

## Tests

Tests cover valid PDF metadata, byte identity across relaunch/export, exact and over-limit boundaries, invalid/encrypted/empty PDFs, deduplication with metadata retention, first-page preview, data- and file-backed providers, multiple accepted objects, mixed success with typed counts, and no record/asset for each rejected input. The release gate is the full suite, signed simulator and physical builds when Zeus is available, simulator UI inspection, and zero spec/standards findings.

## Out of Scope

PDF text extraction, OCR, annotation/editing, password entry, multi-file atomic rollback, video/audio/arbitrary files, and orphan cleanup.
