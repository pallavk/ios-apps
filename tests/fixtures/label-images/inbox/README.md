# Label Image Fixture Inbox

Put real label images here for fixture intake. This folder is for images, not
hand-copied OCR text.

Suggested filename format:

```text
<region>-<short-product-name>-<section>-<shot>.jpg
```

Examples:

```text
sg-cereal-nutrition-front.jpg
sg-cereal-ingredients-back.jpg
us-protein-bar-nutrition-ingredients.jpg
```

Accepted formats:

- `.jpg`
- `.jpeg`
- `.png`
- `.heic`

Recommended capture set per product:

- one nutrition panel image
- one ingredients/allergens image
- one full-package context image if useful

After intake, the workflow should be:

1. Run local OCR from the image.
2. Save the OCR output as a text snapshot under
   `backend/nutriscan-api/tests/fixtures/<region>/`.
3. Add parser assertions in `backend/nutriscan-api/tests/test_api.py`.
4. Keep the original image fixture for OCR regression/manual review.

Do not include personal information or receipts in fixture images.
