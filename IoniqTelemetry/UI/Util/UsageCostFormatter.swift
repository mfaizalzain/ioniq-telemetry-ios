import Foundation

/// Cleans and prices raw Open Charge Map `UsageCost` strings for display.
///
/// Mirrors the Android app's `ui/util/UsageCostFormatter.kt` so both platforms
/// render crowdsourced OCM cost text the same way. One deliberate extension:
/// `RM` (Malaysian ringgit) is recognised as a currency, because local OCM
/// entries are priced "RM …" and would otherwise lose their currency marker.
enum UsageCostFormatter {

    /// The currency symbol implied by a raw OCM cost string, for pricing a
    /// plan's charge stops ("£0.45/kWh" → "£"). Empty when the entry carries
    /// no currency marker.
    static func currencySymbol(of raw: String?) -> String {
        guard let raw else { return "" }
        // Same alternatives as Android, plus \bRM\b (word-bounded so "FORM"
        // never matches). Case-insensitive; the first match wins.
        guard let regex = try? NSRegularExpression(
            pattern: "[£€$¥]|(?:USD|EUR|GBP|AUD|CAD|CHF)|\\bRM\\b",
            options: [.caseInsensitive]
        ), let match = regex.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)),
          let range = Range(match.range, in: raw) else { return "" }
        let marker = String(raw[range])
        switch marker.uppercased() {
        case "USD", "AUD", "CAD": return "$"
        case "EUR": return "€"
        case "GBP": return "£"
        case "RM": return "RM" // normalised to uppercase even for "rm …"
        default: return marker // "CHF", "¥", … — keep the matched text as-is
        }
    }

    /// Cleans a raw OCM `UsageCost` string for badge display.
    ///
    /// OCM data is crowdsourced and often contains messy freeform text like
    /// `"0.00 jaarabonnement"`, `"Free. Parking fees apply."`, or
    /// `"Check xxx app for pricing"`.
    ///
    /// - Returns: A short, human-readable cost badge string, or `nil` if the
    ///   entry is not useful (empty, zero-cost noise, descriptive instructions).
    static func formatUsageCost(_ raw: String?) -> String? {
        guard let s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }

        // "Free. <extra text>" → just "Free" (Dutch/German too)
        let lower = s.lowercased()
        if lower.hasPrefix("free") || lower.hasPrefix("gratis") || lower.hasPrefix("kostenlos") {
            return "Free"
        }

        // Descriptive instructions with no actual pricing → skip.
        let hasInstruction = containsMatch(
            "\\b(?:check|see|contact|call|visit|app|member)\\b", in: s, caseInsensitive: true
        )

        // Does the string carry an actual pricing signal? (Same three probes as Android.)
        let hasPriceSignal = containsMatch("[£$€¥]", in: s)
            || containsMatch("[\\d.]+\\s*(?:€|\\$|£|¥|GBP|EUR|USD|kWh)", in: s, caseInsensitive: true)
            || containsMatch("(?:€|\\$|£|¥)\\s*[\\d.]+", in: s, caseInsensitive: true)

        if hasInstruction && !hasPriceSignal { return nil }

        // Starts with "0", "0.00" etc. and no actual price signal → noise like
        // "0.00 jaarabonnement". (The Android regex ^0(?:\.\d+)?\s*.*$ is
        // equivalent to a "starts with 0" check.)
        if containsMatch("^0(?:\\.\\d+)?\\s*.*$", in: s) && !hasPriceSignal { return nil }

        // Very long verbose strings → trim
        if s.count > 25 {
            return String(s.prefix(22)).trimmingCharacters(in: .whitespaces) + "…"
        }

        return s
    }

    /// Case-(in)sensitive regex containment check; a pattern that fails to
    /// compile simply reports "no match".
    private static func containsMatch(_ pattern: String, in s: String, caseInsensitive: Bool = false) -> Bool {
        guard let regex = try? NSRegularExpression(
            pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : []
        ) else { return false }
        return regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }
}
