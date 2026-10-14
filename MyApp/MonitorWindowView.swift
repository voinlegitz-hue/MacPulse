import Charts
import SwiftUI

private enum MonitorWindowSection: String, CaseIterable, Identifiable {
    case overview
    case processes
    case cpu
    case memory
    case power
    case sensors
    case fans
    case storage
    case network
    case battery
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .processes: "Processes"
        case .cpu: "CPU"
        case .memory: "RAM"
        case .power: "Power"
        case .sensors: "Sensors"
        case .fans: "Fans"
        case .storage: "Storage"
        case .network: "Network"
        case .battery: "Battery"
        case .settings: "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .processes: "list.bullet.rectangle"
        case .cpu: "cpu"
        case .memory: "memorychip"
        case .power: "bolt"
        case .sensors: "thermometer.medium"
        case .fans: "fan"
        case .storage: "internaldrive"
        case .network: "arrow.left.arrow.right"
        case .battery: "battery.75percent"
        case .settings: "gearshape"
        }
    }
}

private struct RunningProcessIcon: View {
    let pid: Int32
    @State private var icon: NSImage?

    var body: some View {
        Group {
            if let icon {
                Image(nsImage: icon)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "gearshape.2")
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear {
            icon = NSWorkspace.shared.runningApplications
                .first(where: { $0.processIdentifier == pid })?.icon
        }
    }
}

struct MonitorWindowView: View {
    @ObservedObject var monitor: SystemMonitor
    @ObservedObject var preferences: MonitorPreferences
    @AppStorage("com.macpulse.windowSection") private var selectedSectionRaw = MonitorWindowSection.overview.rawValue
    @State private var requestedProcessID: String?

    private var selectedSection: Binding<MonitorWindowSection> {
        Binding(
            get: { MonitorWindowSection(rawValue: selectedSectionRaw) ?? .overview },
            set: { selectedSectionRaw = $0.rawValue }
        )
    }

    var body: some View {
        NavigationSplitView {
            List(selection: selectedSection) {
                ForEach(MonitorWindowSection.allCases) { section in
                    Label(section.title, systemImage: section.symbol)
                        .tag(section)
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("MacPulse")
            .frame(minWidth: 175)
        } detail: {
            VStack(spacing: 0) {
                HStack {
                    Text(selectedSection.wrappedValue.title)
                        .font(.system(.title2, design: .rounded).weight(.semibold))
                    Spacer()
                    HStack(spacing: 6) {
                        Circle().fill(.green).frame(width: 7, height: 7)
                        Text("Live monitoring")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 16)

                Divider()
                sectionContent
            }
            .background(.background)
        }
        .frame(minWidth: 850, minHeight: 600)
        .onAppear { monitor.start() }
    }

    @ViewBuilder
    private var sectionContent: some View {
        switch selectedSection.wrappedValue {
        case .overview:
            OverviewSection(
                monitor: monitor,
                preferences: preferences,
                navigate: { section in selectedSection.wrappedValue = section },
                selectProcess: { process in
                    requestedProcessID = process.id
                    selectedSection.wrappedValue = .processes
                }
            )
        case .processes:
            ProcessesView(
                processes: monitor.processes,
                inaccessibleProcessCount: monitor.inaccessibleProcessCount,
                samplingStatus: monitor.processSamplingStatus,
                samplingDiagnostics: monitor.processSamplingDiagnostics,
                retrySampling: monitor.retryProcessSampling,
                requestedSelectionID: requestedProcessID
            )
        case .cpu:
            ProcessorSection(monitor: monitor, enabled: preferences.showCPU)
        case .memory:
            MemorySection(monitor: monitor, enabled: preferences.showRAM)
        case .power:
            PowerSection(monitor: monitor)
        case .sensors:
            SensorsSection(monitor: monitor)
        case .fans:
            FansSection(monitor: monitor)
        case .storage:
            StorageSection(monitor: monitor)
        case .network:
            NetworkSection(monitor: monitor)
        case .battery:
            BatterySection(monitor: monitor)
        case .settings:
            SettingsView(preferences: preferences)
        }
    }
}

private struct OverviewSection: View {
    @ObservedObject var monitor: SystemMonitor
    @ObservedObject var preferences: MonitorPreferences
    let navigate: (MonitorWindowSection) -> Void
    let selectProcess: (ProcessUsage) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                occupancyHeader

                HStack(alignment: .top, spacing: 14) {
                    if preferences.showCPU {
                        HistoryPanel(title: "Processor", symbol: "cpu", color: .blue, keyPath: \.cpuUsage, history: monitor.history)
                    }
                    if preferences.showRAM {
                        HistoryPanel(title: "Memory", symbol: "memorychip", color: .green, keyPath: \.memoryUsage, history: monitor.history)
                    }
                }

                HStack(alignment: .top, spacing: 14) {
                    topProcesses
                    systemDetails
                }
            }
            .padding(22)
        }
    }

    private var occupancyHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 24) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Mac Occupancy")
                        .font(.system(.headline, design: .rounded))
                    Text("A conditional index, not an official macOS measurement")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("CPU 50% + used RAM 50%; unavailable components are excluded and remaining weights renormalized.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .help("The index summarizes CPU and memory use only. It is not a literal fraction of all computing capacity.")
                }

                Spacer()
                AnimatedPercentText(value: monitor.snapshot.overallLoad?.percentage, reservedWidth: 96)
                    .font(.system(size: 38, weight: .semibold, design: .rounded).monospacedDigit())
                    .help(monitor.snapshot.overallLoad?.isPartial == true ? "Partial index; one or more readings are unavailable." : "CPU and memory weighted equally.")
            }
            HStack(spacing: 15) {
                metricLink(title: "CPU", value: monitor.snapshot.cpu.loadPercent, section: .cpu, color: .blue)
                metricLink(
                    title: "RAM",
                    value: monitor.snapshot.memory.available ? monitor.snapshot.memory.usagePercent : nil,
                    section: .memory,
                    color: .green
                )
            }
        }
        .padding(20)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
    }

    private func metricLink(title: String, value: Double?, section: MonitorWindowSection, color: Color) -> some View {
        Button {
            navigate(section)
        } label: {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(title).foregroundStyle(.secondary)
                AnimatedPercentText(value: value, reservedWidth: 44)
                    .fontWeight(.semibold)
            }
            .font(.system(size: 12))
        }
        .buttonStyle(.plain)
    }

    private var topProcesses: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label("Most active processes", systemImage: "list.number")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("Show All") { navigate(.processes) }
                    .buttonStyle(.link)
                    .font(.caption)
            }
            ForEach(monitor.processes.prefix(5)) { process in
                Button {
                    selectProcess(process)
                } label: {
                    HStack(spacing: 8) {
                        RunningProcessIcon(pid: process.pid)
                            .frame(width: 20, height: 20)
                        Text(process.name)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text(process.cpuPercent.map { String(format: "%.1f%%", $0) } ?? "—")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .help("Show \(process.name) in Processes")
            }
            if monitor.processes.isEmpty {
                switch monitor.processSamplingStatus {
                case .loading:
                    Text("Collecting process samples…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .loaded:
                    Text("No readable running processes were found.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case let .failed(message):
                    VStack(alignment: .leading, spacing: 5) {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Retry process collection", action: monitor.retryProcessSampling)
                            .buttonStyle(.link)
                            .font(.caption)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(15)
        .background(.background, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.primary.opacity(0.08), lineWidth: 1)
        }
    }

    private var systemDetails: some View {
        VStack(alignment: .leading, spacing: 11) {
            Label("System", systemImage: "desktopcomputer")
                .font(.system(size: 13, weight: .semibold))
            detailRow("Storage", monitor.snapshot.disk.available
                ? "\(DiskFormatter.formatBytes(monitor.snapshot.disk.usedBytes)) used · \(DiskFormatter.formatBytes(monitor.snapshot.disk.freeBytes)) free"
                : "Unavailable")
            detailRow("Network", monitor.snapshot.network.available
                ? "↓ \(ByteFormatter.formatSpeed(monitor.snapshot.network.downloadRateBytesPerSecond)) · ↑ \(ByteFormatter.formatSpeed(monitor.snapshot.network.uploadRateBytesPerSecond))"
                : "Unavailable")
            detailRow("Power", monitor.snapshot.battery.source)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(15)
        .background(.background, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.primary.opacity(0.08), lineWidth: 1)
        }
    }

    private func detailRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(value)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
        }
        .font(.system(size: 11))
    }
}

private struct ProcessorSection: View {
    @ObservedObject var monitor: SystemMonitor
    let enabled: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if !enabled {
                    disabledMessage("Processor is hidden in display settings.")
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        AnimatedPercentText(
                            value: monitor.snapshot.cpu.loadPercent,
                            unavailableText: monitor.snapshot.cpu.status.hasPrefix("Waiting") ? "Loading…" : "Unavailable",
                            reservedWidth: 84,
                            alignment: .leading
                        )
                            .font(.system(size: 36, weight: .semibold, design: .rounded).monospacedDigit())
                        Text("Total CPU · \(ProcessInfo.processInfo.processorCount) logical cores")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    CPUHistoryChart(history: monitor.history)
                    if !monitor.cpuClusters.isEmpty {
                        HStack(spacing: 10) {
                            ForEach(monitor.cpuClusters) { cluster in
                                Label("\(cluster.name): \(cluster.logicalCPUCount)", systemImage: "cpu")
                                    .font(.caption)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 7)
                                    .background(.quaternary.opacity(0.45), in: Capsule())
                            }
                        }
                        Text("Cluster counts come from macOS sysctl. The current per-core CPU source does not identify which cluster each logical CPU belongs to.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    coreGrid
                }
            }
            .padding(22)
        }
    }

    private var coreGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 10)], spacing: 10) {
            ForEach(monitor.coreUsage) { core in
                HStack {
                    Text("Core \(core.index + 1)")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(core.cpuPercent.map { String(format: "%.0f%%", $0) } ?? "—")
                        .monospacedDigit()
                        .fontWeight(.medium)
                }
                .font(.system(size: 12))
                .padding(10)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }
}

private struct MemorySection: View {
    @ObservedObject var monitor: SystemMonitor
    let enabled: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if !enabled {
                    disabledMessage("Memory is hidden in display settings.")
                } else if monitor.snapshot.memory.available {
                    HStack(spacing: 24) {
                        memoryValue("Used", monitor.snapshot.memory.usedBytes, color: .green)
                        memoryValue("Available", monitor.snapshot.memory.availableBytes, color: .secondary)
                        memoryValue("Physical", monitor.snapshot.memory.totalBytes, color: .primary)
                    }
                    .help("Used includes active, wired and compressed memory; free, inactive and purgeable reclaimable pages are excluded.")
                    HistoryPanel(
                        title: "Memory usage",
                        symbol: "memorychip",
                        color: .green,
                        keyPath: \.memoryUsage,
                        history: monitor.history
                    )
                } else {
                    disabledMessage("Memory measurement is unavailable.")
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Largest process footprints")
                        .font(.system(size: 13, weight: .semibold))
                    ForEach(monitor.processes.sorted {
                        ($0.memoryBytes ?? 0) > ($1.memoryBytes ?? 0)
                    }.prefix(12)) { process in
                        HStack {
                            Text(process.name).lineLimit(1)
                            Spacer()
                            Text(process.memoryBytes.map(DiskFormatter.formatBytes) ?? "—")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        .font(.system(size: 12))
                    }
                }
                .padding(15)
                .background(.background, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .padding(22)
        }
    }

    private func memoryValue(_ title: String, _ bytes: UInt64, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(DiskFormatter.formatBytes(bytes))
                .font(.system(.title3, design: .rounded).weight(.semibold).monospacedDigit())
                .foregroundStyle(color)
        }
    }
}

private struct HistoryPanel: View {
    let title: String
    let symbol: String
    let color: Color
    let keyPath: KeyPath<MetricHistorySample, Double?>
    let history: [MetricHistorySample]

    private var samples: [MetricHistorySample] {
        history.filter { $0[keyPath: keyPath] != nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: symbol)
                .font(.system(size: 13, weight: .semibold))
            if samples.count > 1 {
                Chart(samples) { sample in
                    if let value = sample[keyPath: keyPath] {
                        AreaMark(x: .value("Time", sample.date), y: .value("Value", value))
                            .foregroundStyle(color.opacity(0.08))
                    }
                    if let value = sample[keyPath: keyPath] {
                        LineMark(x: .value("Time", sample.date), y: .value("Value", value))
                            .foregroundStyle(color)
                            .lineStyle(StrokeStyle(lineWidth: 1.6, lineCap: .round))
                    }
                }
                .chartYScale(domain: 0...100)
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .frame(height: 125)
            } else {
                Text("Collecting real samples…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 125)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(15)
        .background(.background, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.primary.opacity(0.08), lineWidth: 1)
        }
    }
}

private struct CPUHistoryChart: View {
    let history: [MetricHistorySample]

    var body: some View {
        HistoryPanel(
            title: "CPU history",
            symbol: "chart.xyaxis.line",
            color: .blue,
            keyPath: \.cpuUsage,
            history: history
        )
    }
}

private func disabledMessage(_ message: String) -> some View {
    ContentUnavailableViewCompat(message: message)
}

private struct ContentUnavailableViewCompat: View {
    let message: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "info.circle")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 170)
    }
}

private struct PowerSection: View {
    @ObservedObject var monitor: SystemMonitor

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                detailCard(title: "Adapter-reported wattage", symbol: "powerplug") {
                    Text(adapterWattageLabel)
                        .font(.system(.largeTitle, design: .rounded).weight(.semibold).monospacedDigit())
                    Text("The value reported by macOS for the connected adapter; it is not a measurement of total Mac power consumption.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let voltage = monitor.snapshot.battery.adapterVoltageEstimate {
                        Text("Approx. adapter voltage from reported wattage/current: \(voltage.formatted(.number.precision(.fractionLength(1)))) V")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                detailCard(title: "Battery transfer estimate", symbol: "battery.100.bolt") {
                    Text(batteryPowerLabel)
                        .font(.system(.title2, design: .rounded).weight(.semibold).monospacedDigit())
                    Text("Estimated from battery-controller voltage and current. This is battery charging/discharging power, not total system draw.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                detailCard(title: "Adapter history", symbol: "chart.xyaxis.line") {
                    if monitor.powerHistory.count > 1 {
                        Chart {
                            ForEach(monitor.powerHistory) { sample in
                                if let watts = sample.adapterReportedWatts {
                                    LineMark(
                                        x: .value("Time", sample.date),
                                        y: .value("Watts", watts),
                                        series: .value("Reading", "Adapter reported")
                                    )
                                    .foregroundStyle(.orange)
                                }
                                if let watts = sample.batteryPowerWatts {
                                    LineMark(
                                        x: .value("Time", sample.date),
                                        y: .value("Watts", watts),
                                        series: .value("Reading", "Battery transfer")
                                    )
                                    .foregroundStyle(.blue)
                                }
                            }
                        }
                        .chartYAxisLabel("Watts")
                        .chartLegend(position: .bottom, alignment: .leading)
                        .chartXAxis(.hidden)
                        .frame(height: 170)
                        Text("Up to 500 samples, updated every 2 seconds. Adapter wattage is the system-reported adapter value; battery transfer is calculated from battery-controller voltage and current.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("No adapter power history is available yet. Connect an adapter reporting a wattage to begin collecting samples.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(22)
        }
    }

    private var batteryPowerLabel: String {
        guard let watts = monitor.snapshot.battery.batteryPowerWatts else { return "Unavailable" }
        guard abs(watts) >= 0.05 else { return "No battery transfer reported" }
        let direction = watts >= 0 ? "Charging" : "Discharging"
        return "\(direction) · \(abs(watts).formatted(.number.precision(.fractionLength(1)))) W"
    }

    private var adapterWattageLabel: String {
        if let watts = monitor.snapshot.battery.adapterWatts {
            return "\(watts.formatted(.number.precision(.fractionLength(0)))) W"
        }
        return monitor.snapshot.battery.source.localizedCaseInsensitiveContains("AC Power")
            ? "Adapter wattage unavailable"
            : "No external adapter"
    }
}

private struct SensorsSection: View {
    @ObservedObject var monitor: SystemMonitor

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                detailCard(title: "Available sensors", symbol: "thermometer.medium") {
                    if monitor.sensors.isEmpty {
                        Text(monitor.hardwareTelemetryDiagnostics)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(monitor.sensors) { sensor in
                            LabeledContent(sensor.name, value: "\(sensor.valueCelsius.formatted(.number.precision(.fractionLength(1)))) °C")
                            Text("Available · Source: \(sensor.source)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text(monitor.hardwareTelemetryDiagnostics)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                detailCard(title: "CPU / GPU / SoC temperatures", symbol: "cpu") {
                    Text("CPU core and GPU sensor temperatures are read from AppleSMCKeysEndpoint. Unavailable mapped keys are listed above. No separately identified SoC die temperature key was confirmed on this Mac; thermal pressure is not substituted for temperature.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(22)
        }
    }
}

private struct FansSection: View {
    @ObservedObject var monitor: SystemMonitor
    @ObservedObject private var fanControl = FanControlService.shared
    @State private var requestedRPM: [Int: Double] = [:]
    @AppStorage("com.macpulse.autoBoost.triggerCelsius") private var autoBoostTriggerCelsius = 80.0
    @AppStorage("com.macpulse.autoBoost.releaseCelsius") private var autoBoostReleaseCelsius = 70.0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                detailCard(title: "Fan status", symbol: "fan") {
                    if monitor.fans.isEmpty {
                        Text(monitor.hardwareTelemetryDiagnostics)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(monitor.fans) { fan in
                            LabeledContent(
                                "Fan \(fan.index + 1)",
                                value: fan.currentRPM.map {
                                    "\($0.formatted(.number.precision(.fractionLength(0)))) RPM · Available"
                                } ?? "Unavailable"
                            )
                            LabeledContent(
                                "Fan \(fan.index + 1) target",
                                value: fan.targetRPM.map {
                                    "\($0.formatted(.number.precision(.fractionLength(0)))) RPM"
                                } ?? "Unavailable"
                            )
                            LabeledContent(
                                "Available range",
                                value: fan.minimumRPM.flatMap { minimum in
                                    fan.maximumRPM.map { maximum in
                                        "\(Int(minimum.rounded()))–\(Int(maximum.rounded())) RPM"
                                    }
                                } ?? "Min/max unavailable"
                            )
                            LabeledContent("Controller", value: fan.controllerModeDescription)
                        }
                        Text(monitor.hardwareTelemetryDiagnostics)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                detailCard(title: "Manual control", symbol: "hand.raised") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(fanControl.helperStatus)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        if fanControl.canRegisterHelper {
                            Button("Install privileged helper…") {
                                Task { await fanControl.installHelper() }
                            }
                            .disabled(fanControl.isBusy)
                        }
                        if fanControl.isHelperEnabled {
                            Button("Update privileged helper…") {
                                Task { await fanControl.refreshHelperInstallation() }
                            }
                            .disabled(fanControl.isBusy || fanControl.manualControlActive)
                        }
                        if fanControl.helperNeedsApproval {
                            Button("Open Login Items Settings") {
                                fanControl.openLoginItemsSettings()
                            }
                        }

                        if !fanControl.readings.isEmpty {
                            ForEach(fanControl.readings) { fan in
                                if let minimum = fan.minimumRPM,
                                   let maximum = fan.maximumRPM,
                                   minimum.isFinite, maximum.isFinite,
                                   minimum > 0, maximum > minimum {
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text("Fan \(fan.index + 1) · \(fan.modeDescription)")
                                            .font(.headline)
                                        Slider(
                                            value: targetBinding(for: fan),
                                            in: minimum...maximum,
                                            step: 100
                                        )
                                        Text(
                                            "Requested target: \(Int(targetBinding(for: fan).wrappedValue.rounded())) RPM "
                                                + "(range \(Int(minimum.rounded()))–\(Int(maximum.rounded())) RPM)"
                                        )
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        HStack {
                                            Button("Apply Manual") {
                                                Task {
                                                    await fanControl.setManual(
                                                        fan: fan,
                                                        rpm: targetBinding(for: fan).wrappedValue
                                                    )
                                                }
                                            }
                                            .disabled(fanControl.isBusy || !fanControl.isHelperEnabled)
                                            Button("System / Auto") {
                                                Task { await fanControl.restoreAutomatic() }
                                            }
                                            .disabled(fanControl.isBusy)
                                        }
                                    }
                                    .padding(.vertical, 6)
                                } else {
                                    Text("Fan \(fan.index + 1): the controller did not report a usable RPM range; manual control is unavailable.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }

                        if fanControl.manualControlActive {
                            Label("Manual control is confirmed; helper watchdog is active.", systemImage: "checkmark.shield")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let error = fanControl.lastError {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                        Button("Refresh controller state") {
                            Task { await fanControl.refresh() }
                        }
                        .disabled(fanControl.isBusy)
                    }
                }
                detailCard(title: "Auto Boost", symbol: "thermometer.high") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(fanControl.autoBoostStatus)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text("Uses fresh CPU/GPU sensor readings. The fan target is raised by up to 500 RPM within the controller-reported range; System / Auto is requested below the release threshold.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Stepper(
                            "Boost at \(Int(autoBoostTriggerCelsius))°C",
                            value: $autoBoostTriggerCelsius,
                            in: 60...100,
                            step: 1
                        )
                        Stepper(
                            "Return to Auto at \(Int(autoBoostReleaseCelsius))°C",
                            value: $autoBoostReleaseCelsius,
                            in: 45...95,
                            step: 1
                        )
                        HStack {
                            Button(fanControl.autoBoostActive ? "Disable Auto Boost" : "Enable Auto Boost") {
                                Task {
                                    if fanControl.autoBoostActive {
                                        await fanControl.disableAutoBoost()
                                    } else {
                                        await fanControl.enableAutoBoost(
                                            triggerCelsius: autoBoostTriggerCelsius,
                                            releaseCelsius: autoBoostReleaseCelsius
                                        )
                                    }
                                }
                            }
                            .disabled(
                                fanControl.isBusy
                                    || (!fanControl.autoBoostActive
                                        && (!fanControl.isHelperEnabled
                                            || !FanAutoBoostPolicy.hasValidThresholds(
                                                trigger: autoBoostTriggerCelsius,
                                                release: autoBoostReleaseCelsius
                                            )))
                            )
                            if fanControl.autoBoostActive {
                                Button("System / Auto now") {
                                    Task { await fanControl.disableAutoBoost() }
                                }
                                .disabled(fanControl.isBusy)
                            }
                        }
                    }
                }
            }
            .padding(22)
        }
        .task {
            await fanControl.refresh()
            for fan in fanControl.readings {
                requestedRPM[fan.index] = initialTarget(for: fan)
            }
        }
    }

    private func targetBinding(for fan: FanControlReading) -> Binding<Double> {
        Binding(
            get: { requestedRPM[fan.index] ?? initialTarget(for: fan) },
            set: { requestedRPM[fan.index] = $0 }
        )
    }

    private func initialTarget(for fan: FanControlReading) -> Double {
        guard let minimum = fan.minimumRPM, let maximum = fan.maximumRPM,
              minimum.isFinite, maximum.isFinite,
              minimum > 0, maximum > minimum else {
            return 0
        }
        for candidate in [requestedRPM[fan.index], fan.targetRPM, fan.currentRPM].compactMap({ $0 }) {
            if FanControlValidation.isTargetWithinReportedRange(candidate, minimum: minimum, maximum: maximum) {
                return candidate
            }
        }
        return minimum
    }
}

private struct StorageSection: View {
    @ObservedObject var monitor: SystemMonitor

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                detailCard(title: monitor.snapshot.disk.volumeName, symbol: "internaldrive") {
                    if monitor.snapshot.disk.available {
                        LabeledContent("Used", value: DiskFormatter.formatBytes(monitor.snapshot.disk.usedBytes))
                        LabeledContent("Free", value: DiskFormatter.formatBytes(monitor.snapshot.disk.freeBytes))
                        LabeledContent("Capacity", value: DiskFormatter.formatBytes(monitor.snapshot.disk.totalBytes))
                        ProgressView(value: monitor.snapshot.disk.usagePercent, total: 100)
                        Text("\(monitor.snapshot.disk.usagePercent.formatted(.number.precision(.fractionLength(1))))% used")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Volume capacity is unavailable.")
                            .foregroundStyle(.secondary)
                    }
                }
                detailCard(title: "Disk activity", symbol: "waveform.path") {
                    Text("Per-process disk I/O and live volume throughput are not available through the current reliable public data source. Storage capacity is shown separately.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(22)
        }
    }
}

private struct NetworkSection: View {
    @ObservedObject var monitor: SystemMonitor

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                detailCard(title: "Network throughput", symbol: "arrow.left.arrow.right") {
                    if monitor.snapshot.network.available {
                        LabeledContent("Download", value: ByteFormatter.formatSpeed(monitor.snapshot.network.downloadRateBytesPerSecond))
                        LabeledContent("Upload", value: ByteFormatter.formatSpeed(monitor.snapshot.network.uploadRateBytesPerSecond))
                    } else {
                        Text("Waiting for a second sample from an active physical Ethernet or Wi-Fi interface.")
                            .foregroundStyle(.secondary)
                    }
                }
                detailCard(title: "Data source", symbol: "info.circle") {
                    Text("Rates are calculated from macOS interface byte counters. VPN, bridge, and tunnel interfaces are excluded to avoid double counting.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(22)
        }
    }
}

private struct BatterySection: View {
    @ObservedObject var monitor: SystemMonitor

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                detailCard(title: "Battery", symbol: "battery.75percent") {
                    LabeledContent("Charge", value: monitor.snapshot.battery.levelPercent.map { "\($0.formatted(.number.precision(.fractionLength(0))))%" } ?? "Unavailable")
                    LabeledContent("Power source", value: monitor.snapshot.battery.source)
                    LabeledContent("State", value: monitor.snapshot.battery.isCharging.map { $0 ? "Charging" : "Not charging" } ?? "Unavailable")
                    LabeledContent("Cycle count", value: monitor.snapshot.battery.cycleCount.map(String.init) ?? "Unavailable")
                    LabeledContent("Maximum capacity estimate", value: monitor.snapshot.battery.healthPercent.map { "\($0.formatted(.number.precision(.fractionLength(0))))%" } ?? "Unavailable")
                    if let temperature = monitor.snapshot.battery.temperatureCelsius {
                        LabeledContent("Battery temperature", value: "\(temperature.formatted(.number.precision(.fractionLength(1)))) °C")
                    }
                }
                detailCard(title: "Electrical readings", symbol: "bolt") {
                    LabeledContent("Battery voltage", value: monitor.snapshot.battery.voltage.map { "\($0.formatted(.number.precision(.fractionLength(2)))) V" } ?? "Unavailable")
                    LabeledContent("Battery current", value: monitor.snapshot.battery.current.map { "\($0.formatted(.number.precision(.fractionLength(2)))) A" } ?? "Unavailable")
                    LabeledContent("Adapter reported", value: monitor.snapshot.battery.adapterWatts.map { "\($0.formatted(.number.precision(.fractionLength(0)))) W" } ?? "Not connected / unavailable")
                    Text("Battery capacity/health and electrical properties are reported by the system battery controller. Adapter wattage is its reported rating, not Mac consumption.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(22)
        }
    }
}

@ViewBuilder
private func detailCard<Content: View>(
    title: String,
    symbol: String,
    @ViewBuilder content: () -> Content
) -> some View {
    VStack(alignment: .leading, spacing: 11) {
        Label(title, systemImage: symbol)
            .font(.system(size: 14, weight: .semibold))
        content()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(16)
    .background(.background, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    .overlay {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(.primary.opacity(0.08), lineWidth: 1)
    }
}
