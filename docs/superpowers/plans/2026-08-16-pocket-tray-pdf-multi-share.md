# Pocket Tray PDF and Multi-Object Share Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add exact-byte PDF capture/preview/export and independent multi-attachment share outcomes for issue #7.

**Architecture:** Reuse the content-addressed `TrayAsset` store with UTI-specific validation. Route PDF and existing content through one provider adapter, then process flattened share attachments sequentially so each has its own persistence transaction and result.

**Tech Stack:** Swift 6, SwiftUI, UIKit share extension, PDFKit/CoreGraphics, UniformTypeIdentifiers, coordinated JSON persistence, XCTest.

## Task 1: PDF domain and storage

- [ ] Add red tests for valid, invalid, encrypted/empty, exact-limit, over-limit, relaunch, export, corruption, and dedup behavior.
- [ ] Add `PDFPayload`, PDF UTI/structure validation, `.pdf` capture content/item kind, and asset validation dispatch.
- [ ] Keep legacy image/text/URL decoding and behavior unchanged.
- [ ] Run targeted and full tests; commit the domain/storage slice.

## Task 2: Provider and multi-object capture

- [ ] Add red data-backed/file-backed PDF provider tests.
- [ ] Add red batch tests for all-success, mixed success, independent 25 MB failures, source ordering, and zero partial records.
- [ ] Extend the provider contract and implement sequential `captureAll` typed outcomes.
- [ ] Flatten every extension attachment and report accepted/rejected counts while preserving cancellation-before-first-commit semantics.
- [ ] Expand the extension activation rule for PDFs and multiple attachments.
- [ ] Run targeted and full tests; commit the share slice.

## Task 3: PDF UI

- [ ] Add bounded first-page thumbnail loading and tests.
- [ ] Add PDF row/detail routing, PDFKit preview, unavailable state, and original-byte ShareLink export.
- [ ] Verify normal and accessibility text sizes in Simulator; commit the UI slice.

## Task 4: Release gate and publication

- [ ] Run `git diff --check` and the full test suite.
- [ ] Produce signed simulator and physical-device builds; install and smoke-test where available.
- [ ] Obtain zero-finding spec and standards reviews.
- [ ] Commit remaining hardening, push all issue #7 commits to `main`, verify the remote SHA, close #7, and immediately continue to #8.
