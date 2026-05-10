# Image Fixture Workflow

NutriScan's real-world test flow starts with label images because the iOS app
uses local OCR before sending text to the backend.

## Source Fixtures

Store incoming real product-label images in:

```text
tests/fixtures/label-images/inbox/
```

Once reviewed, move them to:

```text
tests/fixtures/label-images/sg/
tests/fixtures/label-images/us/
```

## OCR Snapshots

The backend parser remains text-only by default. For repeatable automated tests,
generate OCR text snapshots from the images and store those snapshots under:

```text
backend/nutriscan-api/tests/fixtures/sg/
backend/nutriscan-api/tests/fixtures/us/
```

Each snapshot should preserve OCR mistakes, odd line breaks, and ambiguous text
where possible.

## Why Keep Both

- Images test the capture/OCR path and manual review workflow.
- OCR snapshots make backend parser tests deterministic and fast.
- Keeping both lets us improve OCR later without losing parser coverage.

## Fixture Acceptance

For each real product fixture, aim to capture:

- nutrition fields
- ingredients list
- contains allergen declaration, if present
- may contain or facility warning, if present
- region classification as Singapore or US
