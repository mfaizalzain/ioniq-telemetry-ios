import Foundation

/// Every prompt the app sends, in one place.
///
/// The exact same text lives in `AiPrompts.kt` in the Android repo, and
/// `AiPromptTests` here / `AiPromptTest` there assert the built output against a
/// byte-identical golden fixture. That is deliberate: the wording used to be
/// duplicated across iOS's AiService and Android's two provider repositories, and
/// had already drifted — different personas per provider, a hardcoded vehicle in
/// one of them, and a charging prompt asking about seasonality without being given
/// any dates.
///
/// A prompt is a persona plus a body so each API can use its own convention:
/// DeepSeek takes the persona as a `system` message, Gemini gets persona and body
/// concatenated in one text part. The content the model sees is the same either way.
///
/// Bodies are assembled as arrays of lines joined with newlines, which maps exactly
/// onto Kotlin's `buildString { appendLine(...) }`. Swift multiline literals were
/// swallowing a blank separator the Kotlin side emitted, which is precisely the
/// drift the shared fixture is there to catch.
public struct AiPrompt: Equatable, Sendable {
    public let persona: String
    public let body: String

    /// Single-message form, for APIs without a system role.
    public var combined: String { "\(persona)\n\n\(body)" }
}

public enum AiPrompts {

    /// Appended to every analysis prompt. Models asked to interpret a handful of
    /// figures will otherwise fill the gaps confidently, and these outputs render in
    /// plain text views where markdown shows up as literal asterisks.
    public static let groundingRules = [
        "Use only the figures above; do not invent data. If the data is too limited for a conclusion, say so plainly.",
        "Reply in plain sentences: no markdown, no bullet characters, no headings.",
    ]

    /// Cost questions are the most likely place for a model to invent a number and
    /// present it as a reading, so the assumption has to travel with the answer.
    public static let tariffRule =
        "State the electricity tariff and fuel price you assume, so the figure can be checked."

    // MARK: - Post-trip briefing

    public static func postTripBriefing(
        tripJson: String,
        recentTripsSummary: String,
        efficiencyBaseline: Double?,
        vehicleName: String,
        usableBatteryKwh: Double,
        countryCode: String?
    ) -> AiPrompt {
        let baseline = efficiencyBaseline.map { String(format: "%.1f", $0) } ?? "unknown"
        let country = countryCode.map { " for \($0)" } ?? ""

        var lines = [
            "This trip data (JSON):",
            tripJson,
            "",
        ]
        if !recentTripsSummary.isEmpty {
            lines += ["Recent trips for comparison:", recentTripsSummary, ""]
        }
        lines += [
            "Write a 3-4 sentence post-trip briefing covering:",
            "1. Efficiency (kWh/100km) vs the driver's average (\(baseline) kWh/100km)",
            "2. Regen score estimate (how much energy was recovered)",
            "3. Cost estimate: kWh used x typical local electricity tariff vs equivalent petrol cost\(country), in local currency. \(tariffRule)",
            "4. One personalized efficiency tip based on this trip",
            "",
            "Be concise, friendly, and specific to THIS trip's data.",
        ]
        lines += groundingRules

        return AiPrompt(
            persona: "You are an EV efficiency coach for a \(vehicleName) (\(String(format: "%.0f", usableBatteryKwh)) kWh battery).",
            body: lines.joined(separator: "\n")
        )
    }

    // MARK: - Digest

    public static func digest(
        stats: String,
        chargeSessionsSummary: String,
        period: DigestPeriod,
        vehicleName: String,
        countryCode: String?
    ) -> AiPrompt {
        let periodLabel = period == .weekly ? "week" : "month"
        let country = countryCode.map { " for \($0)" } ?? ""

        var lines = [
            "Summarise the driver's last \(periodLabel) with these trip stats:",
            stats,
            "",
        ]
        // Android computed this summary and then dropped it: generateDigest took it as
        // a parameter and never used it. Charging behaviour is half of how a driver's
        // month actually went.
        if !chargeSessionsSummary.isEmpty {
            lines += ["Charge sessions this \(periodLabel):", chargeSessionsSummary, ""]
        }
        lines += [
            "Write 2-3 natural sentences covering:",
            "1. Total distance driven and estimated cost saved vs petrol\(country), in local currency. \(tariffRule)",
            "2. Their most efficient day this \(periodLabel)",
            "3. One notable pattern or tip",
            "",
            "Be encouraging and specific to their data.",
        ]
        lines += groundingRules

        return AiPrompt(
            persona: "You are an EV driving analyst for a \(vehicleName) driver.",
            body: lines.joined(separator: "\n")
        )
    }

    // MARK: - Charging insight

    public static func chargingInsight(sessionSummary: String) -> AiPrompt {
        var lines = [
            "Review these charge sessions for an E-GMP electric vehicle:",
            sessionSummary,
            "",
            "Analyse trends in 1-2 sentences:",
            "- Is 10-80% time changing?",
            "- Are there seasonal patterns?",
            "- Any notable behaviour worth mentioning?",
            "",
        ]
        lines += groundingRules
        return AiPrompt(
            persona: "You are an EV charging analyst.",
            body: lines.joined(separator: "\n")
        )
    }

    // MARK: - Battery health report

    public static func batteryReport(
        sohHistory: String,
        voltageDeltas: String,
        chargeSpeeds: String
    ) -> AiPrompt {
        var lines = ["Generate a battery health report for an E-GMP electric vehicle."]
        if !sohHistory.isEmpty {
            lines += ["", "SOH (State of Health) over time:", sohHistory]
        }
        if !voltageDeltas.isEmpty {
            lines += ["", "Cell voltage deltas (mV):", voltageDeltas]
        }
        if !chargeSpeeds.isEmpty {
            lines += ["", "10-80% charge times over time:", chargeSpeeds]
        }
        lines += [
            "",
            "Rate the overall battery health and highlight any degradation concerns or recommendations.",
            "Keep the response clear and actionable. Where only a single reading is given, say that no trend can be established yet rather than describing one.",
        ]
        lines += groundingRules
        return AiPrompt(
            persona: "You are an EV battery health analyst.",
            body: lines.joined(separator: "\n")
        )
    }

    // MARK: - Assistant

    public static func assistant(query: String, telemetryContext: String) -> AiPrompt {
        AiPrompt(
            // Deliberately vehicle-agnostic: Android hardcoded "Hyundai Ioniq 5",
            // which is the wrong car for an EV6, GV60 or Ioniq 6 owner.
            persona: "You are an EV assistant answering questions about THIS specific vehicle.",
            body: [
                "VEHICLE CONTEXT:",
                telemetryContext,
                "",
                "USER QUERY:",
                query,
                "",
                "Answer from the context above. If the context does not contain the answer, say so rather than guessing.",
                "Reply in plain sentences: no markdown, no bullet characters, no headings.",
            ].joined(separator: "\n")
        )
    }
}
