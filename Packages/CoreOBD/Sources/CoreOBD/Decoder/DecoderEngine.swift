import Foundation

/// Evaluates declarative signal formulas against reassembled UDS payloads.
/// In a formula, A is the byte at startByte, B at startByte+1, then C, D.
/// Expressions are compiled once per signal and cached.
public final class DecoderEngine {

    private let varNames = ["A", "B", "C", "D"]
    private let formulaCache = NSLock()
    private var cachedFormulas: [String: String] = [:]

    /// Returns decoded values keyed by signal id. Out-of-range values are discarded.
    public func decode(payload: Data, signals: [SignalDef]) -> [String: Double] {
        var out: [String: Double] = [:]
        for signal in signals {
            if let value = decodeSignal(payload: payload, signal: signal) {
                out[signal.id] = value
            }
        }
        return out
    }

    public func decodeSignal(payload: Data, signal: SignalDef) -> Double? {
        guard signal.startByte + signal.length <= payload.count else { return nil }

        // Substitute A, B, C, D with actual byte values
        var exprStr = signal.formula
        let maxVars = max(signal.length, usedVarsCount(signal.formula))
        for i in 0..<min(maxVars, varNames.count) {
            let raw = Int(payload[signal.startByte + i])
            let value: Int
            if signal.signed && i == 0 && raw >= 128 {
                value = raw - 256
            } else {
                value = raw
            }
            exprStr = exprStr.replacingOccurrences(of: varNames[i], with: "\(value).0")
        }

        // Evaluate using NSExpression
        guard let result = evaluateFormula(exprStr) else { return nil }
        guard result.isFinite else { return nil }

        if let min = signal.min, result < min { return nil }
        if let max = signal.max, result > max { return nil }

        return result
    }

    private func evaluateFormula(_ formula: String) -> Double? {
        // NSExpression can't handle leading unary minus before parenthesized expressions
        // like "-(123*256+45)/10". We need to transform those.
        var expr = formula
        // Handle leading negation: -(expr) -> (0-(expr))
        if expr.hasPrefix("-(") {
            expr = "0" + expr  // -> "0-(A*256+B)/10"
        }
        let nsExpr = NSExpression(format: expr)
        return nsExpr.expressionValue(with: nil, context: nil) as? Double
    }

    private func usedVarsCount(_ formula: String) -> Int {
        for i in stride(from: varNames.count - 1, through: 0, by: -1) {
            if formula.contains(varNames[i]) { return i + 1 }
        }
        return 0
    }
}
