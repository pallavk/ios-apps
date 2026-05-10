from fastapi import FastAPI

from .parser import confidence_for, parse_ingredient_analysis, parse_nutrition
from .schemas import AnalyzeLabelRequest, AnalyzeLabelResponse

app = FastAPI(title="NutriScan API", version="0.1.0")


@app.get("/health")
def health() -> dict[str, str]:
    return {"status": "ok"}


@app.post("/analyze-label", response_model=AnalyzeLabelResponse)
def analyze_label(payload: AnalyzeLabelRequest) -> AnalyzeLabelResponse:
    text = payload.ocr_text.lower()

    warnings: list[str] = []
    if "contains" in text:
        warnings.append("Contains statement detected; verify allergens on physical label.")
    if "may contain" in text or "processed in a facility" in text:
        warnings.append("Cross-contamination warning text detected.")

    summary = (
        f"Scan parsed in {payload.region_hint.upper()} mode ({payload.scan_type}). "
        "This is an early MVP response; review extracted text before making decisions."
    )

    return AnalyzeLabelResponse(
        nutrition=parse_nutrition(payload.ocr_text),
        ingredient_analysis=parse_ingredient_analysis(payload.ocr_text),
        warnings=warnings,
        summary=summary,
        confidence=confidence_for(payload.ocr_text, payload.region_hint),
    )
