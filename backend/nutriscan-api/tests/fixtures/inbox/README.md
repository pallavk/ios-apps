# OCR Fixture Inbox

Paste real OCR text files here before turning them into checked parser fixtures.

Suggested filename format:

```text
<region>-<short-product-name>-<section>.txt
```

Examples:

```text
sg-cereal-nutrition-ingredients.txt
us-protein-bar-ingredients.txt
```

For each fixture, include as much raw OCR as possible, including awkward line
breaks and recognition mistakes. Do not include personal information.

After review, fixtures should be copied into `tests/fixtures/sg/` or
`tests/fixtures/us/` with expected parser assertions in `tests/test_api.py`.
