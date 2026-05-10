# NutriScan Decision Log

This log records product and technical decisions made while building the NutriScan MVP. Keep entries short, factual, and updated when new evidence changes the decision.

## Decision Format

- **Date:** When the decision was made or last confirmed.
- **Status:** Accepted, trial, deferred, or superseded.
- **Decision:** The current direction.
- **Rationale:** Why this direction fits the MVP constraints.
- **Follow-up:** What would cause us to revisit it.

## Decisions

### 2026-05-10: iOS-first working copy

- **Status:** Accepted
- **Decision:** Build the MVP for iOS first, with Android deferred until after the working copy is useful on real iPhones.
- **Rationale:** The user has an iPhone 14 Pro available for real-device testing, and iOS gives us Apple Vision OCR and a direct photo capture workflow for collecting label fixtures.
- **Follow-up:** Revisit Android once the parser, capture workflow, and fixture corpus are stable.

### 2026-05-10: Singapore and US label scope

- **Status:** Accepted
- **Decision:** Optimize parsing and fixtures for Singapore and US food labels first.
- **Rationale:** This keeps serving-size, allergen, and nutrition-panel normalization bounded enough for an MVP while still covering the user's expected labels.
- **Follow-up:** Add region support only after the Singapore and US fixture suite has broad coverage.

### 2026-05-10: Privacy-first OCR and backend flow

- **Status:** Accepted
- **Decision:** Prefer on-device OCR, send text to the backend by default, and require explicit opt-in before any image upload mode is added.
- **Rationale:** Food labels can still contain sensitive purchase or dietary information. Text-only upload limits exposure while allowing deterministic backend parsing.
- **Follow-up:** Any cloud OCR or cloud document parser must be opt-in, clearly labeled, and testable against local alternatives.

### 2026-05-10: Deterministic parser first

- **Status:** Accepted
- **Decision:** Build deterministic parser helpers before LLM interpretation, using red/green/refactor TDD for parser behavior.
- **Rationale:** Calories, serving size, added sugar, declared allergens, and facility warnings need stable structured output and regression tests.
- **Follow-up:** Add LLM assistance only around interpretation and explanation, not as the only source of core nutrition or allergen fields.

### 2026-05-10: Conservative allergy language

- **Status:** Accepted
- **Decision:** Use conservative allergy wording and avoid absolute safety claims.
- **Rationale:** OCR and parser output can miss or misread label text. The app should highlight declared risks and uncertainty, not certify safety.
- **Follow-up:** Review safety copy before internal beta and again before any wider release.

### 2026-05-10: Image-first fixture collection

- **Status:** Accepted
- **Decision:** Treat real label images as first-class fixtures, with generated OCR snapshots stored alongside them.
- **Rationale:** The user will collect photos like the real product flow. Keeping both image and OCR text lets us improve capture, OCR formatting, and parser behavior independently.
- **Follow-up:** Grow the mixed Singapore and US fixture suite to at least 20-50 labels before calling parser coverage representative.

### 2026-05-10: Capture draft history behavior

- **Status:** Accepted
- **Decision:** Let users save capture drafts before analysis, make the save action idempotent, show visible confirmation, store the image preview, use date/time scan titles, and allow deleting history items.
- **Rationale:** This makes the test app useful for collecting label photos and OCR text without repeatedly creating duplicate history entries.
- **Follow-up:** Add fixture export polish once the collection workflow reveals friction.

### 2026-05-10: Ingredient concern highlighting

- **Status:** Accepted
- **Decision:** Start with a deterministic ingredient concern taxonomy for unhealthy or borderline ingredients users may miss.
- **Rationale:** The main use case is surfacing concerning ingredients quickly. A deterministic taxonomy is cheap, inspectable, and testable.
- **Follow-up:** Expand the taxonomy from real labels and keep allergy warnings separate from general ingredient concerns.

### 2026-05-10: Optional LLM-assisted interpretation

- **Status:** Deferred
- **Decision:** Add LLM-assisted ingredient interpretation later as an optional user-triggered mode.
- **Rationale:** LLMs can help explain ambiguous additives and tradeoffs, but deterministic fields should remain the source of truth for MVP parsing. API access requires an OpenAI API key; a ChatGPT subscription alone does not authenticate backend API calls.
- **Follow-up:** Implement only after the deterministic flow and fixture corpus can evaluate whether LLM output improves usefulness without weakening safety language.

### 2026-05-10: OCR table handling strategy

- **Status:** Trial
- **Decision:** Use Apple's on-device Vision document recognition on iOS 26+ first, including table rows from `DocumentObservation.Container.Table`, then fall back to `VNRecognizeTextRequest` with bounding-box-aware layout formatting on older OS versions or document-recognition failures.
- **Rationale:** Nutrition labels often use tables, and plain OCR text loses row/column relationships. The iOS 26 document API is local and exposes table containers, while the legacy OCR fallback keeps the app working on older devices.
- **Options considered:** Apple Vision table/document extraction, LlamaParse or similar cloud parsers, LiteParse/local document parsing, and an on-device or fine-tuned small vision-language model such as Gemma.
- **Follow-up:** After collecting 20-50 real label fixtures, compare document-recognition output against legacy OCR. Consider an opt-in cloud parser for hard table-heavy labels if local OCR remains insufficient. Treat on-device/fine-tuned vision models as a later research track after we have a larger evaluated corpus.

### 2026-05-10: Physical-device verification

- **Status:** Accepted
- **Decision:** Smoke test the iOS working copy on the user's iPhone 14 Pro in addition to simulator builds.
- **Rationale:** Camera, photo permissions, Vision OCR, and local persistence need real-device feedback before the app is useful for collecting label fixtures.
- **Follow-up:** Keep using physical-device checks for capture/OCR/history changes, then broaden device coverage before internal beta.
