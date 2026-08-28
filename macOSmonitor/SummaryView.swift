import SwiftUI

/// The Summary dashboard: the app's landing surface.
///
/// Composes cards from data already sampled — no provider of its own. The upper
/// regions arrive in later tasks; the bottom stat row is here from the start.
struct SummaryView: View {
    let model: ProcessListModel
    let vitalsModel: VitalsModel
    @Binding var surface: Surface?

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 12) {
            Spacer()          // replaced by the CPU/top-processes row in Task 7
            statRow
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.panelBackground)
    }

    private var statRow: some View {
        HStack(spacing: 12) {
            StatCard(title: "Disk",
                     value: vitalsModel.vitals?.diskText ?? "—",
                     metric: .disk)
            StatCard(title: "Network",
                     value: vitalsModel.vitals?.networkText ?? "—",
                     metric: .network)
            // Omitted entirely when there is no battery (M9's rule), so a desktop
            // Mac shows three cards rather than a gap.
            if let battery = vitalsModel.vitals?.battery {
                StatCard(title: "Battery",
                         value: battery.displayText,
                         metric: .battery)
            }
            StatCard(title: "Thermal",
                     value: vitalsModel.vitals?.thermalState ?? "—",
                     metric: .thermal)
        }
    }
}
