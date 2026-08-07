import Foundation

/// Wraps a UDS request payload in an ISO-TP single frame: a leading byte whose low
/// nibble is the payload length (high nibble 0 = single frame).
/// e.g. "220101" (3 bytes) -> "03220101".
///
/// - Throws: `FramingError.tooLong` for a payload over 7 bytes. A length nibble of
///   8+ would be interpreted by the ELM327 as a multi-frame first frame, silently
///   mis-framing the request.
public func isoTpSingleFrame(requestHex: String) throws -> String {
    // Odd-length hex is malformed — refuse it rather than truncating a nibble.
    guard requestHex.count % 2 == 0 else { throw FramingError.malformed }
    let byteCount = requestHex.count / 2
    guard byteCount <= 7 else { throw FramingError.tooLong(byteCount) }
    return String(format: "%02X%@", byteCount, requestHex)
}

public enum FramingError: Error, Equatable {
    case malformed
    case tooLong(Int)
}
