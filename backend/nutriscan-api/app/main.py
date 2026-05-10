import re

from fastapi import FastAPI

from .parser import confidence_for, parse_ingredient_analysis, parse_nutrition
from .schemas import AnalyzeLabelRequest, AnalyzeLabelResponse, IngredientAnalysis

app = FastAPI(title="NutriScan API", version="0.1.0")


@app.get("/health")
def health() -> dict[str, str]:
    return {"status": "ok"}


@app.post("/analyze-label", response_model=AnalyzeLabelResponse)
def analyze_label(payload: AnalyzeLabelRequest) -> AnalyzeLabelResponse:
    text = payload.ocr_text.lower()
    ingredient_analysis = parse_ingredient_analysis(payload.ocr_text)

    warnings: list[str] = []
    if "contains" in text:
        warnings.append("Contains statement detected; verify the physical label before making allergy decisions.")
    if "may contain" in text or "facility" in text or "equipment" in text:
        warnings.append("Cross-contamination warning text detected.")
    warnings.extend(_preference_flags(ingredient_analysis, payload))

    summary = (
        f"Scan parsed in {payload.region_hint.upper()} mode ({payload.scan_type}). "
        "This is an early MVP response; review extracted text before making decisions."
    )

    return AnalyzeLabelResponse(
        nutrition=parse_nutrition(payload.ocr_text),
        ingredient_analysis=ingredient_analysis,
        warnings=warnings,
        summary=summary,
        confidence=confidence_for(payload.ocr_text, payload.region_hint),
    )


def _preference_flags(
    ingredient_analysis: IngredientAnalysis,
    payload: AnalyzeLabelRequest,
) -> list[str]:
    flags: list[str] = []
    preferred_allergens = [_normalize_match(value) for value in payload.user_preferences.allergens]
    avoid_ingredients = [_normalize_match(value) for value in payload.user_preferences.avoid_ingredients]

    for allergen in ingredient_analysis.contains_allergens:
        if _normalize_match(allergen) in preferred_allergens:
            flags.append(f"Declared allergen match: {allergen}")

    for allergen in ingredient_analysis.may_contain_allergens:
        if _normalize_match(allergen) in preferred_allergens:
            flags.append(f"Possible cross-contact allergen match: {allergen}")

    for warning in ingredient_analysis.facility_allergen_warnings:
        normalized_warning = _normalize_match(warning)
        for allergen in preferred_allergens:
            if re.search(rf"\b{re.escape(allergen)}\b", normalized_warning):
                flags.append(f"Facility warning mentions allergen preference: {allergen}")

    for ingredient in ingredient_analysis.ingredients:
        if _normalize_match(ingredient) in avoid_ingredients:
            flags.append(f"Avoid ingredient match: {ingredient}")

    ingredient_analysis.flags = flags
    return [
        f"{flag}; verify the physical label before making decisions."
        for flag in flags
    ]


def _normalize_match(value: str) -> str:
    return " ".join(value.lower().split())
