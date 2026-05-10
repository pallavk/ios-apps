# NutriScan API (uv)

## Quick start
```bash
cd backend/nutriscan-api
uv sync --group dev
uv run pytest
uv run uvicorn app.main:app --reload
```

## Local configuration

Copy `.env.example` to `.env` for local overrides if needed. The MVP backend is
text-only by default; OCR should run on-device in the iOS app.
