# Ingredient Concern Taxonomy

NutriScan should highlight ingredients that shoppers often miss or may want to
review more carefully. This is general information, not medical advice.

## MVP Concern Groups

### Added Sweeteners

Flag obvious added sugars and syrups that appear in ingredient lists:

- high fructose corn syrup
- corn syrup
- glucose syrup
- fructose
- dextrose
- maltodextrin
- cane sugar

### Highly Processed Fats

Flag common oil/fat terms that often deserve a closer look:

- hydrogenated oil
- partially hydrogenated oil
- shortening
- palm oil

### Additives And Preservatives

Flag common additive classes or examples that users may want to review:

- artificial flavors
- artificial colours / artificial colors
- sodium nitrite
- sodium benzoate
- potassium sorbate
- monosodium glutamate / msg

## Wording Rules

- Use "review" or "flagged" language, not "unsafe".
- Explain why a term was flagged in plain English.
- Keep allergy claims separate from general ingredient concerns.
- Prefer deterministic matches first; optional LLM interpretation can add
  explanations later, but should not override declared allergen parsing.

## Open Questions

- Which concern groups should be user-configurable at launch?
- Should the UI sort concerns by severity, label order, or user preferences?
- What level of explanation is enough without feeling like medical advice?
