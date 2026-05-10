from typing import Literal

from pydantic import BaseModel, Field


RegionHint = Literal["sg", "us", "auto"]
ScanType = Literal["nutrition", "ingredients", "nutrition_and_ingredients", "unknown"]


class NutritionGoal(BaseModel):
    max_added_sugar_g: float | None = None
    max_sodium_mg: float | None = None


class UserPreferences(BaseModel):
    allergens: list[str] = Field(default_factory=list)
    avoid_ingredients: list[str] = Field(default_factory=list)
    dietary_preferences: list[str] = Field(default_factory=list)
    nutrition_goals: NutritionGoal | None = None


class AnalyzeLabelRequest(BaseModel):
    ocr_text: str = Field(min_length=1)
    scan_type: ScanType = "unknown"
    region_hint: RegionHint = "auto"
    user_preferences: UserPreferences = Field(default_factory=UserPreferences)


class IngredientAnalysis(BaseModel):
    ingredients: list[str] = Field(default_factory=list)
    contains_allergens: list[str] = Field(default_factory=list)
    may_contain_allergens: list[str] = Field(default_factory=list)
    facility_allergen_warnings: list[str] = Field(default_factory=list)
    flags: list[str] = Field(default_factory=list)


class NutritionFacts(BaseModel):
    calories: int | float | None = None
    serving_size_text: str | None = None
    added_sugar_g: int | float | None = None
    total_sugar_g: int | float | None = None
    sodium_mg: int | float | None = None
    total_fat_g: int | float | None = None
    total_carbohydrate_g: int | float | None = None
    protein_g: int | float | None = None


class AnalyzeLabelResponse(BaseModel):
    nutrition: NutritionFacts = Field(default_factory=NutritionFacts)
    ingredient_analysis: IngredientAnalysis = Field(default_factory=IngredientAnalysis)
    warnings: list[str] = Field(default_factory=list)
    summary: str
    confidence: dict = Field(default_factory=dict)
