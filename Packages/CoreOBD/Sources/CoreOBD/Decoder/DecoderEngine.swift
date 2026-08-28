import Foundation

/// Evaluates declarative signal formulas against reassembled UDS payloads.
/// In a formula, A is the byte at startByte, B at startByte+1, then C, D.
/// Sendable by way of the lock guarding the only mutable state (the formula
/// cache); the polling scheduler decodes off the main actor.
public final class DecoderEngine: @unchecked Sendable {

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
        // The substitution loop reads max(signal.length, vars referenced by the
        // formula) bytes: a formula may name a var beyond the declared window
        // only when the profile says so, so bound the whole read here. Profiles
        // referencing vars past `length` are rejected at parse time by
        // ProfileParser.validate; this guard also covers hand-built SignalDefs.
        let vars = max(signal.length, usedVarsCount(signal.formula))
        guard signal.startByte >= 0, vars >= 0,
              signal.startByte + max(signal.length, vars) <= payload.count else { return nil }

        // Substitute A, B, C, D with actual byte values
        var exprStr = signal.formula
        for i in 0..<min(vars, varNames.count) {
            let raw = Int(payload[signal.startByte + i])
            let value: Int
            if signal.signed && i == 0 && raw >= 128 {
                value = raw - 256
            } else {
                value = raw
            }
            exprStr = exprStr.replacingOccurrences(of: varNames[i], with: "\(value).0")
        }

        guard let result = Self.evaluateFormula(exprStr) else { return nil }
        guard result.isFinite else { return nil }

        if let min = signal.min, result < min { return nil }
        if let max = signal.max, result > max { return nil }

        return result
    }

    /// Evaluate an arithmetic formula (literals, + - * /, parentheses, unary
    /// minus) with a tiny recursive-descent parser.
    ///
    /// This used to go through `NSExpression(format:)`, which throws an
    /// Objective-C *exception* — not a Swift error — on a malformed format
    /// string, so a single profile typo would crash every decode of that
    /// signal (Swift cannot catch NSException). The formula grammar for OBD
    /// profiles is trivially small, so it is parsed here instead: malformed
    /// input returns nil and profiles are additionally validated at parse time
    /// (ProfileParser.validate).
    static func evaluateFormula(_ formula: String) -> Double? {
        guard !formula.isEmpty else { return nil }
        var parser = FormulaParser(tokens: FormulaTokenizer.tokenize(formula))
        guard let value = parser.parseExpression() else { return nil }
        guard parser.isAtEnd else { return nil }
        return value.isFinite ? value : nil
    }

    private func usedVarsCount(_ formula: String) -> Int {
        for i in stride(from: varNames.count - 1, through: 0, by: -1) {
            if formula.contains(varNames[i]) { return i + 1 }
        }
        return 0
    }

    /// Validation-time hook: runs the decode path against synthetic bytes.
    /// Internal so ProfileParser can call it without exposing a public decode API.
    static func staticSelfTest(payload: Data, signal: SignalDef) -> Double? {
        // Value ranges don't matter here (0x01 bytes are synthetic) — only that
        // the formula parses and references no byte outside the declared window.
        // min/max are plausibility filters on REAL data; applying them to the
        // synthetic value would reject perfectly valid formulas.
        let formulaOnly = SignalDef(
            id: signal.id,
            startByte: signal.startByte,
            length: signal.length,
            formula: signal.formula,
            unit: signal.unit,
            signed: signal.signed,
            min: nil,
            max: nil
        )
        let engine = DecoderEngine()
        return engine.decodeSignal(payload: payload, signal: formulaOnly)
    }
}

// MARK: - Formula parser

private enum FormulaToken: Equatable {
    case number(Double)
    case plus
    case minus
    case times
    case divide
    case leftParen
    case rightParen
}

private enum FormulaTokenizer {
    static func tokenize(_ input: String) -> [FormulaToken] {
        var tokens: [FormulaToken] = []
        var number = ""
        func flushNumber() {
            if let value = Double(number), !number.isEmpty {
                tokens.append(.number(value))
            }
            number = ""
        }
        for ch in input {
            switch ch {
            case "0"..."9", ".":
                number.append(ch)
            case "+":
                flushNumber(); tokens.append(.plus)
            case "-":
                flushNumber(); tokens.append(.minus)
            case "*":
                flushNumber(); tokens.append(.times)
            case "/":
                flushNumber(); tokens.append(.divide)
            case "(":
                flushNumber(); tokens.append(.leftParen)
            case ")":
                flushNumber(); tokens.append(.rightParen)
            case " ", "\t", "\n", "\r":
                flushNumber()
            default:
                // Any other character (letter, %, ^, comma, …) is outside the
                // OBD formula grammar — poison the token stream so parsing
                // fails instead of silently dropping it.
                flushNumber()
                tokens.append(.rightParen)  // unbalanced → parseExpression fails
                tokens.append(.rightParen)
            }
        }
        flushNumber()
        return tokens
    }
}

/// Recursive-descent evaluator for the grammar:
///   expression := term (('+' | '-') term)*
///   term       := unary (('*' | '/') unary)*
///   unary      := '-' unary | primary
///   primary    := number | '(' expression ')'
private struct FormulaParser {
    private let tokens: [FormulaToken]
    private var index = 0

    init(tokens: [FormulaToken]) {
        self.tokens = tokens
    }

    var isAtEnd: Bool { index >= tokens.count }

    mutating func parseExpression() -> Double? {
        guard var lhs = parseTerm() else { return nil }
        while index < tokens.count {
            switch tokens[index] {
            case .plus:
                index += 1
                guard let rhs = parseTerm() else { return nil }
                lhs += rhs
            case .minus:
                index += 1
                guard let rhs = parseTerm() else { return nil }
                lhs -= rhs
            default:
                return lhs
            }
        }
        return lhs
    }

    private mutating func parseTerm() -> Double? {
        guard var lhs = parseUnary() else { return nil }
        while index < tokens.count {
            switch tokens[index] {
            case .times:
                index += 1
                guard let rhs = parseUnary() else { return nil }
                lhs *= rhs
            case .divide:
                index += 1
                guard let rhs = parseUnary() else { return nil }
                guard rhs != 0 else { return nil }  // division by zero → no value
                lhs /= rhs
            default:
                return lhs
            }
        }
        return lhs
    }

    private mutating func parseUnary() -> Double? {
        if index < tokens.count, tokens[index] == .minus {
            index += 1
            guard let value = parseUnary() else { return nil }
            return -value
        }
        return parsePrimary()
    }

    private mutating func parsePrimary() -> Double? {
        guard index < tokens.count else { return nil }
        switch tokens[index] {
        case .number(let value):
            index += 1
            return value
        case .leftParen:
            index += 1
            guard let value = parseExpression() else { return nil }
            guard index < tokens.count, tokens[index] == .rightParen else { return nil }
            index += 1
            return value
        default:
            return nil
        }
    }
}
