import Foundation

/// Reassembles ISO-TP multi-frame responses. Input is the cleaned response lines
/// from the adapter with headers ON and spaces OFF, e.g.:
///
///   7EC103D6201...   first frame       PCI high nibble = 1
///   7EC21FFFFFF...   consecutive       PCI high nibble = 2, low nibble = sequence
///
/// A gap in the sequence counter means a dropped frame — the whole response is
/// discarded (return nil) rather than decoding corrupt data.
public enum IsoTpReassembler {

    /// UDS response CAN id = request id + 8 (7E4 -> 7EC).
    public static func responseHeaderFor(requestHeader: String) -> String {
        guard let id = UInt(requestHeader, radix: 16) else { return requestHeader }
        let responseId = id + 8
        return String(responseId, radix: 16).uppercased().padLeft(toLength: 3, withPad: "0")
    }

    public static func reassemble(lines: [String], responseHeader: String) -> [UInt8]? {
        let frames: [String] = lines
            .map { $0.replacingOccurrences(of: " ", with: "").uppercased() }
            .filter { $0.hasPrefix(responseHeader) && $0.count > responseHeader.count }
            .map { String($0.dropFirst(responseHeader.count)) }

        guard !frames.isEmpty,
              let firstBytes = frames[0].hexToBytes(),
              !firstBytes.isEmpty
        else { return nil }

        let pciType = (Int(firstBytes[0]) & 0xF0) >> 4
        switch pciType {
        case 0:
            // Single frame: low nibble is length, payload starts at byte 1
            let len = Int(firstBytes[0]) & 0x0F
            guard firstBytes.count >= 1 + len else { return nil }
            return Array(firstBytes[1..<1 + len])

        case 1:
            return reassembleMultiFrame(frames: frames)

        default:
            return nil
        }
    }

    // MARK: - Multi-frame

    private static func reassembleMultiFrame(frames: [String]) -> [UInt8]? {
        guard let first = frames[0].hexToBytes(), first.count >= 2 else { return nil }

        // First frame: PCI high nibble 1, remaining 12 bits give total length; payload at offset 2.
        let totalLength = ((Int(first[0]) & 0x0F) << 8) | (Int(first[1]) & 0xFF)
        var out = [UInt8]()
        out.reserveCapacity(totalLength)
        out.append(contentsOf: first.dropFirst(2))

        var expectedSeq = 1
        for frame in frames.dropFirst() {
            guard let bytes = frame.hexToBytes(), !bytes.isEmpty else { return nil }

            let pci = Int(bytes[0]) & 0xFF
            guard (pci & 0xF0) == 0x20 else { return nil }  // not a consecutive frame

            let seq = pci & 0x0F
            guard seq == expectedSeq else { return nil }     // dropped or out-of-order frame
            expectedSeq = (expectedSeq + 1) & 0x0F           // sequence wraps 0..F

            out.append(contentsOf: bytes.dropFirst())
            if out.count >= totalLength { break }
        }

        guard out.count >= totalLength else { return nil }   // truncated response
        return Array(out.prefix(totalLength))                // truncate to declared length
    }
}

// MARK: - Hex parsing

private extension String {
    /// Converts a hex string to byte array. Returns nil if any character is invalid hex.
    func hexToBytes() -> [UInt8]? {
        let s = count % 2 == 0 ? self : String(dropLast())
        guard !s.isEmpty else { return nil }

        var bytes = [UInt8]()
        bytes.reserveCapacity(s.count / 2)

        var index = s.startIndex
        while index < s.endIndex {
            let nextIndex = s.index(index, offsetBy: 2)
            let hexPair = s[index..<nextIndex]
            guard let byte = UInt8(hexPair, radix: 16) else { return nil }
            bytes.append(byte)
            index = nextIndex
        }
        return bytes
    }
}

// MARK: - String padding helper

private extension String {
    func padLeft(toLength length: Int, withPad pad: String) -> String {
        let padCount = length - count
        guard padCount > 0 else { return self }
        return String(repeating: pad, count: padCount) + self
    }
}
