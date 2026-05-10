from fastapi.testclient import TestClient
from pathlib import Path

from app.main import app


client = TestClient(app)
FIXTURES_DIR = Path(__file__).parent / "fixtures"


def test_health() -> None:
    response = client.get("/health")
    assert response.status_code == 200
    assert response.json() == {"status": "ok"}


def test_analyze_label_accepts_region_hint() -> None:
    payload = {
        "ocr_text": "Ingredients: sugar. Contains: milk. May contain peanuts.",
        "scan_type": "nutrition_and_ingredients",
        "region_hint": "sg",
        "user_preferences": {
            "allergens": ["milk"],
            "avoid_ingredients": ["gelatin"],
            "dietary_preferences": ["vegetarian"],
        },
    }

    response = client.post("/analyze-label", json=payload)
    assert response.status_code == 200

    body = response.json()
    assert "summary" in body
    assert "SG" in body["summary"]
    assert len(body["warnings"]) >= 1


def test_analyze_label_requires_ocr_text() -> None:
    payload = {"ocr_text": "", "scan_type": "unknown", "region_hint": "auto"}
    response = client.post("/analyze-label", json=payload)
    assert response.status_code == 422


def test_analyze_label_returns_structured_nutrition_fields_from_us_fixture() -> None:
    payload = {
        "ocr_text": (FIXTURES_DIR / "us" / "nutrition_with_added_sugar.txt").read_text(),
        "scan_type": "nutrition",
        "region_hint": "us",
    }

    response = client.post("/analyze-label", json=payload)

    assert response.status_code == 200
    nutrition = response.json()["nutrition"]
    assert nutrition["calories"] == 230
    assert nutrition["serving_size_text"] == "2/3 cup (55g)"
    assert nutrition["added_sugar_g"] == 10
    assert nutrition["total_sugar_g"] == 12
    assert nutrition["sodium_mg"] == 160
    assert nutrition["total_fat_g"] == 8
    assert nutrition["total_carbohydrate_g"] == 37
    assert nutrition["protein_g"] == 3


def test_analyze_label_returns_structured_allergen_fields_from_sg_fixture() -> None:
    payload = {
        "ocr_text": (FIXTURES_DIR / "sg" / "ingredients_allergens_warning.txt").read_text(),
        "scan_type": "ingredients",
        "region_hint": "sg",
    }

    response = client.post("/analyze-label", json=payload)

    assert response.status_code == 200
    ingredient_analysis = response.json()["ingredient_analysis"]
    assert ingredient_analysis["ingredients"] == [
        "wheat flour",
        "sugar",
        "vegetable oil",
        "milk powder",
        "soy lecithin",
        "salt",
    ]
    assert ingredient_analysis["contains_allergens"] == ["wheat", "milk", "soy"]
    assert ingredient_analysis["may_contain_allergens"] == ["peanuts", "tree nuts"]
    assert ingredient_analysis["facility_allergen_warnings"] == [
        "Manufactured in a facility that also processes egg and sesame products."
    ]


def test_analyze_label_applies_sg_nutrition_normalization_notes() -> None:
    payload = {
        "ocr_text": (FIXTURES_DIR / "sg" / "nutrition_panel.txt").read_text(),
        "scan_type": "nutrition",
        "region_hint": "sg",
    }

    response = client.post("/analyze-label", json=payload)

    assert response.status_code == 200
    body = response.json()
    assert body["nutrition"]["calories"] == 190
    assert body["nutrition"]["serving_size_text"] == "40g"
    assert body["nutrition"]["protein_g"] == 5.5
    assert body["nutrition"]["total_carbohydrate_g"] == 28
    assert body["confidence"]["parser"] >= 0.7
    assert "sg_nutrition_panel" in body["confidence"]["notes"]
