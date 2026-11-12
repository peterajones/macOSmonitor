import Testing
import AppKit
@testable import macOSmonitor

struct MenuBarReadoutTests {
    private func vitals(gpu: GPUInfo? = nil, battery: BatteryInfo? = nil) -> SystemVitals {
        var v = SystemVitals(cpuUsagePercent: 23.4, usedMemoryBytes: 12_000_000_000,
                             totalMemoryBytes: 16_000_000_000, coreCount: 12, activeCoreCount: 12,
                             thermalState: "Nominal", lowPowerMode: false, uptime: 100,
                             osVersion: "macOS 27.2")
        v.gpu = gpu
        v.battery = battery
        return v
    }

    @Test func labelIsCPUOrADashBeforeTheFirstSample() {
        #expect(MenuBarReadout.label(nil) == "—")
        #expect(MenuBarReadout.label(vitals()) == "23%")
    }

    @Test func rowsFollowSidebarOrderAndOnlyIncludeWhatThisMacHas() {
        #expect(MenuBarReadout.rows(nil).isEmpty)
        #expect(MenuBarReadout.rows(vitals()).map(\.title) == ["CPU", "Memory", "Network"])

        let full = vitals(gpu: GPUInfo(utilizationPercent: 40, memoryInUseBytes: nil),
                          battery: BatteryInfo(chargePercent: 80, state: .ac, timeRemainingMinutes: nil))
        #expect(MenuBarReadout.rows(full).map(\.title) == ["CPU", "GPU", "Memory", "Network", "Battery"])
    }

    /// Each meter's fraction is its own reading, not a neighbour's; Network has no meter.
    @Test func metersShowTheirOwnFractions() {
        let full = vitals(gpu: GPUInfo(utilizationPercent: 40, memoryInUseBytes: nil),
                          battery: BatteryInfo(chargePercent: 80, state: .ac, timeRemainingMinutes: nil))
        let fractions = Dictionary(uniqueKeysWithValues: MenuBarReadout.rows(full).map { ($0.title, $0.fraction) })
        #expect(fractions["CPU"] == 23.4 / 100)     // computed like the code: 23.4 isn't exact in binary
        #expect(fractions["GPU"] == 0.4)
        #expect(fractions["Memory"] == 0.75)
        #expect(fractions["Battery"] == 0.8)
        #expect(fractions["Network"] == .some(nil))
        #expect(MenuBarReadout.rows(full).map(\.metric) == [.cpu, .gpu, .memory, .network, .battery])
    }
}

/// The menu-bar toggle (review-harness follow-up). The test host shares Peter's preferences, so
/// these check declared defaults and the live menu, and never write the setting.
@MainActor
struct MenuBarSettingsTests {
    @Test func storedKeyAndDefaultArePinned() {
        #expect(MenuBarSettings.key == "showMenuBarExtra")
        #expect(MenuBarSettings.shownByDefault)
    }

    @Test func viewMenuOffersTheToggle() async throws {
        func viewMenuTitles() -> [String] {
            NSApp.mainMenu?.items.first { $0.title == "View" }?.submenu?.items.map(\.title) ?? []
        }
        for _ in 0..<20 where !viewMenuTitles().contains(MenuBarSettings.menuTitle) {
            try await Task.sleep(for: .milliseconds(100))   // SwiftUI builds the menu after launch
        }
        #expect(viewMenuTitles().contains(MenuBarSettings.menuTitle), "View menu: \(viewMenuTitles())")
    }
}
