import re

from .schemas import IngredientAnalysis, NutritionFacts


def parse_nutrition(text: str) -> NutritionFacts:
    nutrition: dict[str, float | int | str | None] = {}

    serving_size = re.search(r"\bserving size\s+(.+)", text, re.IGNORECASE)
    if serving_size:
        nutrition["serving_size_text"] = serving_size.group(1).strip()

    calories = re.search(r"\bcalories\s+(\d+(?:\.\d+)?)", text, re.IGNORECASE)
    if calories:
        nutrition["calories"] = _number(calories.group(1))

    added_sugar = re.search(
        r"\bincludes\s+(\d+(?:\.\d+)?)\s*g\s+added sugars?\b",
        text,
        re.IGNORECASE,
    )
    if added_sugar:
        nutrition["added_sugar_g"] = _number(added_sugar.group(1))

    return NutritionFacts(**nutrition)


def parse_ingredient_analysis(text: str) -> IngredientAnalysis:
    contains_allergens: list[str] = []
    may_contain_allergens: list[str] = []
    facility_allergen_warnings: list[str] = []

    for line in _lines(text):
        contains_match = re.search(r"\bcontains:\s*(.+)", line, re.IGNORECASE)
        if contains_match:
            contains_allergens.extend(_split_allergen_list(contains_match.group(1)))

        may_contain_match = re.search(
            r"\bmay contain(?: traces of)?\s+(.+)",
            line,
            re.IGNORECASE,
        )
        if may_contain_match:
            may_contain_allergens.extend(_split_allergen_list(may_contain_match.group(1)))

        facility_match = re.search(
            r"\bfacility\b.*\b(processes|processed|handles|manufactures)\b",
            line,
            re.IGNORECASE,
        )
        if facility_match:
            facility_allergen_warnings.append(line)

    return IngredientAnalysis(
        contains_allergens=_dedupe(contains_allergens),
        may_contain_allergens=_dedupe(may_contain_allergens),
        facility_allergen_warnings=facility_allergen_warnings,
    )


def _number(value: str) -> int | float:
    parsed = float(value)
    if parsed.is_integer():
        return int(parsed)
    return parsed


def _lines(text: str) -> list[str]:
    return [line.strip() for line in text.splitlines() if line.strip()]


def _split_allergen_list(value: str) -> list[str]:
    cleaned = re.sub(r"\bproducts?\b", "", value, flags=re.IGNORECASE)
    cleaned = cleaned.rstrip(". ")
    parts = re.split(r",|\band\b|&", cleaned, flags=re.IGNORECASE)
    return [part.strip().lower() for part in parts if part.strip()]


def _dedupe(values: list[str]) -> list[str]:
    deduped: list[str] = []
    for value in values:
        if value not in deduped:
            deduped.append(value)
    return deduped
