# Pocket Tray Local Intelligence Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add offline post-capture OCR, metadata, search indexing, and contextual actions for issue #8.

**Architecture:** Persist framework-neutral `ContentAnalysis` on each item. A deduplicating scheduler invokes an injected `ContentAnalyzing` adapter only after durable capture and retries missing analysis on app reload. Apple framework results translate through fixture DTOs into the durable domain.

## Task 1: Domain, persistence, and scheduling

- [ ] Write red tests for analysis persistence, post-commit ordering, failure isolation, retry, and deterministic injection.
- [ ] Add analysis/action/entity domain types and backward-compatible item coding.
- [ ] Add repository mutation and deduplicated post-capture/pending scheduler.
- [ ] Run full tests and commit.

## Task 2: Apple adapters and fixture translation

- [ ] Write fixture translation tests for OCR, language, entities, URL, phone, address, date, and tracking actions.
- [ ] Implement Vision OCR, Natural Language metadata, `NSDataDetector`, and deterministic tracking patterns locally.
- [ ] Add representative image OCR integration coverage without asserting framework internals.
- [ ] Run full tests and commit.

## Task 3: Search and contextual UI

- [ ] Add analysis fields to local search tests and implementation.
- [ ] Add recognized-action presentation and safe system routing/copy fallback.
- [ ] Verify normal and accessibility layouts; commit.

## Task 4: Release

- [ ] Run full tests, signed builds, install/smoke checks, and `git diff --check`.
- [ ] Obtain zero-finding spec and standards reviews.
- [ ] Push to `main`, verify remote SHA, close #8, and continue to #9.
