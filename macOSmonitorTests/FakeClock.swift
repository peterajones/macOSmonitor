/// Mutable stand-in for a sampler's injected `now` clock. A class, so a
/// `@Sendable` closure can capture it by reference and still see later
/// `clock.now = …` assignments without capturing a `var`.
final class FakeClock: @unchecked Sendable {
    var now: UInt64 = 0
}
