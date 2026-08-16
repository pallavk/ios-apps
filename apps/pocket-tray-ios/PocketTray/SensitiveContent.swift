import Foundation

enum SensitiveContentReason: String, Codable, CaseIterable, Equatable, Sendable {
    case oneTimeCode
    case paymentCard
    case privateKey

    var warningLabel: String {
        switch self {
        case .oneTimeCode: "one-time code"
        case .paymentCard: "payment card number"
        case .privateKey: "private key"
        }
    }

    static func ordered(_ reasons: Set<Self>) -> [Self] {
        reasons.sorted { $0.rawValue < $1.rawValue }
    }
}

struct SensitivityAssessment: Codable, Equatable, Sendable {
    let reasons: Set<SensitiveContentReason>
    private(set) var isOverridden: Bool

    init(
        reasons: Set<SensitiveContentReason>,
        isOverridden: Bool = false
    ) {
        self.reasons = reasons
        self.isOverridden = isOverridden
    }

    func settingOverridden(_ isOverridden: Bool) -> SensitivityAssessment {
        SensitivityAssessment(reasons: reasons, isOverridden: isOverridden)
    }
}

struct SensitivePreviewSession: Equatable, Sendable {
    private var revealedItemIDs: Set<UUID> = []

    func allowsContentAccess(to item: TrayItem) -> Bool {
        !item.protectsSensitivePreview || revealedItemIDs.contains(item.id)
    }

    mutating func reveal(_ itemID: UUID) {
        revealedItemIDs.insert(itemID)
    }

    mutating func hide(_ itemID: UUID) {
        revealedItemIDs.remove(itemID)
    }

    mutating func endForegroundSession() {
        revealedItemIDs.removeAll()
    }
}

protocol SensitiveContentClassifying: Sendable {
    func reasons(in text: String) -> Set<SensitiveContentReason>
}

struct DeterministicSensitiveContentClassifier: SensitiveContentClassifying {
    func reasons(in text: String) -> Set<SensitiveContentReason> {
        var reasons: Set<SensitiveContentReason> = []
        if containsContextualOneTimeCode(text) { reasons.insert(.oneTimeCode) }
        if containsLuhnValidCard(text) { reasons.insert(.paymentCard) }
        if containsPrivateKeyMarker(text) { reasons.insert(.privateKey) }
        return reasons
    }

    private func containsContextualOneTimeCode(_ text: String) -> Bool {
        let context = #"(?:otp|one[ -]time(?: password| code)?|verification code|security code|passcode|2fa|two[ -]factor(?: authentication)? code)"#
        let patterns = [
            #"\b"# + context + #"\b[^0-9]{0,32}([0-9]{4,8})\b"#,
            #"\b([0-9]{4,8})\b[^\n]{0,32}\b(?:is your |your )"# + context + #"\b"#
        ]
        return patterns.contains { matches($0, in: text, options: [.caseInsensitive]) }
    }

    private func containsLuhnValidCard(_ text: String) -> Bool {
        let pattern = #"(?<![0-9])(?:[0-9][ -]?){12,18}[0-9](?![0-9])"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return expression.matches(in: text, range: range).contains { match in
            guard let candidateRange = Range(match.range, in: text) else { return false }
            let digits = text[candidateRange].compactMap(\.wholeNumberValue)
            guard
                (13...19).contains(digits.count),
                Set(digits).count > 1
            else { return false }
            return isLuhnValid(digits)
        }
    }

    private func isLuhnValid(_ digits: [Int]) -> Bool {
        let sum = digits.reversed().enumerated().reduce(into: 0) { total, element in
            let (offset, digit) = element
            if offset.isMultiple(of: 2) {
                total += digit
            } else {
                let doubled = digit * 2
                total += doubled > 9 ? doubled - 9 : doubled
            }
        }
        return sum.isMultiple(of: 10)
    }

    private func containsPrivateKeyMarker(_ text: String) -> Bool {
        let uppercase = text.uppercased()
        return [
            "-----BEGIN PRIVATE KEY-----",
            "-----BEGIN RSA PRIVATE KEY-----",
            "-----BEGIN EC PRIVATE KEY-----",
            "-----BEGIN DSA PRIVATE KEY-----",
            "-----BEGIN OPENSSH PRIVATE KEY-----",
            "-----BEGIN PGP PRIVATE KEY BLOCK-----"
        ].contains(where: uppercase.contains)
    }

    private func matches(
        _ pattern: String,
        in text: String,
        options: NSRegularExpression.Options = []
    ) -> Bool {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: options) else {
            return false
        }
        return expression.firstMatch(
            in: text,
            range: NSRange(text.startIndex..<text.endIndex, in: text)
        ) != nil
    }
}
