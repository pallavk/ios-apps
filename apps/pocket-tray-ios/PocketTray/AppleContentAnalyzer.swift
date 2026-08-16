import Foundation
import NaturalLanguage
import Vision

struct AppleEntityFixture: Equatable, Sendable {
    let kind: ContentEntityKind
    let value: String
}

struct AppleDetectedValue: Equatable, Sendable {
    let kind: ContentActionKind
    let value: String
    let date: Date?

    init(kind: ContentActionKind, value: String, date: Date? = nil) {
        self.kind = kind
        self.value = value
        self.date = date
    }
}

struct AppleAnalysisFixture: Equatable, Sendable {
    let recognizedText: [String]
    let languageCode: String?
    let languageCodes: [String]
    let entities: [AppleEntityFixture]
    let detectedValues: [AppleDetectedValue]

    init(
        recognizedText: [String],
        languageCode: String?,
        languageCodes: [String] = [],
        entities: [AppleEntityFixture],
        detectedValues: [AppleDetectedValue]
    ) {
        self.recognizedText = recognizedText
        self.languageCode = languageCode
        self.languageCodes = languageCodes
        self.entities = entities
        self.detectedValues = detectedValues
    }
}

enum AppleAnalysisTranslator {
    static func translate(
        _ fixture: AppleAnalysisFixture,
        itemText: String
    ) -> ContentAnalysis {
        let searchableLines = uniqueNormalized([itemText] + fixture.recognizedText)
        let entities = uniqueEntities(fixture.entities)
        let actions = uniqueActions(fixture.detectedValues.compactMap(makeAction))
        return ContentAnalysis(
            searchableText: searchableLines.isEmpty ? nil : searchableLines.joined(separator: "\n"),
            languageCode: normalized(fixture.languageCode),
            languageCodes: uniqueNormalized(
                [fixture.languageCode].compactMap { $0 } + fixture.languageCodes
            ),
            entities: entities,
            actions: actions
        )
    }

    private static func makeAction(_ detected: AppleDetectedValue) -> ContentAction? {
        guard let value = normalized(detected.value) else { return nil }
        let target: String?
        switch detected.kind {
        case .url:
            target = URL(string: value)?.absoluteString
        case .phone:
            let prefix = value.hasPrefix("+") ? "+" : ""
            let digits = value.filter(\.isNumber)
            target = digits.isEmpty ? nil : "tel:\(prefix)\(digits)"
        case .address:
            var components = URLComponents(string: "http://maps.apple.com/")
            components?.queryItems = [URLQueryItem(name: "q", value: value)]
            target = components?.url?.absoluteString
        case .date:
            target = detected.date.map { "calshow:\(Int($0.timeIntervalSinceReferenceDate))" }
        case .trackingNumber:
            if value.uppercased().hasPrefix("1Z") {
                var components = URLComponents(string: "https://www.ups.com/track")
                components?.queryItems = [URLQueryItem(name: "tracknum", value: value)]
                target = components?.url?.absoluteString
            } else {
                target = nil
            }
        }
        return ContentAction(kind: detected.kind, value: value, target: target)
    }

    private static func uniqueNormalized(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.compactMap(normalized).filter { seen.insert($0).inserted }
    }

    private static func uniqueEntities(_ fixtures: [AppleEntityFixture]) -> [ContentEntity] {
        var seen: Set<String> = []
        return fixtures.compactMap { fixture in
            guard let value = normalized(fixture.value) else { return nil }
            let key = "\(fixture.kind.rawValue)\u{0}\(value)"
            guard seen.insert(key).inserted else { return nil }
            return ContentEntity(kind: fixture.kind, value: value)
        }
    }

    private static func uniqueActions(_ actions: [ContentAction]) -> [ContentAction] {
        var seen: Set<String> = []
        return actions.filter {
            seen.insert("\($0.kind.rawValue)\u{0}\($0.value)").inserted
        }
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return normalized.isEmpty ? nil : normalized
    }
}

struct AppleContentAnalyzer: ContentAnalyzing {
    private let preferredLanguages: [String]

    init(preferredLanguages: [String] = []) {
        self.preferredLanguages = preferredLanguages
    }

    func analyze(_ input: ContentAnalysisInput) async throws -> ContentAnalysis {
        let recognizedText = try recognizedText(from: input.assetData)
        let combinedText = ([input.text] + recognizedText).joined(separator: "\n")
        let languageCodes = Self.languageHypotheses(in: combinedText)
        let languageCode = languageCodes.first
        let fixture = AppleAnalysisFixture(
            recognizedText: recognizedText,
            languageCode: languageCode,
            languageCodes: languageCodes,
            entities: namedEntities(in: combinedText, languageCode: languageCode),
            detectedValues: detectedValues(in: combinedText)
                + trackingNumbers(in: combinedText)
        )
        return AppleAnalysisTranslator.translate(fixture, itemText: input.text)
    }

    private func recognizedText(from data: Data?) throws -> [String] {
        guard let data else { return [] }
        let request = Self.makeRecognitionRequest(preferredLanguages: preferredLanguages)
        let handler = VNImageRequestHandler(data: data)
        try handler.perform([request])
        return (request.results ?? []).compactMap {
            $0.topCandidates(1).first?.string
        }
    }

    static func makeRecognitionRequest(
        preferredLanguages: [String] = []
    ) -> VNRecognizeTextRequest {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        if
            !preferredLanguages.isEmpty,
            let supportedLanguages = try? request.supportedRecognitionLanguages()
        {
            let selected = supportedRecognitionPreferences(
                preferredLanguages,
                supportedLanguages: supportedLanguages
            )
            if !selected.isEmpty {
                request.recognitionLanguages = selected
            }
        }
        return request
    }

    static func supportedRecognitionPreferences(
        _ preferredLanguages: [String],
        supportedLanguages: [String]
    ) -> [String] {
        var selected: [String] = []
        for preferred in preferredLanguages {
            let normalized = preferred.lowercased()
            let components = normalized.split(separator: "-")
            let includesScript = components.dropFirst().contains { $0.count == 4 }
            let match = supportedLanguages.first { $0.lowercased() == normalized }
                ?? supportedLanguages.first {
                    let supported = $0.lowercased()
                    return normalized.hasPrefix("\(supported)-")
                        || supported.hasPrefix("\(normalized)-")
                }
                ?? (includesScript ? nil : supportedLanguages.first {
                    $0.lowercased().split(separator: "-").first == components.first
                })
            if let match, !selected.contains(match) {
                selected.append(match)
            }
        }
        return selected
    }

    static func runtimeSupportedRecognitionLanguages() -> [String] {
        let request = makeRecognitionRequest()
        return (try? request.supportedRecognitionLanguages()) ?? []
    }

    static func languageHypotheses(in text: String, maximum: Int = 3) -> [String] {
        guard maximum > 0 else { return [] }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        return recognizer.languageHypotheses(withMaximum: maximum)
            .sorted {
                if $0.value == $1.value {
                    return $0.key.rawValue < $1.key.rawValue
                }
                return $0.value > $1.value
            }
            .map(\.key.rawValue)
    }

    static func supportsNamedEntities(languageCode: String?) -> Bool {
        guard let languageCode else { return false }
        let language = NLLanguage(rawValue: languageCode)
        return NLTagger.availableTagSchemes(for: .word, language: language).contains(.nameType)
    }

    private func namedEntities(
        in text: String,
        languageCode: String?
    ) -> [AppleEntityFixture] {
        guard Self.supportsNamedEntities(languageCode: languageCode) else { return [] }
        let language = NLLanguage(rawValue: languageCode ?? "")
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        let range = text.startIndex..<text.endIndex
        tagger.setLanguage(language, range: range)
        var entities: [AppleEntityFixture] = []
        tagger.enumerateTags(
            in: range,
            unit: .word,
            scheme: .nameType,
            options: [.omitWhitespace, .omitPunctuation, .joinNames]
        ) { tag, tokenRange in
            let kind: ContentEntityKind?
            switch tag {
            case .personalName: kind = .person
            case .placeName: kind = .place
            case .organizationName: kind = .organization
            default: kind = nil
            }
            if let kind {
                entities.append(AppleEntityFixture(kind: kind, value: String(text[tokenRange])))
            }
            return true
        }
        return entities
    }

    private func detectedValues(in text: String) -> [AppleDetectedValue] {
        let checkingTypes: NSTextCheckingResult.CheckingType = [
            .link, .phoneNumber, .address, .date
        ]
        guard let detector = try? NSDataDetector(types: checkingTypes.rawValue) else {
            return []
        }
        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        return detector.matches(in: text, range: fullRange).compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            let sourceValue = String(text[range])
            switch match.resultType {
            case .link:
                return AppleDetectedValue(
                    kind: .url,
                    value: match.url?.absoluteString ?? sourceValue
                )
            case .phoneNumber:
                return AppleDetectedValue(
                    kind: .phone,
                    value: match.phoneNumber ?? sourceValue
                )
            case .address:
                return AppleDetectedValue(kind: .address, value: sourceValue)
            case .date:
                return AppleDetectedValue(kind: .date, value: sourceValue, date: match.date)
            default:
                return nil
            }
        }
    }

    private func trackingNumbers(in text: String) -> [AppleDetectedValue] {
        let patterns: [(pattern: String, captureGroup: Int)] = [
            (#"\b1Z[0-9A-Z]{16}\b"#, 0),
            (#"\b(?:92|93|94|95)[0-9]{18,20}\b"#, 0),
            (#"\b(?:fedex|tracking(?: number| no\.?)?)\s*[:#-]?\s*([0-9]{12,22})\b"#, 1)
        ]
        return patterns.flatMap { rule -> [AppleDetectedValue] in
            guard let expression = try? NSRegularExpression(
                pattern: rule.pattern,
                options: [.caseInsensitive]
            ) else { return [] }
            let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
            return expression.matches(in: text, range: fullRange).compactMap { match in
                guard let range = Range(match.range(at: rule.captureGroup), in: text) else {
                    return nil
                }
                let value = text[range].filter { $0.isLetter || $0.isNumber }
                return AppleDetectedValue(kind: .trackingNumber, value: String(value))
            }
        }
    }
}
