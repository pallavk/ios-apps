# Pocket Tray Image Capture Design

## Status

Approved through the Pocket Tray product grilling session and tracked by GitHub issue #6.

## Goal

Extend Pocket Tray's existing share-extension capture path to common images and screenshots. Keep original bytes unchanged, persist them safely, show a recognizable preview, export the original, reject objects larger than 25 MB, and deduplicate identical bytes without losing user metadata.

Direct camera and photo-library capture remains a later adapter in issue #14. It must reuse the image path defined here.

## Considered Approaches

### Content-addressed sidecar assets — selected

Store image bytes in an `assets` directory using their SHA-256 digest as the stable filename. Keep the digest, byte count, media type, and display metadata in `tray.json`.

This keeps the existing JSON metadata model, avoids inflating every metadata transaction with image bytes, and makes byte-identical deduplication explicit. Writing the immutable asset before committing metadata ensures a record never points to a partially written file.

### Base64 bytes inside `tray.json`

This would need the least new file-management code, but a 25 MB object would expand substantially in JSON and every small metadata update would rewrite all binary content. Corruption or an interrupted write would also put all objects and assets in one failure domain.

### SwiftData or Core Data with external binary storage

This could manage relationships and external storage, but it would replace the current repository and migration model during an otherwise focused feature. The operational complexity is not justified for the MVP.

## Domain Model

`TrayItemKind` gains `image`. An image item carries immutable `TrayAsset` metadata:

- SHA-256 digest of the exact original bytes
- original byte count
- uniform type identifier
- normalized file extension
- optional source filename for display and export

The asset digest is the image's deduplication identity. Text aliases remain unchanged. Titles, notes, collections, pin state, lifecycle state, creation date, and stable item ID remain object metadata and survive recapture.

The capture boundary accepts an `ImagePayload` containing bytes plus type and filename hints. It validates that the data is non-empty, conforms to an image type, can be decoded as an image, and is no larger than 25,000,000 bytes before any durable mutation.

## Storage and Transaction Flow

The shared Pocket Tray container contains:

```text
PocketTray/
  tray.json
  assets/
    <sha256>.<extension>
```

Capture follows this order:

1. Validate the payload and calculate its SHA-256 digest.
2. If the digest asset does not exist, atomically write the original bytes to a temporary sibling and rename it to the final content-addressed path.
3. Verify the final file's size and digest.
4. Commit the item metadata through the existing coordinated `TrayStore` transaction.
5. If a matching image item exists, refresh that item instead of creating another one, preserving its user metadata and stable ID.

An asset written before a failed metadata commit is an unreferenced orphan, not a partial object. Orphans are safe and may be removed by a later maintenance pass; cleanup is not required for issue #6. Existing digest files are never overwritten.

Permanent deletion removes metadata but leaves the immutable asset as an orphan. Cross-process reference-aware cleanup is deferred so deletion cannot race a simultaneous share-extension capture. Moving an object to Trash also leaves its bytes intact.

## Capture Adapter

The share extension checks image representations before URL and text representations when the provider advertises an image. It loads file-backed or data-backed `NSItemProvider` values without transcoding and forwards the exact bytes through `ShareCapture` into `Tray`.

Cancellation, unreadable providers, invalid images, unsupported formats, and objects over 25 MB produce a clear failure message and no item record. Camera and photo-picker permissions are out of scope here.

## Preview and Export

Image rows show an aspect-fill thumbnail generated with ImageIO from the stored original. Thumbnail generation limits the decoded pixel size to protect memory and runs outside the main actor. A missing or corrupt asset shows an unavailable placeholder instead of crashing or silently deleting the item.

Opening an image presents a larger preview. Export uses the stored asset file URL through the system Share sheet, preserving the original bytes and type. Export is disabled with a clear error when validation detects a missing or corrupt asset.

## Error Handling

- More than 25,000,000 bytes: reject before writing.
- Insufficient space or failed atomic asset write: return a storage error and do not commit metadata.
- Metadata commit failure after a new asset write: return the error; the unreferenced asset is harmless.
- Missing asset: retain metadata, show an unavailable state, and block export.
- Digest mismatch or undecodable bytes: treat the asset as corrupt, retain metadata, and block export.
- Interrupted writes: temporary files are never treated as assets; only verified final digest paths are readable.

## Testing

Domain and repository tests cover:

- common image type acceptance and non-image rejection
- exact 25 MB boundary and over-limit rejection with no record or final asset
- original byte identity across relaunch and export
- byte-identical image deduplication with recency refresh and metadata preservation
- atomic write failure and insufficient-space simulation
- missing, truncated, digest-mismatched, and undecodable assets
- legacy text-only stores loading unchanged
- share-provider data-backed and file-backed image representations

The final verification includes the complete unit suite, signed simulator and physical-device builds, install on Zeus, visual preview inspection, and spec plus standards review before push and issue closure.

## Out of Scope

- Image editing, compression, OCR, and AI analysis
- Camera and photo-library UI, tracked by #14
- Video, audio, and arbitrary files
- Cloud sync
- Proactive orphan cleanup
