import Foundation

/// A numeric edit commits once, and cannot follow a control into another
/// preset, scene, channel, model, or page.
struct AM4ParameterNumberDraft {
    enum Outcome: Equatable { case apply(Double), unchanged, invalid, cancelled }
    let identity: String
    let initialPosition: Double
    var text: String
    private(set) var active = true

    init(definition: AM4ParameterDefinition, position: Double, identity: String, locale: Locale = .current) {
        self.identity = identity
        initialPosition = position
        text = String(format: "%.6f", definition.displayValue(position))
            .replacingOccurrences(of: "0+$", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\.$", with: "", options: .regularExpression)
            .replacingOccurrences(of: ".", with: locale.decimalSeparator ?? ".")
    }

    mutating func cancel() { active = false }

    mutating func commit(definition: AM4ParameterDefinition, identity: String, locale: Locale = .current) -> Outcome {
        guard active else { return .cancelled }
        guard self.identity == identity else { active = false; return .cancelled }
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: locale.decimalSeparator ?? ".", with: ".")
        guard let value = Double(input), let position = definition.normalizedValue(forDisplay: value) else { return .invalid }
        active = false
        return abs(position - initialPosition) <= definition.tolerance(at: initialPosition) ? .unchanged : .apply(position)
    }
}
