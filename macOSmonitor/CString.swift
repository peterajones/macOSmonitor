extension String {
    /// The text in a fixed-size C buffer, up to its first NUL (the whole buffer if there is
    /// none). Replaces `String(cString:)` on arrays, which Swift 6 deprecates because it
    /// can't know the array is NUL-terminated.
    init(cBuffer buffer: [CChar]) {
        self.init(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
