import Foundation

struct AnalyzeLabelPayload: Encodable {
    var ocrText: String
    var scanType: String
    var regionHint: String
    var userPreferences: UserPreferenceSelection

    enum CodingKeys: String, CodingKey {
        case ocrText = "ocr_text"
        case scanType = "scan_type"
        case regionHint = "region_hint"
        case userPreferences = "user_preferences"
    }
}

struct UserPreferenceSelection: Codable {
    var allergens: [String] = []
    var avoidIngredients: [String] = []
    var dietaryPreferences: [String] = []
    var nutritionGoals: NutritionGoals?

    enum CodingKeys: String, CodingKey {
        case allergens
        case avoidIngredients = "avoid_ingredients"
        case dietaryPreferences = "dietary_preferences"
        case nutritionGoals = "nutrition_goals"
    }
}

struct NutritionGoals: Codable {
    var maxAddedSugarG: Double?
    var maxSodiumMg: Double?

    enum CodingKeys: String, CodingKey {
        case maxAddedSugarG = "max_added_sugar_g"
        case maxSodiumMg = "max_sodium_mg"
    }
}

struct LabelAnalysis: Decodable {
    var nutrition: NutritionFacts
    var ingredientAnalysis: IngredientAnalysis
    var warnings: [String]
    var summary: String
    var confidence: [String: JSONValue]

    enum CodingKeys: String, CodingKey {
        case nutrition
        case ingredientAnalysis = "ingredient_analysis"
        case warnings
        case summary
        case confidence
    }
}

struct NutritionFacts: Decodable {
    var calories: Double?
    var servingSizeText: String?
    var addedSugarG: Double?
    var totalSugarG: Double?
    var sodiumMg: Double?
    var totalFatG: Double?
    var totalCarbohydrateG: Double?
    var proteinG: Double?
    var sourceText: [String: String]
    var fieldConfidence: [String: Double]

    enum CodingKeys: String, CodingKey {
        case calories
        case servingSizeText = "serving_size_text"
        case addedSugarG = "added_sugar_g"
        case totalSugarG = "total_sugar_g"
        case sodiumMg = "sodium_mg"
        case totalFatG = "total_fat_g"
        case totalCarbohydrateG = "total_carbohydrate_g"
        case proteinG = "protein_g"
        case sourceText = "source_text"
        case fieldConfidence = "field_confidence"
    }
}

struct IngredientAnalysis: Decodable {
    var ingredients: [String]
    var containsAllergens: [String]
    var mayContainAllergens: [String]
    var facilityAllergenWarnings: [String]
    var flags: [String]

    enum CodingKeys: String, CodingKey {
        case ingredients
        case containsAllergens = "contains_allergens"
        case mayContainAllergens = "may_contain_allergens"
        case facilityAllergenWarnings = "facility_allergen_warnings"
        case flags
    }
}

enum JSONValue: Decodable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    var displayText: String? {
        switch self {
        case .string(let value):
            value
        case .number(let value):
            value.formatted(.number.precision(.fractionLength(0...2)))
        case .bool(let value):
            value ? "true" : "false"
        case .array(let values):
            values.compactMap(\.displayText).joined(separator: ", ")
        case .object, .null:
            nil
        }
    }
}

enum NutriScanAPI {
    static var baseURL = URL(string: "http://127.0.0.1:8000")!

    static func analyze(
        ocrText: String,
        preferences: UserPreferenceSelection,
        scanType: String = "nutrition_and_ingredients",
        regionHint: String = "auto"
    ) async throws -> LabelAnalysis {
        let url = baseURL.appending(path: "analyze-label")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            AnalyzeLabelPayload(
                ocrText: ocrText,
                scanType: scanType,
                regionHint: regionHint,
                userPreferences: preferences
            )
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode)
        else {
            throw NutriScanAPIError.requestFailed
        }
        return try JSONDecoder().decode(LabelAnalysis.self, from: data)
    }
}

enum NutriScanAPIError: LocalizedError {
    case requestFailed

    var errorDescription: String? {
        "NutriScan API request failed. Check that the local backend is running."
    }
}
