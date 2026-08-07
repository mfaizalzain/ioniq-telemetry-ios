import Foundation
import Testing
@testable import CoreOBD

struct IsoTpReassemblerRegressionTests {

    @Test("response header is request plus 8")
    func responseHeader() {
        #expect(IsoTpReassembler.responseHeaderFor(requestHeader: "7E4") == "7EC")
        #expect(IsoTpReassembler.responseHeaderFor(requestHeader: "7B3") == "7BB")
    }

    @Test("single frame reassembles")
    func singleFrame() {
        let data = IsoTpReassembler.reassemble(lines: ["7EC03620101"], responseHeader: "7EC")
        #expect(data == Data([0x62, 0x01, 0x01]))
    }

    @Test("odd-length hex is rejected, not nibble-dropped")
    func oddLengthRejected() {
        // "7EC213" has an odd-length body: the old code dropped the trailing '3'
        // and decoded [0x21] as a plausible-but-wrong payload.
        #expect(IsoTpReassembler.reassemble(lines: ["7EC213"], responseHeader: "7EC") == nil)
    }

    @Test("zero-length single frame is rejected")
    func zeroLengthRejected() {
        // PCI 0x00 declares a zero-length payload — empty is corrupt, not success.
        #expect(IsoTpReassembler.reassemble(lines: ["7EC00"], responseHeader: "7EC") == nil)
    }

    @Test("dropped sequence frame is rejected")
    func droppedFrameRejected() {
        #expect(IsoTpReassembler.reassemble(
            lines: ["7EC1014620101AABBCC", "7EC22DDEEFF11223344"],
            responseHeader: "7EC"
        ) == nil)
    }
}

struct IsoTpFramingRegressionTests {

    @Test("frames a short request")
    func framesShort() throws {
        #expect(try isoTpSingleFrame(requestHex: "220101") == "03220101")
    }

    @Test("rejects a payload over 7 bytes instead of mis-framing it")
    func tooLongRejected() {
        // A length nibble of 8+ would be read by the ELM327 as a multi-frame first
        // frame — silently corrupt. It must fail loudly.
        #expect(throws: FramingError.self) {
            _ = try isoTpSingleFrame(requestHex: "2201010101010101FF")
        }
    }

    @Test("rejects odd-length hex")
    func oddLengthRejected() {
        #expect(throws: FramingError.self) {
            _ = try isoTpSingleFrame(requestHex: "22010")
        }
    }
}
