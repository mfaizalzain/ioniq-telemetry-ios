import Foundation

/// Reassembles ISO-TP multi-frame responses from cleaned adapter lines.
/// Input lines have headers ON and spaces OFF, e.g.:
///   7EC103D6201...   first frame       PCI high nibble = 1
///   7EC21FFFFFF...   consecutive       PCI high nibble = 2, low nibble = sequence
public enum IsoTpReassembler {

    /// UDS response CAN id = request id + 8 (7E4 -> 7EC).
    public static func responseHeaderFor(requestHeader: String) -> String {
        guard let id = Int(requestHeader, radix: 16) else { return requestHeader }
        return String(format: "%03X", id + 8)
    }

    public static func reassemble(lines: [String], responseHeader: String) -> Data? {
        let frames = lines
            .map { $0.replacingOccurrences(of: " ", with: "").uppercased() }
            .filter { $0.hasPrefix(responseHeader) && $0.count > responseHeader.count }
            .map { String($0.dropFirst(responseHeader.count)) }

        guard let firstHex = frames.first else { return nil }
        guard let firstBytes = hexToBytes(firstHex), !firstBytes.isEmpty else { return nil }

        let pciType = (Int(firstBytes[0]) & 0xF0) >> 4
        switch pciType {
        case 0: // single frame
            let len = Int(firstBytes[0]) & 0x0F
            // A zero-length frame carries no payload — reject it as corrupt rather
            // than handing callers empty "success" data.
            guard len > 0, firstBytes.count >= 1 + len else { return nil }
            return Data(firstBytes[1..<1 + len])
        case 1: // multi-frame
            return reassembleMultiFrame(frames: frames)
        default:
            return nil
        }
    }

    private static func reassembleMultiFrame(frames: [String]) -> Data? {
        guard let firstHex = frames.first,
              let firstBytes = hexToBytes(firstHex),
              firstBytes.count >= 2 else { return nil }

        let totalLength = ((Int(firstBytes[0]) & 0x0F) << 8) | Int(firstBytes[1])
        var out = [UInt8]()
        out.append(contentsOf: firstBytes.dropFirst(2))

        var expectedSeq = 1
        for frame in frames.dropFirst() {
            guard let bytes = hexToBytes(frame), !bytes.isEmpty else { return nil }
            let pci = Int(bytes[0])
            guard (pci & 0xF0) == 0x20 else { return nil }
            let seq = pci & 0x0F
            guard seq == expectedSeq else { return nil }
            expectedSeq = (expectedSeq + 1) & 0x0F
            out.append(contentsOf: bytes.dropFirst())
            if out.count >= totalLength { break }
        }

        guard out.count >= totalLength else { return nil }
        return Data(out.prefix(totalLength))
    }

    private static func hexToBytes(_ hex: String) -> [UInt8]? {
        // An odd-length hex line means a dropped or misaligned nibble. The
        // reassembler exists to refuse corrupt data, so reject it outright — a
        // silently-truncated trailing nibble can decode to a plausible-but-wrong
        // reading (e.g. "7EC213" -> [0x21]) that would reach the dashboard.
        guard hex.count % 2 == 0, !hex.isEmpty else { return nil }
        var bytes = [UInt8]()
        var index = hex.startIndex
        while index < hex.endIndex {
            let nextIndex = hex.index(index, offsetBy: 2)
            let byteStr = String(hex[index..<nextIndex])
            guard let byte = UInt8(byteStr, radix: 16) else { return nil }
            bytes.append(byte)
            index = nextIndex
        }
        return bytes
    }
}
