import SwiftUI

/// Theme, saturation and bloom, from the sidebar's Colours button. Every choice is stored
/// (AppStorage), so it applies to every window and survives relaunch.
struct ColoursPopover: View {
    @Binding var themeID: String
    @Binding var bloomLevel: Double
    @Binding var saturationLevel: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Colours").font(.headline)

            Picker("Theme", selection: $themeID) {
                ForEach(Theme.all) { option in
                    Text(option.name).tag(option.id)
                }
            }
            .pickerStyle(.menu)

            slider("Saturation", systemImage: "drop", value: $saturationLevel)
            slider("Bloom", systemImage: "sparkles", value: $bloomLevel)

            HStack {
                Spacer()
                Button("Reset") {
                    themeID = Theme.system.id
                    bloomLevel = Bloom.defaultLevel
                    saturationLevel = SaturationLevel.defaultLevel
                }
            }
        }
        .padding(16)
        .frame(width: 280)
    }

    private func slider(_ title: String, systemImage: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label(title, systemImage: systemImage)
                Spacer()
                Text("\(Int(value.wrappedValue)) / 10")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: Bloom.levels, step: 1)
        }
    }
}
