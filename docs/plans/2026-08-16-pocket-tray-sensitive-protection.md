# Pocket Tray Sensitive Protection Implementation Plan

> **Implementation workflow:** Use Matt Pocock's TDD skill in vertical slices, then review through the agreed public seams.

**Goal:** Add deterministic sensitive-object warnings, protected previews, override/reveal behavior, and optional system-auth app locking for issue #9.

**Architecture:** Persist framework-neutral sensitivity metadata on each object. A deterministic injected classifier runs before textual commits and after OCR. SwiftUI replaces protected content with a semantic cover until deliberate reveal/override. A separate injectable app-lock state machine uses Local Authentication with system fallback.

## Task 1: Classifier and domain persistence

- [ ] Write red rule tests for contextual OTPs, Luhn cards, private-key markers, and false positives.
- [ ] Add sensitivity domain types, backward-compatible coding, edit invalidation, and override mutation.
- [ ] Add explicit acknowledgment to flagged text commit and typed share rejection.
- [ ] Run full tests and commit.

## Task 2: OCR integration and protected rows

- [ ] Write red tests proving OCR-derived sensitivity persists without affecting the original/lifecycle.
- [ ] Classify analysis searchable text with the deterministic boundary.
- [ ] Add semantic protected rows, session reveal, persistent false-positive override, and background re-hide.
- [ ] Verify normal, accessibility-size, and VoiceOver semantics; run tests and commit.

## Task 3: Optional app lock

- [ ] Write red state-machine tests for off-by-default, enable authentication, scene locking, retry, disable, and failure.
- [ ] Implement `AppAuthenticating`, Local Authentication owner-auth policy, persisted setting, and lock gate.
- [ ] Add Settings UI and neutral locked/retry UI without constructing visible tray content while locked.
- [ ] Run tests, signed builds, and visual checks; commit.

## Task 4: Release

- [ ] Run full tests, signed simulator/device builds, install/smoke checks, and `git diff --check`.
- [ ] Obtain zero-finding spec and standards reviews.
- [ ] Push to `main`, verify remote SHA, close #9, and continue to #10.
