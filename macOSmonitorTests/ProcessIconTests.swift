import Testing
import AppKit
@testable import macOSmonitor

/// A process's icon comes from the innermost app bundle its executable lives in, so a
/// helper nested inside an app shows the helper bundle's own icon; tools outside any app
/// bundle have none.
struct ProcessIconTests {
    @Test func anAppsExecutableUsesItsBundle() {
        #expect(ProcessIcon.bundlePath(forExecutable: "/Applications/Xcode.app/Contents/MacOS/Xcode")
                == "/Applications/Xcode.app")
    }

    @Test func aNestedHelperUsesTheInnermostBundle() {
        let helper = "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework"
            + "/Versions/A/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)"
        #expect(ProcessIcon.bundlePath(forExecutable: helper) == "/Applications/Google Chrome.app/Contents/Frameworks"
                + "/Google Chrome Framework.framework/Versions/A/Helpers/Google Chrome Helper (Renderer).app")
    }

    @Test func aToolOutsideAnyAppHasNoBundle() {
        #expect(ProcessIcon.bundlePath(forExecutable: "/usr/sbin/cfprefsd") == nil)
        #expect(ProcessIcon.bundlePath(forExecutable: nil) == nil)
    }

    @Test func onlyAWholeComponentEndingInAppCounts() {
        #expect(ProcessIcon.bundlePath(forExecutable: "/opt/my.application/bin/tool") == nil)
        #expect(ProcessIcon.bundlePath(forExecutable: "/opt/webapp/bin/tool") == nil)
    }

    @MainActor @Test func theCacheGivesAnIconForAnAppAndNoneForATool() {
        let cache = ProcessIconCache()
        #expect(cache.icon(forExecutable: "/System/Applications/Calculator.app/Contents/MacOS/Calculator") != nil)
        #expect(cache.icon(forExecutable: "/usr/bin/true") == nil)
    }

    @MainActor @Test func theCacheReturnsTheSameImageForTheSameBundle() {
        let cache = ProcessIconCache()
        let path = "/System/Applications/Calculator.app/Contents/MacOS/Calculator"
        #expect(cache.icon(forExecutable: path) === cache.icon(forExecutable: path))
    }
}
