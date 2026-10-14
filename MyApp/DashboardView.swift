import SwiftUI
import Charts
import AppKit

struct AnimatedPercentText: View {
    let value: Double?
    var unavailableText = "—"
    var reservedWidth: CGFloat = 58
    var alignment: Alignment = .trailing

    var body: some View {
        Group {
            if let value, value.isFinite {
                let displayedValue = NumericValueAnimation.displayedInteger(value)
                Text("\(displayedValue)%")
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(.easeInOut(duration: 0.2), value: displayedValue)
            } else {
                Text(unavailableText).monospacedDigit()
            }
        }
        .frame(width: reservedWidth, alignment: alignment)
    }
}

struct DashboardView: View {
    @ObservedObject var monitor: SystemMonitor
    @ObservedObject var preferences: MonitorPreferences
    @Environment(\.openWindow) private var openWindow
    @State private var settingsVisible = false
    @State private var showingProcesses = false

    private var visibleMetricCount: Int {
        [
            preferences.showCPU,
            preferences.showRAM,
            preferences.showDisk,
            preferences.showNetwork,
            preferences.showBattery,
            preferences.showTemperature
        ].filter { $0 }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if !settingsVisible {
                Picker("View", selection: $showingProcesses) {
                    Text("Overview").tag(false)
                    Text("Processes").tag(true)
                }
                .pickerStyle(.segmented)
                .controlSize(.small)
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
            }
            Divider().opacity(0.55)

            if settingsVisible {
                SettingsView(preferences: preferences)
                    .padding(.horizontal, 17)
                    .padding(.vertical, 14)
            } else {
                if showingProcesses {
                    ProcessesView(
                        processes: monitor.processes,
                        inaccessibleProcessCount: monitor.inaccessibleProcessCount,
                        samplingStatus: monitor.processSamplingStatus,
                        samplingDiagnostics: monitor.processSamplingDiagnostics,
                        retrySampling: monitor.retryProcessSampling
                    )
                } else {
                    dashboardContent
                }
            }

            footer
        }
        .frame(width: 380)
        .background(.regularMaterial)
        .animation(.easeInOut(duration: 0.18), value: settingsVisible)
        .animation(.easeInOut(duration: 0.18), value: visibleMetricCount)
    }

    private var header: some View {
        HStack(spacing: 11) {
            Image(systemName: "waveform.path.ecg")
                .font(.system(size: 21, weight: .medium))
                .foregroundStyle(.tint)
                .frame(width: 30, height: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text("MacPulse")
                    .font(.system(.headline, design: .rounded).weight(.semibold))
                Text(settingsVisible ? "Display settings" : showingProcesses ? "Running processes" : "System monitor")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            if !settingsVisible {
                HStack(spacing: 5) {
                    Circle()
                        .fill(.green)
                        .frame(width: 6, height: 6)
                    Text("Monitoring")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(.quaternary, in: Capsule())
            }

            Button {
                settingsVisible.toggle()
            } label: {
                Image(systemName: settingsVisible ? "chevron.left" : "slider.horizontal.3")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 29, height: 29)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(settingsVisible ? "Back to overview" : "Display settings")
            .accessibilityLabel(settingsVisible ? "Back to overview" : "Display settings")
        }
        .padding(.horizontal, 17)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var dashboardContent: some View {
        if visibleMetricCount == 0 && !preferences.showHistory {
            VStack(spacing: 9) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 23))
                    .foregroundStyle(.secondary)
                Text("No metrics selected")
                    .font(.headline)
                Text("Choose the metrics to show in Display Settings.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, minHeight: 175)
            .padding(.horizontal, 26)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 13) {
                    occupancySummary

                    if preferences.showCPU || preferences.showRAM {
                        primaryMetrics
                    }

                    if preferences.showCPU {
                        CoreUsageView(cores: monitor.coreUsage)
                    }

                    if preferences.showDisk
                        || preferences.showNetwork
                        || preferences.showBattery
                        || preferences.showTemperature {
                        secondaryMetrics
                    }

                    if preferences.showHistory {
                        historySection
                    }
                }
                .padding(.horizontal, 15)
                .padding(.vertical, 13)
            }
            .frame(maxHeight: 470)
        }
    }

    private var occupancySummary: some View {
        let load = monitor.snapshot.overallLoad
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Mac Occupancy")
                        .font(.system(size: 12, weight: .semibold))
                    Text(load?.isPartial == true ? "Partial conditional index" : "CPU and memory use, weighted equally")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                AnimatedPercentText(value: load?.percentage, reservedWidth: 60)
                    .font(.system(size: 25, weight: .semibold, design: .rounded).monospacedDigit())
            }

            HStack(spacing: 10) {
                HStack(spacing: 4) {
                    Image(systemName: "cpu")
                    AnimatedPercentText(
                        value: monitor.snapshot.cpu.loadPercent,
                        unavailableText: monitor.snapshot.cpu.status.hasPrefix("Waiting") ? "Loading" : "CPU —",
                        reservedWidth: 48
                    )
                }
                .foregroundStyle(.blue)
                HStack(spacing: 4) {
                    Image(systemName: "memorychip")
                    AnimatedPercentText(
                        value: monitor.snapshot.memory.available ? monitor.snapshot.memory.usagePercent : nil,
                        unavailableText: "RAM —",
                        reservedWidth: 48
                    )
                }
                .foregroundStyle(.green)
            }
            .font(.system(size: 10, weight: .medium).monospacedDigit())

            MetricSparkline(
                samples: monitor.history,
                value: \.overallLoadPercent,
                color: .blue,
                range: 0...100
            )
        }
        .padding(13)
        .background(.background.opacity(0.78), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.primary.opacity(0.055), lineWidth: 1)
        }
        .help("Conditional MacPulse index = 50% CPU + 50% used RAM. It is not an official macOS metric or a literal measure of all computing capacity.")
    }

    private var primaryMetrics: some View {
        HStack(alignment: .top, spacing: 0) {
            if preferences.showCPU {
                primaryMetric(
                    symbol: "cpu",
                    title: "Processor",
                    value: monitor.snapshot.cpu.loadPercent,
                    detail: monitor.snapshot.cpu.loadPercent == nil
                        ? monitor.snapshot.cpu.status
                        : "\(ProcessInfo.processInfo.processorCount) logical cores",
                    color: .blue
                )
            }

            if preferences.showCPU && preferences.showRAM {
                Rectangle()
                    .fill(.quaternary)
                    .frame(width: 1)
                    .padding(.horizontal, 14)
            }

            if preferences.showRAM {
                primaryMetric(
                    symbol: "memorychip",
                    title: "Memory",
                    value: monitor.snapshot.memory.available ? monitor.snapshot.memory.usagePercent : nil,
                    detail: monitor.snapshot.memory.available
                        ? "\(gigabytes(monitor.snapshot.memory.usedBytes)) of \(gigabytes(monitor.snapshot.memory.totalBytes)) GB used"
                        : "Memory data unavailable",
                    color: .green
                )
            }
        }
        .padding(14)
        .background(.background.opacity(0.78), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.primary.opacity(0.055), lineWidth: 1)
        }
    }

    private func primaryMetric(
        symbol: String,
        title: String,
        value: Double?,
        detail: String,
        color: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            AnimatedPercentText(
                value: value,
                unavailableText: value == nil && title == "Processor" && monitor.snapshot.cpu.status.hasPrefix("Waiting")
                    ? "Loading…"
                    : "—",
                reservedWidth: 76,
                alignment: .leading
            )
                .font(.system(size: 29, weight: .semibold, design: .rounded).monospacedDigit())

            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .help(title == "Memory"
                    ? "Used excludes free, inactive and purgeable reclaimable pages; it includes active, wired and compressed memory."
                    : detail)

            if preferences.showHistory {
                MetricSparkline(
                    samples: monitor.history,
                    value: title == "Processor" ? \.cpuUsage : \.memoryUsage,
                    color: color,
                    range: 0...100
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var secondaryMetrics: some View {
        VStack(spacing: 0) {
            if preferences.showDisk {
                metricRow(symbol: "internaldrive", title: "Storage") {
                    if monitor.snapshot.disk.available {
                        Text("\(gigabytes(monitor.snapshot.disk.usedBytes)) GB used")
                            .font(.system(.subheadline, design: .rounded).weight(.semibold).monospacedDigit())
                        Text("\(gigabytes(monitor.snapshot.disk.freeBytes)) GB free of \(gigabytes(monitor.snapshot.disk.totalBytes)) GB")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        ProgressView(value: monitor.snapshot.disk.usagePercent, total: 100)
                            .tint(.purple)
                            .controlSize(.small)
                            .frame(width: 120)
                    } else {
                        unavailableValue("Storage data unavailable")
                    }
                }
            }

            if preferences.showNetwork {
                rowDivider
                metricRow(symbol: "arrow.left.arrow.right", title: "Network") {
                    if monitor.snapshot.network.available {
                        HStack(spacing: 10) {
                            Label(ByteFormatter.formatSpeed(monitor.snapshot.network.downloadRateBytesPerSecond), systemImage: "arrow.down")
                                .foregroundStyle(.blue)
                            Label(ByteFormatter.formatSpeed(monitor.snapshot.network.uploadRateBytesPerSecond), systemImage: "arrow.up")
                                .foregroundStyle(.orange)
                        }
                        .font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())

                        if preferences.showHistory {
                            NetworkSparkline(samples: monitor.history)
                        }
                    } else {
                        unavailableValue("Collecting interface sample")
                    }
                }
                .help("Receive and send rates use byte-counter deltas from unique active Ethernet/Wi-Fi link-layer interfaces. Virtual interfaces are excluded.")
            }

            if preferences.showBattery {
                rowDivider
                metricRow(symbol: batterySymbol, title: "Battery") {
                    if let level = monitor.snapshot.battery.levelPercent {
                        Text(formatPercent(level))
                            .font(.system(.subheadline, design: .rounded).weight(.semibold).monospacedDigit())
                        Text(batteryDetail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else if monitor.snapshot.battery.source != "Unavailable" {
                        Text(monitor.snapshot.battery.source)
                            .font(.system(.subheadline, design: .rounded).weight(.semibold))
                        Text(batteryDetail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else {
                        unavailableValue("Battery data unavailable")
                    }
                }
            }

            if preferences.showTemperature {
                rowDivider
                metricRow(symbol: "thermometer.medium", title: "Temperature") {
                    Text("Unavailable")
                        .font(.system(.subheadline, design: .rounded).weight(.medium))
                        .foregroundStyle(.secondary)
                    Text(monitor.snapshot.temperature.message)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 13)
        .background(.background.opacity(0.78), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.primary.opacity(0.055), lineWidth: 1)
        }
    }

    private func metricRow<Content: View>(
        symbol: String,
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 18)

            Text(title)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 66, alignment: .leading)

            Spacer(minLength: 4)

            VStack(alignment: .trailing, spacing: 3) {
                content()
            }
        }
        .padding(.vertical, 10)
    }

    private var rowDivider: some View {
        Divider()
            .padding(.leading, 28)
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Recent activity", systemImage: "chart.xyaxis.line")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Last minute")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if preferences.showCPU {
                historyRow("Processor", color: .blue, value: \.cpuUsage, range: 0...100)
            }
            if preferences.showRAM {
                historyRow("Memory", color: .green, value: \.memoryUsage, range: 0...100)
            }
            if preferences.showNetwork {
                HStack {
                    Text("Network")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 66, alignment: .leading)
                    NetworkSparkline(samples: monitor.history)
                }
            }

            if !preferences.showCPU && !preferences.showRAM && !preferences.showNetwork {
                Text("Enable a processor, memory or network metric to graph its history.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(13)
        .background(.background.opacity(0.78), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.primary.opacity(0.055), lineWidth: 1)
        }
    }

    private func historyRow(
        _ title: String,
        color: Color,
        value: KeyPath<MetricHistorySample, Double?>,
        range: ClosedRange<Double>
    ) -> some View {
        HStack {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 66, alignment: .leading)
            MetricSparkline(
                samples: monitor.history,
                value: { $0[keyPath: value] },
                color: color,
                range: range
            )
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 9, weight: .medium))
            Text("Updated \(monitor.snapshot.timestamp, style: .time)")
                .font(.caption2)
                .monospacedDigit()
            Spacer()
            Button {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Label("Open Full App", systemImage: "macwindow")
                    .font(.caption2.weight(.medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
            .help("Open the full MacPulse window")
        }
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 17)
        .padding(.vertical, 9)
        .overlay(alignment: .top) {
            Divider().opacity(0.55)
        }
    }

    private var batterySymbol: String {
        monitor.snapshot.battery.isCharging == true ? "battery.100percent.bolt" : "battery.75percent"
    }

    private var batteryDetail: String {
        if let watts = monitor.snapshot.battery.adapterWatts {
            return "\(monitor.snapshot.battery.source) · adapter rated \(watts.formatted(.number.precision(.fractionLength(0)))) W"
        }
        if monitor.snapshot.battery.isCharging == true {
            return "\(monitor.snapshot.battery.source) · Charging"
        }
        return monitor.snapshot.battery.source
    }

    private func unavailableValue(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func formatPercent(_ value: Double) -> String {
        "\(Int(value.rounded()))%"
    }

    private func gigabytes(_ bytes: UInt64) -> String {
        String(format: "%.1f", Double(bytes) / 1_073_741_824)
    }
}

private struct CoreUsageView: View {
    let cores: [CoreUsage]

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 4)

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label("Individual logical cores", systemImage: "square.grid.2x2")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Per core")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if cores.isEmpty {
                Text("Individual core readings are unavailable.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 9) {
                    ForEach(cores) { core in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 2) {
                                Text("Core \(core.index + 1)")
                                    .foregroundStyle(.secondary)
                                Spacer(minLength: 0)
                                Text(core.cpuPercent.map { String(format: "%.0f%%", $0) } ?? "—")
                                    .foregroundStyle(.primary)
                                    .monospacedDigit()
                            }
                            .font(.system(size: 9, weight: .medium))

                            GeometryReader { geometry in
                                Capsule()
                                    .fill(.quaternary)
                                    .overlay(alignment: .leading) {
                                        Capsule()
                                            .fill(.blue)
                                            .frame(width: geometry.size.width * min(max((core.cpuPercent ?? 0) / 100, 0), 1))
                                    }
                            }
                            .frame(height: 3)
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 6)
                        .background(.background.opacity(0.72), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    }
                }
            }

            Text("System-wide processor load is shown above.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .background(.background.opacity(0.78), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.primary.opacity(0.055), lineWidth: 1)
        }
    }
}

private struct MetricSparkline: View {
    let samples: [MetricHistorySample]
    let value: (MetricHistorySample) -> Double?
    let color: Color
    let range: ClosedRange<Double>?

    private var plottedSamples: [MetricHistorySample] {
        samples.filter { value($0) != nil }
    }

    private var yDomain: ClosedRange<Double> {
        range ?? (0...max(plottedSamples.compactMap(value).max() ?? 1, 1))
    }

    var body: some View {
        if plottedSamples.count > 1,
           let firstDate = plottedSamples.first?.date,
           let lastDate = plottedSamples.last?.date,
           firstDate < lastDate {
            Chart(plottedSamples) { sample in
                if let measurement = value(sample) {
                    LineMark(
                        x: .value("Time", sample.date),
                        y: .value("Measurement", measurement)
                    )
                    .foregroundStyle(color)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                }
            }
            .chartXScale(domain: firstDate...lastDate)
            .chartYScale(domain: yDomain)
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartPlotStyle { plot in plot.clipped() }
            .frame(height: 31)
            .accessibilityLabel("Recent measured history")
        } else {
            Text("Collecting history…")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(height: 31, alignment: .center)
        }
    }
}

private struct NetworkSparkline: View {
    let samples: [MetricHistorySample]

    private var plottedSamples: [MetricHistorySample] {
        samples.filter { $0.downloadBytesPerSecond != nil || $0.uploadBytesPerSecond != nil }
    }

    var body: some View {
        if plottedSamples.count > 1 {
            Chart {
                ForEach(plottedSamples) { sample in
                    if let incoming = sample.downloadBytesPerSecond {
                        LineMark(
                            x: .value("Time", sample.date),
                            y: .value("Receive", incoming),
                            series: .value("Direction", "Receive")
                        )
                        .foregroundStyle(.blue)
                        .lineStyle(StrokeStyle(lineWidth: 1.3, lineCap: .round))
                    }
                    if let outgoing = sample.uploadBytesPerSecond {
                        LineMark(
                            x: .value("Time", sample.date),
                            y: .value("Send", outgoing),
                            series: .value("Direction", "Send")
                        )
                        .foregroundStyle(.orange)
                        .lineStyle(StrokeStyle(lineWidth: 1.3, lineCap: .round))
                    }
                }
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartPlotStyle { plot in plot.clipped() }
            .frame(height: 31)
            .accessibilityLabel("Recent measured network history")
        } else {
            Text("Collecting history…")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(height: 31, alignment: .center)
        }
    }
}
