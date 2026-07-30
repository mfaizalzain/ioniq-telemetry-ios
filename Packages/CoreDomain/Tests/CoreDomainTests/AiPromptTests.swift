import Foundation
import Testing
@testable import CoreDomain

/// Renders every prompt from fixed inputs and compares the result to
/// `ai-prompts-golden.txt`, which is byte-identical to
/// `core-data/src/test/resources/ai-prompts-golden.txt` in the Android repo, where
/// `AiPromptTest` asserts the same thing.
///
/// That is the whole point: this wording was previously duplicated in three files
/// across two repos and had drifted — different personas per provider, a hardcoded
/// vehicle, and a charging prompt asking about seasonality with no dates supplied.
/// Now an intentional change means regenerating the fixture and copying it to the
/// other repo, and an unintentional one fails a test.
///
/// To regenerate after deliberately editing a prompt:
///   GENERATE_PROMPT_FIXTURE=1 swift test --filter AiPromptTests
/// then copy the file to the Android repo.
@Suite("AI prompts")
struct AiPromptTests {

    // MARK: - Fixed inputs (mirrored exactly in Android's AiPromptTest)

    private static let tripJson = #"{"distanceKm":128.5,"energyUsedKwh":21.1}"#
    private static let recentTrips = "- 2026-07-28: 90.0 km, 15.0 kWh\n- 2026-07-29: 45.0 km, 8.0 kWh"
    private static let digestStats = """
    Trips: 4
    Total distance: 512.0 km
    Total energy: 87.0 kWh
    Average efficiency: 17.0 kWh/100km
    """
    private static let chargeSessions = """
    Sessions: 2
    - 2026-07-28: 25% → 80%, energy: 42.5 kWh, peak: 178.0 kW, avg: 95.5 kW, type: DC, 10-80% time: 18 min, pack temp: 24°C
    """
    private static let sohHistory = "- 2026-07-01: 99.1%"
    private static let voltageDeltas = "min=12.0, max=28.0, avg=18.5"
    private static let chargeSpeeds = "- 2026-07-28: 18 min"

    /// Every prompt, in a stable order.
    private static var all: [(String, AiPrompt)] {
        [
            ("postTripBriefing", AiPrompts.postTripBriefing(
                tripJson: tripJson,
                recentTripsSummary: recentTrips,
                efficiencyBaseline: 16.4,
                vehicleName: "Ioniq 5",
                usableBatteryKwh: 74,
                countryCode: "MY"
            )),
            ("postTripBriefing.noRecentTrips.noCountry", AiPrompts.postTripBriefing(
                tripJson: tripJson,
                recentTripsSummary: "",
                efficiencyBaseline: nil,
                vehicleName: "EV6",
                usableBatteryKwh: 77.4,
                countryCode: nil
            )),
            ("digest.weekly", AiPrompts.digest(
                stats: digestStats,
                chargeSessionsSummary: chargeSessions,
                period: .weekly,
                vehicleName: "Ioniq 5",
                countryCode: "MY"
            )),
            ("digest.monthly.noCharging", AiPrompts.digest(
                stats: digestStats,
                chargeSessionsSummary: "",
                period: .monthly,
                vehicleName: "Ioniq 5",
                countryCode: nil
            )),
            ("chargingInsight", AiPrompts.chargingInsight(sessionSummary: chargeSessions)),
            ("batteryReport", AiPrompts.batteryReport(
                sohHistory: sohHistory,
                voltageDeltas: voltageDeltas,
                chargeSpeeds: chargeSpeeds
            )),
            ("batteryReport.sohOnly", AiPrompts.batteryReport(
                sohHistory: sohHistory, voltageDeltas: "", chargeSpeeds: ""
            )),
            ("assistant", AiPrompts.assistant(
                query: "Why is my range dropping?",
                telemetryContext: "SOC 72%, pack 27C, 18.5 kW draw"
            )),
        ]
    }

    private static var rendered: String {
        all.reduce(into: "") { out, entry in
            out += "===== \(entry.0) :: PERSONA =====\n\(entry.1.persona)\n"
            out += "===== \(entry.0) :: BODY =====\n\(entry.1.body)\n"
        }
    }

    // MARK: - Test

    @Test("every prompt matches the fixture shared with Android")
    func matchesGoldenFixture() throws {
        let rendered = Self.rendered

        if ProcessInfo.processInfo.environment["GENERATE_PROMPT_FIXTURE"] != nil {
            let path = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .appendingPathComponent("Fixtures/ai-prompts-golden.txt")
            try rendered.write(to: path, atomically: true, encoding: .utf8)
            print("wrote fixture to \(path.path)")
            return
        }

        let url = try #require(
            Bundle.module.url(forResource: "Fixtures/ai-prompts-golden", withExtension: "txt"),
            "fixture missing — regenerate with GENERATE_PROMPT_FIXTURE=1"
        )
        let expected = try String(contentsOf: url, encoding: .utf8)
        #expect(rendered == expected, "prompts changed; regenerate the fixture and mirror it to Android")
    }

    /// Cost questions are where a model is most likely to state an invented tariff as
    /// fact, so the instruction to show its assumptions must not quietly disappear.
    @Test("prompts that ask about money require the assumption to be stated")
    func costPromptsRequireAssumptions() {
        let briefing = AiPrompts.postTripBriefing(
            tripJson: "{}", recentTripsSummary: "", efficiencyBaseline: nil,
            vehicleName: "Ioniq 5", usableBatteryKwh: 74, countryCode: "MY"
        )
        let digest = AiPrompts.digest(
            stats: "", chargeSessionsSummary: "", period: .weekly,
            vehicleName: "Ioniq 5", countryCode: "MY"
        )
        #expect(briefing.body.contains(AiPrompts.tariffRule))
        #expect(digest.body.contains(AiPrompts.tariffRule))
    }

    @Test("every prompt carries the grounding rules")
    func allPromptsGrounded() {
        for (name, prompt) in Self.all where name != "assistant" {
            #expect(
                prompt.body.contains("do not invent data"),
                "\(name) is missing the grounding rules"
            )
        }
    }

    /// The assistant persona must stay vehicle-agnostic: it used to name the Ioniq 5
    /// on Android, which is the wrong car for an EV6, GV60 or Ioniq 6 owner.
    @Test("the assistant persona names no specific model")
    func assistantIsVehicleAgnostic() {
        let prompt = AiPrompts.assistant(query: "q", telemetryContext: "c")
        for model in ["Ioniq 5", "Ioniq 6", "EV6", "GV60", "Hyundai"] {
            #expect(!prompt.persona.contains(model), "persona hardcodes \(model)")
        }
    }
}
