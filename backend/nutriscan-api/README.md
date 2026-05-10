# NutriScan API (uv)

## Quick start
```bash
cd backend/nutriscan-api
uv sync --group dev
uv run pytest
uv run uvicorn app.main:app --reload
