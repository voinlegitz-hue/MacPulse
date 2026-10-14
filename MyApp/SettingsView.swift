import SwiftUI

struct SettingsView: View {
    @ObservedObject var preferences: MonitorPreferences

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Choose what appears in your dashboard.")
                        .font(.subheadline)
                    Text("Your choices are saved automatically.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                settingsSection("Dashboard cards", symbol: "square.grid.2x2") {
                    preferenceToggle("Processor", detail: "Current load and logical cores", symbol: "cpu", value: $preferences.showCPU)
                    preferenceToggle("Memory", detail: "Used and available RAM", symbol: "memorychip", value: $preferences.showRAM)
                    preferenceToggle("Storage", detail: "Space on the system volume", symbol: "internaldrive", value: $preferences.showDisk)
                    preferenceToggle("Network", detail: "Current receive and send rates", symbol: "arrow.left.arrow.right", value: $preferences.showNetwork)
                    preferenceToggle("Battery", detail: "Charge and available power details", symbol: "battery.75percent", value: $preferences.showBattery)
                    preferenceToggle("Temperature", detail: "Battery temperature may be available; CPU/GPU readings are not", symbol: "thermometer.medium", value: $preferences.showTemperature)
                }

                settingsSection("History", symbol: "chart.xyaxis.line") {
                    Toggle(isOn: $preferences.showHistory) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Show charts")
                                .font(.system(size: 13, weight: .medium))
                            Text("Keep recent measured samples in each graph")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)
                }

                settingsSection("Menu bar", symbol: "menubar.rectangle") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Show beside the MacPulse icon")
                            .font(.system(size: 13, weight: .medium))
                        Picker("Menu bar metric", selection: $preferences.menuBarMetric) {
                            Text("Icon only").tag(MenuBarMetric.icon)
                            Text("Processor").tag(MenuBarMetric.cpu)
                            Text("Memory").tag(MenuBarMetric.ram)
                            Text("Battery").tag(MenuBarMetric.battery)
                            Text("Adapter-reported wattage").tag(MenuBarMetric.power)
                            Text("Mac Occupancy (Conditional Index)").tag(MenuBarMetric.overallLoad)
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        Text("Conditional index: CPU (50%) and memory use (50%), renormalized over available readings. Disk activity is unavailable through a reliable public API; network is shown separately and is not treated as overload.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 10) {
                    Button("Show All") {
                        preferences.enableAll()
                    }
                    .buttonStyle(.bordered)

                    Button("Reset Display Settings") {
                        preferences.resetDisplaySettings()
                    }
                    .buttonStyle(.bordered)
                    .help("Restore default card and chart visibility")
                }

                HStack {
                    Text("MacPulse")
                        .font(.caption.weight(.medium))
                    Spacer()
                    Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 2)
            .padding(.bottom, 4)
        }
        .frame(maxHeight: 490)
    }

    private func settingsSection<Content: View>(
        _ title: String,
        symbol: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            Label(title, systemImage: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 10) {
                content()
            }
            .padding(13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.opacity(0.72), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(.primary.opacity(0.055), lineWidth: 1)
            }
        }
    }

    private func preferenceToggle(
        _ title: String,
        detail: String,
        symbol: String,
        value: Binding<Bool>
    ) -> some View {
        Toggle(isOn: value) {
            HStack(spacing: 9) {
                Image(systemName: symbol)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(width: 17)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
    }
}
