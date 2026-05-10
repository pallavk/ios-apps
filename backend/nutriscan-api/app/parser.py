import re
from dataclasses import dataclass
from re import Match

from .schemas import IngredientAnalysis, IngredientConcern, NutritionFacts


@dataclass(frozen=True)
class LineMatch:
    line: str
    match: Match[str]


def confidence_for(text: str, region_hint: str) -> dict[str, float | list[str]]:
    text = normalize_ocr_text(text)
    effective_region = detect_region(text, region_hint)
    notes: list[str] = []
    parser_confidence = 0.5

    if effective_region == "sg" and re.search(r"\bnutrition information\b|\benergy\s+\d", text, re.IGNORECASE):
        notes.append("sg_nutrition_panel")
        parser_confidence = 0.75
    elif effective_region == "us" and re.search(r"\bnutrition facts\b", text, re.IGNORECASE):
        notes.append("us_nutrition_facts")
        parser_confidence = 0.75

    return {
        "parser": parser_confidence,
        "detected_region": effective_region,
        "sections_detected": detect_sections(text),
        "notes": notes,
    }


def detect_sections(text: str) -> list[str]:
    sections: list[str] = []
    normalized_text = normalize_ocr_text(text)
    if re.search(r"\bnutrition (facts|information)\b|\bcalories\b|\benergy\s+\d", normalized_text, re.IGNORECASE):
        sections.append("nutrition")
    if re.search(r"\bingredients?:", normalized_text, re.IGNORECASE):
        sections.append("ingredients")
    if re.search(r"\bcontains:|\bmay contain\b|\bfacility\b", normalized_text, re.IGNORECASE):
        sections.append("allergens")
    return sections


def detect_region(text: str, region_hint: str) -> str:
    if region_hint != "auto":
        return region_hint
    normalized_text = normalize_ocr_text(text)
    if re.search(r"\bnutrition facts\b", normalized_text, re.IGNORECASE):
        return "us"
    if re.search(r"\bnutrition information\b|\benergy\s+\d", normalized_text, re.IGNORECASE):
        return "sg"
    return "auto"


def normalize_ocr_text(text: str) -> str:
    return "\n".join(" ".join(line.split()) for line in text.splitlines())


def parse_nutrition(text: str) -> NutritionFacts:
    text = normalize_ocr_text(text)
    nutrition: dict[str, float | int | str | None] = {}
    source_text: dict[str, str] = {}
    field_confidence: dict[str, float] = {}

    serving_size = _search_line(text, r"\bserving size:?\s+(.+)")
    if serving_size:
        nutrition["serving_size_text"] = serving_size.match.group(1).strip()
        source_text["serving_size_text"] = serving_size.line
        field_confidence["serving_size_text"] = 0.85

    calories = _search_line(text, r"\b(?:calories|energy)\s+(\d+(?:\.\d+)?)")
    if calories:
        nutrition["calories"] = _number(calories.match.group(1))
        source_text["calories"] = calories.line
        field_confidence["calories"] = 0.9

    added_sugar = _search_line(
        text,
        r"\bincludes\s+(\d+(?:\.\d+)?)\s*g\s+added sugars?\b",
    )
    if added_sugar:
        nutrition["added_sugar_g"] = _number(added_sugar.match.group(1))
        source_text["added_sugar_g"] = added_sugar.line
        field_confidence["added_sugar_g"] = 0.9

    nutrient_patterns = {
        "total_sugar_g": r"\btotal sugars?\s+(\d+(?:\.\d+)?)\s*g\b",
        "sodium_mg": r"\bsodium\s+(\d+(?:\.\d+)?)\s*mg\b",
        "total_fat_g": r"\btotal fat\s+(\d+(?:\.\d+)?)\s*g\b",
        "total_carbohydrate_g": r"\b(?:total carbohydrate|carbohydrate)\s+(\d+(?:\.\d+)?)\s*g\b",
        "protein_g": r"\bprotein\s+(\d+(?:\.\d+)?)\s*g\b",
    }
    for field_name, pattern in nutrient_patterns.items():
        match = _search_line(text, pattern)
        if match:
            nutrition[field_name] = _number(match.match.group(1))
            source_text[field_name] = match.line
            field_confidence[field_name] = 0.85

    nutrition["source_text"] = source_text
    nutrition["field_confidence"] = field_confidence

    return NutritionFacts(**nutrition)


def parse_ingredient_analysis(text: str) -> IngredientAnalysis:
    text = normalize_ocr_text(text)
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
        ingredient_concerns=_ingredient_concerns(text, ingredients),
    )


def _number(value: str) -> int | float:
    parsed = float(value)
    if parsed.is_integer():
        return int(parsed)
    return parsed


def _lines(text: str) -> list[str]:
    return [line.strip() for line in text.splitlines() if line.strip()]


def _search_line(text: str, pattern: str) -> LineMatch | None:
    for line in _lines(text):
        match = re.search(pattern, line, re.IGNORECASE)
        if match:
            return LineMatch(line=line, match=match)
    return None


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


def _ingredient_concerns(text: str, ingredients: list[str]) -> list[IngredientConcern]:
    source_line = _ingredient_source_line(text)
    concerns: list[IngredientConcern] = []
    for ingredient in ingredients:
        concern = _concern_for(ingredient, source_line)
        if concern:
            concerns.append(concern)
    return concerns


def _ingredient_source_line(text: str) -> str:
    for line in _lines(text):
        if re.match(r"ingredients?:", line, re.IGNORECASE):
            return line
    return ""


def _concern_for(ingredient: str, source_line: str) -> IngredientConcern | None:
    concern_rules = [
        (
            ["high fructose corn syrup", "corn syrup", "glucose syrup", "fructose", "dextrose", "maltodextrin", "cane sugar"],
            "added_sweetener",
            "Added sweetener term detected in the ingredient list.",
        ),
        (
            ["partially hydrogenated", "hydrogenated", "shortening", "palm oil"],
            "highly_processed_fat",
            "Hydrogenated fat/oil term detected in the ingredient list.",
        ),
        (
            ["artificial flavor", "artificial colour", "artificial color", "sodium nitrite", "sodium benzoate", "potassium sorbate", "monosodium glutamate", "msg"],
            "additive_or_preservative",
            "Additive or preservative term detected in the ingredient list.",
        ),
    ]
    for terms, category, reason in concern_rules:
        if any(term in ingredient for term in terms):
            return IngredientConcern(
                ingredient=ingredient,
                category=category,
                severity="review",
                reason=reason,
                source_text=source_line,
            )
    return None


def _dedupe(values: list[str]) -> list[str]:
    deduped: list[str] = []
    for value in values:
        if value not in deduped:
            deduped.append(value)
    return deduped
