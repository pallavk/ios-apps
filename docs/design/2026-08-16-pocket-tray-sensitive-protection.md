# Pocket Tray Sensitive Protection Design

## Status

Approved product work tracked by GitHub issue #9.

## Goal

Reduce accidental exposure of likely one-time codes, payment-card numbers, and private keys without using a model or allowing classification to affect retention, deletion, expiry, or durable storage integrity. Add an optional system-authentication app lock that is off by default.

## Deterministic Classification

`SensitiveContentClassifying` is a synchronous, deterministic boundary. Production uses transparent rules:

- one-time codes require a nearby OTP, verification, passcode, one-time, or two-factor context rather than flagging every short number;
- payment-card candidates contain 13–19 digits, pass Luhn, and are not a repeated single digit;
- private keys require recognizable PEM/OpenSSH private-key begin markers.

The persisted `SensitivityAssessment` contains stable reason values and an explicit override flag. It contains no model output. Tests inject or call the deterministic classifier directly.

For text and URL captures, classification happens during preparation. A flagged prepared capture cannot commit until the caller explicitly acknowledges the warning. The normal Paste flow presents that warning and offers Save Anyway or Cancel. Share-extension items that require acknowledgment are rejected safely with a typed explanation rather than silently saved; the app Paste flow remains the deliberate override path.

Image OCR can reveal sensitive text only after durable capture. When local analysis completes, the same deterministic classifier evaluates the extracted searchable text and persists a flag without changing the original or its lifecycle. The next analysis refresh immediately hides the preview.

Editing textual content reclassifies it. Deduplicating the same content preserves a user override; materially changed content receives a fresh assessment.

## Preview Protection and Override

Flagged, non-overridden objects render a semantic cover instead of their text, image, or PDF preview. The hidden content is absent from the accessibility tree. The cover names the broad reason without reproducing the secret and provides deliberate Reveal and Mark Not Sensitive actions.

Reveal is session-only UI state and resets when the view/app is recreated or backgrounded. Mark Not Sensitive persists an override on the item and makes the ordinary row available without deleting or recapturing it. Editing the underlying text clears the stale override and reclassifies the new value.

Copy/open/preview actions are unavailable while covered. Revealing does not alter storage or retention.

## Optional App Lock

App lock is stored as a local Boolean setting and defaults to off. A small `AppAuthenticating` boundary wraps Local Authentication. Production evaluates `.deviceOwnerAuthentication`, allowing Face ID/Touch ID where available and the system passcode fallback. Tests inject deterministic outcomes.

Enabling lock requires a successful system authentication. When enabled, leaving the active scene locks the app; returning active presents a neutral lock screen before constructing the tray UI, avoiding visible content snapshots. Authentication failure leaves the app locked with a Retry action. The setting can only be disabled from an already unlocked session.

The share extension remains a capture surface and does not reveal tray contents, so app lock does not block sharing into the tray. Sensitive pre-commit acknowledgment remains separately enforced.

## Testing and Release Gate

Tests cover each deterministic rule and representative false positives, Luhn boundaries, explicit commit acknowledgment, post-OCR flagging, edit reclassification, override persistence, preview-state semantics, app-lock defaults/transitions/fallback policy, and backward-compatible decoding. Final gates are the full suite, signed simulator/device builds, normal/accessibility protected-row inspection, locked/unlocked inspection where the device permits it, and zero spec/standards findings.
