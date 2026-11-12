import Testing
import Darwin
import Foundation
@testable import macOSmonitor

struct ProcessQueryTests {
    private let rows = [
        ProcessInfoRow(pid: 771, name: "Google Chrome Helper", cpuPercent: nil, memoryBytes: nil,
                       uid: 501, user: "pjones", path: "/Applications/Google Chrome.app/Contents/MacOS/Helper"),
        ProcessInfoRow(pid: 7712, name: "mds", cpuPercent: nil, memoryBytes: nil,
                       uid: 0, user: "root", path: "/System/Library/Frameworks/mds"),
        ProcessInfoRow(pid: 1771, name: "Safari", cpuPercent: nil, memoryBytes: nil,
                       uid: 501, user: "pjones", path: "/Applications/Safari.app/Contents/MacOS/Safari"),
        ProcessInfoRow(pid: 90, name: "vanished", cpuPercent: nil, memoryBytes: nil),
    ]

    private func pids(_ text: String) -> [pid_t] {
        let query = ProcessQuery(text)
        return rows.filter(query.matches).map(\.pid)
    }

    @Test func plainWordsStillMatchNameOrPIDSubstring() {
        #expect(pids("chrome") == [771])
        #expect(pids("771") == [771, 7712, 1771])
        #expect(pids("   ").count == rows.count)
    }

    /// The reason for pid:. Three rows contain "771"; only one is PID 771.
    @Test func pidFieldIsExact() {
        #expect(pids("pid:771") == [771])
        #expect(pids("PID:771") == [771])
        #expect(pids("pid:abc").isEmpty)
    }

    @Test func userMatchesNameSubstringOrExactUID() {
        #expect(pids("user:root") == [7712])
        #expect(pids("user:PJ") == [771, 1771])
        #expect(pids("user:0") == [7712])
        #expect(pids("user:50").isEmpty)            // uid is exact, not substring
    }

    @Test func pathAndNameFields() {
        #expect(pids("path:/Applications") == [771, 1771])
        #expect(pids("path:\"Google Chrome.app\"") == [771])
        #expect(pids("name:771").isEmpty)           // name: doesn't fall back to the PID
    }

    @Test func everyWordMustMatch() {
        #expect(pids("user:pjones path:Safari") == [1771])
        #expect(pids("helper chrome") == [771])       // order-free, unlike one substring
        #expect(pids("helper safari").isEmpty)
    }

    /// Typing "pid:" must not empty the table before the number arrives; an unknown prefix
    /// is ordinary text (a name could contain a colon).
    @Test func emptyFieldsAreIgnoredAndUnknownPrefixesAreText() {
        #expect(ProcessQuery("pid:").terms.isEmpty)
        #expect(pids("pid: chrome") == [771])
        #expect(ProcessQuery("foo:bar").terms == [.plain("foo:bar")])
    }

    @Test func quotesKeepSpacesInsideAWord() {
        #expect(ProcessQuery.words(in: #"path:"a b"  c "d e""#) == ["path:a b", "c", "d e"])
    }

    /// Bold only what made the row match: pid:771 bolds 771's PID, not the "771" inside 7712.
    @Test func highlightsFollowTheFields() {
        let query = ProcessQuery("chrome pid:771 user:root")
        #expect(query.nameHighlights == ["chrome"])
        #expect(query.pidHighlights(for: 771) == ["chrome", "771"])
        #expect(query.pidHighlights(for: 7712) == ["chrome"])
    }
}

struct SearchFieldsSamplingTests {
    @Test func samplerCarriesPathAndResolvesUserNames() async {
        let fake = FakeProcInfo()
        fake.pids = [5, 6]
        fake.owners = [5: 0, 6: 4_000_000]          // root, and a uid with no account
        fake.paths = [5: "/sbin/launchd"]
        let sampler = ProcessSampler(source: fake, apps: FakeRegularApps(), now: { 0 })

        let rows = await sampler.sample()
        #expect(rows.map(\.user) == ["root", "4000000"])
        #expect(rows.map(\.path) == ["/sbin/launchd", nil])
    }

    @Test func pathIsReadableForRootsProcesses() {
        #expect(ProcInfo().path(pid: 1) == "/sbin/launchd")
    }
}

struct MultiTermHighlightTests {
    @Test func boldsEveryTerm() {
        let attributed = MatchHighlight.attributed("Google Chrome Helper", terms: ["chrome", "help"])
        let bold = attributed.runs.filter { $0.inlinePresentationIntent == .stronglyEmphasized }
            .map { String(attributed[$0.range].characters) }
        #expect(bold == ["Chrome", "Help"])
    }
}
