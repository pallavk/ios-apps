import re

from .schemas import IngredientAnalysis, NutritionFacts


def confidence_for(text: str, region_hint: str) -> dict[str, float | list[str]]:
    notes: list[str] = []
    parser_confidence = 0.5

    if region_hint == "sg" and re.search(r"\bnutrition information\b|\benergy\s+\d", text, re.IGNORECASE):
        notes.append("sg_nutrition_panel")
        parser_confidence = 0.75
    elif region_hint == "us" and re.search(r"\bnutrition facts\b", text, re.IGNORECASE):
        notes.append("us_nutrition_facts")
        parser_confidence = 0.75

    return {"parser": parser_confidence, "notes": notes}


def parse_nutrition(text: str) -> NutritionFacts:
    nutrition: dict[str, float | int | str | None] = {}

    serving_size = re.search(r"\bserving size:?\s+(.+)", text, re.IGNORECASE)
    if serving_size:
        nutrition["serving_size_text"] = serving_size.group(1).strip()

    calories = re.search(r"\b(?:calories|energy)\s+(\d+(?:\.\d+)?)", text, re.IGNORECASE)
    if calories:
        nutrition["calories"] = _number(calories.group(1))

    added_sugar = re.search(
        r"\bincludes\s+(\d+(?:\.\d+)?)\s*g\s+added sugars?\b",
        text,
        re.IGNORECASE,
    )
    if added_sugar:
        nutrition["added_sugar_g"] = _number(added_sugar.group(1))

    nutrient_patterns = {
        "total_sugar_g": r"\btotal sugars?\s+(\d+(?:\.\d+)?)\s*g\b",
        "sodium_mg": r"\bsodium\s+(\d+(?:\.\d+)?)\s*mg\b",
        "total_fat_g": r"\btotal fat\s+(\d+(?:\.\d+)?)\s*g\b",
        "total_carbohydrate_g": r"\b(?:total carbohydrate|carbohydrate)\s+(\d+(?:\.\d+)?)\s*g\b",
        "protein_g": r"\bprotein\s+(\d+(?:\.\d+)?)\s*g\b",
    }
    for field_name, pattern in nutrient_patterns.items():
        match = re.search(pattern, text, re.IGNORECASE)
        if match:
            nutrition[field_name] = _number(match.group(1))

    return NutritionFacts(**nutrition)


def parse_ingredient_analysis(text: str) -> IngredientAnalysis:
    ingredients = _parse_ingredients(text)
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
        ingredients=ingredients,
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


def _parse_ingredients(text: str) -> list[str]:
    lines = _lines(text)
    for index, line in enumerate(lines):
        match = re.match(r"ingredients?:\s*(.*)", line, re.IGNORECASE)
        if not match:
            continue

        ingredient_text = match.group(1).strip()
        if not ingredient_text and index + 1 < len(lines):
            ingredient_text = lines[index + 1]
        return _split_ingredients(ingredient_text)

    return []


def _split_ingredients(value: str) -> list[str]:
    cleaned = value.rstrip(". ")
    return [part.strip().lower() for part in cleaned.split(",") if part.strip()]


def _dedupe(values: list[str]) -> list[str]:
    deduped: list[str] = []
    for value in values:
        if value not in deduped:
            deduped.append(value)
    return deduped
