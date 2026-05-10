# NutriScan Technical Implementation Plan (v0.1)

## 1) Repository Layout
- `apps/nutriscan-ios/` — iOS SwiftUI app.
- `backend/nutriscan-api/` — FastAPI parsing service.
- `docs/plans/` — product and technical docs.

## 2) Architecture
Pipeline:
Capture → OCR → Clean → Segment → Parse → Validate → Personalize → Explain → Save

### iOS Responsibilities
- Capture/crop image.
- Run Apple Vision OCR locally.
- Display/edit OCR text.
- Send OCR text + preferences to backend.
- Render structured result and save locally.

### Backend Responsibilities
- Normalize OCR text.
- Parse nutrition deterministically where possible, with region-aware rules (Singapore + US initially).
- Parse ingredients/allergens with rules + LLM-assisted extraction.
- Validate response schemas.
- Return summary + confidence indicators.

## 3) Proposed API (MVP)
### `POST /analyze-label`
Include optional `region_hint` (`sg`, `us`, or `auto`) to improve parser behavior.
Request:
- `ocr_text: string`
- `scan_type: nutrition | ingredients | nutrition_and_ingredients | unknown`
- `region_hint: sg | us | auto`
- `user_preferences: { allergens[], avoid_ingredients[], dietary_preferences[], nutrition_goals{} }`

Response:
- `nutrition`
- `ingredient_analysis`
- `warnings[]`
- `summary`
- `confidence`

## 4) Data Models (Initial)
- Product
- Scan
- NutritionFacts
- IngredientAnalysis
- UserPreference

(Implement with Pydantic models in backend and mirrored Swift models in iOS.)

## 5) Implementation Phases
### Phase 1: iOS OCR Spike
- Create SwiftUI shell.
- Add Photos picker + camera capture.
- Integrate Vision OCR.
- Display raw OCR and editable review screen.

### Phase 2: Parser Prototype (Backend)
- Add regional parser profiles for Singapore and US label conventions.
- Build parser package with fixture-based tests.
- Add deterministic nutrition parsing.
- Add ingredient/allergen/facility-warning extraction.

### Phase 3: API Integration
- Expose `POST /analyze-label`.
- Connect iOS app networking.
- Render analysis result screen.

### Phase 4: Persistence + Preferences
- Local save/delete scans.
- Preference controls and personalized warning highlights.

### Phase 5: Reliability Hardening
- Expand fixtures with 20–50 real labels.
- Confidence and fallback improvements.
- Latency and error handling polish.


## 6) Development Methodology: Red-Green-Refactor (TDD)
Yes—TDD is a good fit for this project if applied selectively.

Use strict red/green/refactor for:
- Parser and normalization logic.
- Allergen and warning detection rules.
- API schema validation/contract behavior.
- View models and pure business logic.

Use lighter-weight testing (not strict TDD) for:
- SwiftUI layout details and visual polish.
- Camera UX and OCR edge-capture interactions that are hardware dependent.

Recommended loop:
1. Red: add/extend failing test from real OCR fixture.
2. Green: implement smallest change to pass.
3. Refactor: improve parser/readability, keep tests green.

Definition of Done for each parser story:
- New failing fixture test added first.
- All parser unit/integration tests pass.
- Confidence and fallback behavior asserted for ambiguous input.
- Regression fixture added for every production parsing bug.

## 7) Testing Strategy
- Unit tests: nutrition parser, ingredient parser, allergen detection.
- Golden fixtures: OCR text + expected JSON.
- Integration tests: endpoint contract validity.
- Manual test runs on varied lighting/angles.

## 8) Privacy Defaults
- OCR on-device.
- Text-only backend calls by default.
- Optional image upload only with explicit user opt-in.
- Local delete flows for scan history.

## 9) Regionalization Notes
- Start with Singapore-first test fixtures, then ensure parity on US fixtures.
- Maintain a normalization dictionary for regional nutrient naming variants and declaration styles.

## 10) Future Extensions (Post-MVP)
- Barcode lookup and metadata enrichment.
- Cloud sync/account support.
- Android client using same backend.
- Expanded ingredient taxonomy and regional label formats.

