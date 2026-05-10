# NutriScan Working Build Checklist

Use this checklist to create a fully working end-to-end MVP "working copy" of NutriScan.

## 0) Project Setup
- [x] Confirm product scope: iOS-first, Singapore + US labels, no accounts for v0.1.
- [ ] Create/verify repo folders:
  - [ ] `apps/nutriscan-ios/`
  - [x] `backend/nutriscan-api/`
  - [x] `docs/plans/`
- [ ] Define branch strategy (`main`, short-lived feature branches).
- [ ] Add issue templates for bug/feature/test fixture requests.

## 1) iOS App Skeleton
- [ ] Create SwiftUI app project in `apps/nutriscan-ios/`.
- [ ] Add app navigation shell (Home, Scan, OCR Review, Results, Preferences, History).
- [ ] Add local persistence scaffold (SwiftData/Core Data models).
- [ ] Add basic error/loading states.

## 2) Capture + OCR
- [ ] Add photo picker flow (PhotosUI).
- [ ] Add camera capture flow (VisionKit/AVFoundation).
- [ ] Integrate Apple Vision OCR extraction.
- [ ] Render raw OCR output in editable text view.
- [ ] Persist OCR text + image reference locally.

## 3) Parser Backend Skeleton
- [x] Create FastAPI service in `backend/nutriscan-api/`.
- [x] Add Pydantic request/response schemas for `POST /analyze-label`.
- [x] Add health endpoint (`GET /health`).
- [x] Add local run config (uvicorn) and `.env.example`.

## 4) Test Fixtures + TDD Baseline
- [x] Create fixture folders:
  - [x] `backend/nutriscan-api/tests/fixtures/sg/`
  - [x] `backend/nutriscan-api/tests/fixtures/us/`
- [ ] Add first OCR text fixtures from real labels (nutrition + ingredients).
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
  - [x] schema validation
  - [x] summary generation
- [x] Return standardized response fields (`nutrition`, `ingredient_analysis`, `warnings`, `summary`, `confidence`).
- [x] Add integration tests for response contract stability.

## 7) iOS Integration
- [ ] Connect iOS app networking to backend `POST /analyze-label`.
- [ ] Build Analysis Result screen sections:
  - [ ] summary
  - [ ] nutrition table
  - [ ] ingredients/allergens/warnings
  - [ ] confidence/uncertainty hints
- [ ] Add save/delete from result screen.

## 8) Preferences + Personalization
- [ ] Build Preferences UI (allergens, dietary prefs, avoid-list, nutrition goals).
- [x] Pass preferences with analyze requests.
- [x] Highlight conflicts in results (contains/may contain/avoid-list matches).
- [x] Use conservative allergy wording (no safety guarantees).

## 9) Reliability + Privacy Hardening
- [ ] Add retry/failure UX for OCR/API issues.
- [ ] Add manual correction loop before analysis by default.
- [x] Ensure on-device OCR and text-only upload default.
- [x] Add explicit opt-in if image upload is ever enabled.
- [ ] Add disclaimer and safety copy in app settings/results.

## 10) Acceptance Criteria (Working Copy)
- [ ] User can capture or pick a label image.
- [ ] OCR text appears and is editable.
- [x] Analyze returns structured nutrition + ingredient output.
- [x] Allergens and warnings are detected and displayed.
- [x] Summary is generated and understandable.
- [ ] Scan can be saved and reopened from history.
- [ ] At least 20–50 mixed Singapore/US fixtures run in parser test suite.

## 11) Launch-Readiness for Internal Beta
- [ ] Smoke test on physical iPhone devices with varied lighting.
- [ ] Validate top allergy scenarios against physical labels.
- [ ] Review legal/safety copy for non-medical positioning.
- [ ] Freeze MVP scope and create post-MVP backlog (barcode, sync, Android).
