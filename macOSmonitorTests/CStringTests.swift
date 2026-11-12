import Testing
@testable import macOSmonitor

struct CStringTests {
    private func buffer(_ bytes: [UInt8]) -> [CChar] { bytes.map { CChar(bitPattern: $0) } }

    /// Kernel buffers keep stale bytes after the terminator; they must not leak into the text.
    @Test func stopsAtTheFirstNUL() {
        #expect(String(cBuffer: buffer(Array("en0".utf8) + [0] + Array("stale".utf8))) == "en0")
    }

    @Test func usesTheWholeBufferWithoutANUL() {
        #expect(String(cBuffer: buffer(Array("utun3".utf8))) == "utun3")
    }

    /// CChar is signed: bytes ≥ 0x80 are negative and must be reinterpreted, not dropped.
    @Test func decodesUTF8BytesAbove127() {
        #expect(String(cBuffer: buffer(Array("Café".utf8) + [0, 0])) == "Café")
    }

    @Test func emptyAndAllZero() {
        #expect(String(cBuffer: []) == "")
        #expect(String(cBuffer: [0, 0, 0]) == "")
    }
}
