# NutriScan MVP PRD

## 1) Product Overview
NutriScan is an iOS-first label understanding app that converts photos of nutrition labels and ingredient text into structured, useful, and personalized insights.

### Problem
Users can read labels, but they are often hard to interpret quickly—especially for allergens, added sugars, and dietary preferences.

### MVP Goal
Deliver a reliable scan → OCR → parse → explain → save flow for packaged food/supplement labels across regions, with initial support for Singapore and US label formats.

## 2) Target Users
- People with allergen concerns.
- People following dietary preferences (vegan, vegetarian, low sugar, low sodium, gluten-free, dairy-free).
- Shoppers comparing products quickly.

## 3) MVP Scope
### Included
- iOS app (SwiftUI) only.
- Camera/photo capture of Nutrition Facts and/or ingredients.
- OCR review and manual text correction.
- Backend-assisted parsing from OCR text.
- Nutrition label parsing for Singapore and US common fields/sections.
- Ingredients parsing.
- Allergen + facility-warning detection.
- Preference-based warnings.
- Plain-English summary.
- Local save/delete scan history.

### Excluded
- Android app.
- Full global label coverage at launch (beyond Singapore + US).
- Barcode/product DB as source of truth.
- Cloud sync/accounts.
- Medical guidance.
- Health score.

## 4) Core User Stories
1. As a user, I can scan a nutrition label and see structured nutrition values.
2. As a user, I can scan ingredients text and detect allergens or "may contain" warnings.
3. As a user, I can set avoid-lists/preferences and get personalized warnings.
4. As a user, I can save scans and revisit results later.

## 5) Functional Requirements
- Capture image from camera and photo library.
- Run OCR locally using Apple Vision.
- Detect/segment text into likely sections: Nutrition Facts, Ingredients, Allergens/Warnings.
- Allow manual OCR corrections prior to analysis.
- Parse nutrition and ingredients into structured JSON.
- Generate plain-English summary with confidence-aware wording.
- Save scan, parsed output, and source OCR text locally.

## 6) Non-Functional Requirements
- Works with imperfect photos where possible.
- Transparent uncertainty (confidence where available).
- Privacy-first defaults (local OCR; text-only backend by default).
- No medical advice claims.

## 7) Safety & Compliance Language
- "NutriScan provides general nutrition and ingredient information and is not medical advice."
- "No matching allergens were detected in scanned text" instead of absolute safety claims.
- Remind users to verify physical labels for high-risk allergy scenarios.

## 8) Regional Scope (MVP)
- Primary regional support: Singapore and US packaged labels.
- Support common Singapore-market wording/format variations in nutrition, ingredients, and allergen declarations.
- Display region-aware parsing notes when label structure is ambiguous.

## 9) Success Metrics (MVP)
- OCR usability: users can correct OCR in <30 seconds median.
- Parsing completeness on test set: >=85% for core nutrition fields.
- Allergen detection recall on fixture set: >=95% for declared allergens.
- Scan-to-result latency target: <5 seconds median on modern iPhones (excluding network variability).

## 10) Risks and Mitigations
- OCR quality variance: crop guidance + retake + manual correction.
- Label format variation: fixture-driven parser tests + confidence + fallback UI.
- LLM hallucinations: schema validation + source text citation per claim.
- Liability risk: conservative language + disclaimers.

## 11) Milestones
1. OCR prototype in iOS app.
2. Parsing prototype with fixtures/tests.
3. End-to-end analysis in app.
4. Save/history/preferences.
5. Hardening with 20–50 real label test images.


## 12) Engineering Approach
- Development follows a red/green/refactor TDD workflow for parser and API logic.
- Fixture-first tests are required for nutrition parsing, ingredient extraction, and allergen/warning detection.
- UI/camera flows use a pragmatic mix of unit tests, snapshot/manual tests, and device validation where strict TDD is less practical.

