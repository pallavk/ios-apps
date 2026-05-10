# NutriScan Working Build Checklist

Use this checklist to create a fully working end-to-end MVP "working copy" of NutriScan.

## 0) Project Setup
- [x] Confirm product scope: iOS-first, Singapore + US labels, no accounts for v0.1.
- [x] Create/verify repo folders:
  - [x] `apps/nutriscan-ios/`
  - [x] `backend/nutriscan-api/`
  - [x] `docs/plans/`
- [x] Define branch strategy (`main`, short-lived feature branches).
- [x] Add issue templates for bug/feature/test fixture requests.

## 1) iOS App Skeleton
- [x] Create SwiftUI app project in `apps/nutriscan-ios/`.
- [x] Add app navigation shell (Home, Scan, OCR Review, Results, Preferences, History).
- [x] Add local persistence scaffold (SwiftData/Core Data models).
- [x] Add basic error/loading states.

## 2) Capture + OCR
- [x] Add photo picker flow (PhotosUI).
- [x] Add camera capture flow (VisionKit/AVFoundation).
- [x] Integrate Apple Vision OCR extraction.
- [x] Render raw OCR output in editable text view.
- [x] Persist OCR text + image reference locally.
  - [x] Save OCR/photo capture drafts before backend analysis.

## 3) Parser Backend Skeleton
- [x] Create FastAPI service in `backend/nutriscan-api/`.
- [x] Add Pydantic request/response schemas for `POST /analyze-label`.
- [x] Add health endpoint (`GET /health`).
- [x] Add local run config (uvicorn) and `.env.example`.

## 4) Test Fixtures + TDD Baseline
- [x] Create fixture folders:
  - [x] `backend/nutriscan-api/tests/fixtures/sg/`
  - [x] `backend/nutriscan-api/tests/fixtures/us/`
  - [x] `tests/fixtures/label-images/sg/`
  - [x] `tests/fixtures/label-images/us/`
  - [x] `tests/fixtures/label-images/inbox/`
- [x] Add first real label image fixtures and generated OCR snapshots (nutrition + ingredients).
  - [x] Add first realistic OCR-like text fixtures for Singapore and US parser coverage.
- [x] Write failing tests first (red):
  - [x] nutrition parsing
  - [x] ingredients parsing
  - [x] allergen and facility-warning detection
- [x] Implement minimal parser logic to pass tests (green).
- [x] Refactor parser modules while tests stay green (refactor).

## 5) Parsing Features (MVP)
- [x] Nutrition extraction for core fields (calories, serving size, sugars, sodium, fats, protein).
- [x] Ingredients list extraction.
- [x] General ingredient concern detection for added sweeteners, processed fats, and common additives.
- [x] Declared allergen extraction (`contains`).
- [x] `may contain` and facility-warning extraction.
- [x] Region-aware normalization (`region_hint`: `sg | us | auto`).
  - [x] Initial Singapore and US parser notes/aliases based on explicit `region_hint`.
- [x] Field-level confidence and source-text references where possible.

## 6) End-to-End API
- [ ] Implement `POST /analyze-label` orchestration pipeline:
  - [x] cleanup
  - [x] section detection
  - [x] deterministic parse
  - [ ] optional LLM-assisted ingredient interpretation
    - [x] Document opt-in LLM design and API-key requirement.
  - [x] schema validation
  - [x] summary generation
- [x] Return standardized response fields (`nutrition`, `ingredient_analysis`, `warnings`, `summary`, `confidence`).
- [x] Add integration tests for response contract stability.

## 7) iOS Integration
- [x] Connect iOS app networking to backend `POST /analyze-label`.
- [x] Build Analysis Result screen sections:
  - [x] summary
  - [x] nutrition table
  - [x] ingredients/allergens/warnings
  - [x] confidence/uncertainty hints
- [ ] Add save/delete from result screen.
  - [x] Add save from result screen and delete from history.

## 8) Preferences + Personalization
- [x] Build Preferences UI (allergens, dietary prefs, avoid-list, nutrition goals).
- [x] Pass preferences with analyze requests.
- [x] Highlight conflicts in results (contains/may contain/avoid-list matches).
- [x] Use conservative allergy wording (no safety guarantees).

## 9) Reliability + Privacy Hardening
- [x] Add retry/failure UX for OCR/API issues.
- [x] Add manual correction loop before analysis by default.
- [x] Ensure on-device OCR and text-only upload default.
- [x] Add explicit opt-in if image upload is ever enabled.
- [x] Add disclaimer and safety copy in app settings/results.

## 10) Acceptance Criteria (Working Copy)
- [x] User can capture or pick a label image.
- [x] OCR text appears and is editable.
- [x] Analyze returns structured nutrition + ingredient output.
- [x] Allergens and warnings are detected and displayed.
- [x] Summary is generated and understandable.
- [x] Scan can be saved and reopened from history.
- [ ] At least 20–50 mixed Singapore/US fixtures run in parser test suite.
  - [x] Add fixture workflow from iPhone capture drafts to fixture inbox.

## 11) Launch-Readiness for Internal Beta
- [ ] Smoke test on physical iPhone devices with varied lighting.
  - [x] Build, install, launch, and screenshot smoke test on iPhone 17 simulator.
  - [x] Build, install, and launch smoke test on iPhone 14 Pro physical device.
- [ ] Validate top allergy scenarios against physical labels.
  - [x] Add first top-allergy scenario fixture covering contains, may contain, and equipment warnings.
- [ ] Review legal/safety copy for non-medical positioning.
- [ ] Freeze MVP scope and create post-MVP backlog (barcode, sync, Android).
