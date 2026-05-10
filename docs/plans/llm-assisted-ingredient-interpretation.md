# Optional LLM-Assisted Ingredient Interpretation

## Goal

Add an opt-in backend step that explains ingredients and borderline concerns in
plain English after deterministic parsing has already produced structured
nutrition, allergen, facility-warning, and concern fields.

## Non-Goals

- Do not replace deterministic allergen parsing.
- Do not make absolute safety, medical, or diagnosis claims.
- Do not upload images by default; send OCR text only.
- Do not enable the LLM path unless the user explicitly opts in.

## OpenAI API Requirement

OpenAI API calls require an API key from the OpenAI platform dashboard. A
ChatGPT subscription is useful for manual testing in ChatGPT, but it is not the
same as backend API credentials for an app. The backend should therefore use an
`OPENAI_API_KEY` environment variable when optional LLM interpretation is
enabled.

## Proposed Backend Switches

```text
NUTRISCAN_ENABLE_LLM_INGREDIENT_INTERPRETATION=false
OPENAI_API_KEY=
OPENAI_MODEL=gpt-5.2-mini
```

## Data Flow

1. iOS runs local OCR.
2. iOS sends corrected OCR text to the backend.
3. Backend runs deterministic parsing.
4. If the request opts in and server config allows it, backend sends a compact
   text-only ingredient payload to the LLM.
5. Backend validates the LLM output against a strict schema.
6. Backend returns the deterministic fields plus an optional explanation block.

## Prompt Constraints

- Explain why flagged ingredients may deserve review.
- Use cautious language: "may", "review", "consider checking".
- Cite the source ingredient text for each explanation.
- Return "unknown" when evidence is insufficient.
- Never say a product is safe for allergies.

## Testing Plan

- Keep deterministic parser tests independent of OpenAI.
- Add mocked LLM-client tests for schema validation and fallback behavior.
- Add an integration test that confirms the LLM path is skipped by default.
- Add an integration test that confirms the backend fails gracefully if the LLM
  provider is unavailable.
