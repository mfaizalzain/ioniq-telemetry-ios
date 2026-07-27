import Foundation

/// Wraps a UDS request payload in an ISO-TP single frame: a leading byte whose low
/// nibble is the payload length (high nibble 0 = single frame).
/// e.g. "220101" (3 bytes) -> "03220101".
public func isoTpSingleFrame(requestHex: String) -> String {
    let byteCount = requestHex.count / 2
    return String(format: "%02X%@", byteCount, requestHex)
}
