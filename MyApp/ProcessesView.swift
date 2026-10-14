import AppKit
import SwiftUI

struct ProcessesView: View {
    let processes: [ProcessUsage]
    let inaccessibleProcessCount: Int
    let samplingStatus: ProcessSamplingStatus
    let samplingDiagnostics: ProcessSamplingDiagnostics?
    let retrySampling: () -> Void
    var requestedSelectionID: String? = nil

    @AppStorage("com.macpulse.processSortColumn") private var storedSortColumn = ProcessSortColumn.cpu.rawValue
    @AppStorage("com.macpulse.processSortDirection") private var storedSortDirection = "descending"
    @State private var searchText = ""
    @State private var showingMyApplications = false
    @State private var selectedProcessID: String?
    @State private var selectedProcess: ProcessUsage?
    @State private var applicationIcons: [Int32: NSImage] = [:]
    @State private var applicationPaths: [Int32: String] = [:]
    @State private var runningApplicationPIDs: Set<Int32> = []

    private var sortState: ProcessSortState {
        ProcessSortState(
            column: ProcessSortColumn(rawValue: storedSortColumn) ?? .cpu,
            direction: storedSortDirection == "ascending" ? .ascending : .descending
        )
    }

    private var applicationPIDs: Set<Int32> {
        runningApplicationPIDs
    }

    private var visibleProcesses: [ProcessUsage] {
        ProcessListCalculator.filteredAndSorted(
            processes,
            searchText: searchText,
            filter: showingMyApplications ? .myApplications : .all,
            applicationPIDs: applicationPIDs,
            sort: sortState
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            controls
            columnHeaders

            if processes.isEmpty, samplingStatus == .loading {
                VStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Collecting process samples…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 150)
            } else if processes.isEmpty, case let .failed(message) = samplingStatus {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Text("Couldn’t collect process data")
                        .font(.system(size: 13, weight: .medium))
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Retry", action: retrySampling)
                        .controlSize(.small)
                }
                .frame(maxWidth: .infinity, minHeight: 150)
            } else if visibleProcesses.isEmpty {
                VStack(spacing: 7) {
                    Image(systemName: searchText.isEmpty ? "app.dashed" : "magnifyingglass")
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                    Text(searchText.isEmpty ? "No Processes" : "No Matching Processes")
                        .font(.system(size: 13, weight: .medium))
                    Text(searchText.isEmpty
                        ? "No readable running processes were found."
                        : "Try another process name.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 150)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(visibleProcesses) { process in
                            processRow(process)
                            if process.id != visibleProcesses.last?.id {
                                Divider().padding(.leading, 42)
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                }
                .frame(maxHeight: 390)
            }

            HStack(alignment: .top, spacing: 5) {
                Image(systemName: "info.circle")
                Text("CPU is per logical core and may exceed 100%. Memory is resident size. Per-process disk/network rates are unavailable from the current source.")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)

            if let samplingDiagnostics {
                Text(samplingDiagnostics.summary)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 7)
            }

            if inaccessibleProcessCount > 0 {
                Text("\(inaccessibleProcessCount) processes could not be read; macOS may restrict access to protected processes.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 9)
            }
        }
        .onAppear(perform: refreshApplicationIcons)
        .onReceive(NotificationCenter.default.publisher(for: NSWorkspace.didLaunchApplicationNotification)) { _ in
            refreshApplicationIcons()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWorkspace.didTerminateApplicationNotification)) { _ in
            refreshApplicationIcons()
        }
        .task(id: requestedSelectionID) { selectRequestedProcess() }
        .task(id: processes) { selectRequestedProcess() }
        .sheet(item: $selectedProcess) { process in
            ProcessDetailsView(
                process: process,
                applicationPath: applicationPaths[process.pid]
            )
        }
    }

    private var controls: some View {
        VStack(spacing: 9) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search processes", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(.quaternary.opacity(0.65), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            Picker("Process filter", selection: $showingMyApplications) {
                Text("All Processes").tag(false)
                Text("My Applications").tag(true)
            }
            .pickerStyle(.segmented)
            .controlSize(.small)
            .help("My Applications includes running GUI applications macOS exposes through NSWorkspace.")
        }
        .padding(.horizontal, 14)
        .padding(.top, 4)
        .padding(.bottom, 8)
    }

    private var columnHeaders: some View {
        HStack(spacing: 6) {
            sortButton("PROCESS", column: .name)
                .frame(maxWidth: .infinity, alignment: .leading)
            sortButton("CPU", column: .cpu)
                .frame(width: 52, alignment: .trailing)
            sortButton("MEMORY", column: .memory)
                .frame(width: 68, alignment: .trailing)
            sortButton("PID", column: .pid)
                .frame(width: 44, alignment: .trailing)
        }
        .font(.system(size: 9, weight: .semibold))
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.35))
        .overlay(alignment: .bottom) { Divider() }
    }

    private func sortButton(_ title: String, column: ProcessSortColumn) -> some View {
        Button {
            var updated = sortState
            updated.select(column)
            storedSortColumn = updated.column.rawValue
            storedSortDirection = updated.direction == .ascending ? "ascending" : "descending"
        } label: {
            HStack(spacing: 3) {
                Text(title)
                if sortState.column == column {
                    Image(systemName: sortState.direction == .ascending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 7, weight: .bold))
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Sort by \(title.lowercased()), toggle direction")
    }

    private func processRow(_ process: ProcessUsage) -> some View {
        Button {
            selectedProcessID = process.id
            selectedProcess = process
        } label: {
            HStack(spacing: 7) {
                processIcon(for: process)
                    .frame(width: 25, height: 25)

                VStack(alignment: .leading, spacing: 2) {
                    Text(process.name)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Text(process.cpuPercent.map { String(format: "%.1f%%", $0) } ?? "—")
                    .font(.system(size: 11, weight: .medium, design: .rounded).monospacedDigit())
                    .foregroundStyle(process.cpuPercent.map { $0 >= 80 ? Color.orange : Color.primary } ?? Color.secondary)
                    .frame(width: 52, alignment: .trailing)

                Text(process.memoryBytes.map(DiskFormatter.formatBytes) ?? "—")
                    .font(.system(size: 10, weight: .regular, design: .rounded).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 68, alignment: .trailing)

                Text(String(process.pid))
                    .font(.system(size: 10, design: .monospaced).monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .frame(width: 44, alignment: .trailing)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .background {
                if process.id == selectedProcessID {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.accentColor.opacity(0.13))
                }
            }
        }
        .buttonStyle(.plain)
        .help("\(process.name) (PID \(process.pid))")
    }

    @ViewBuilder
    private func processIcon(for process: ProcessUsage) -> some View {
        if let icon = applicationIcons[process.pid] {
            Image(nsImage: icon)
                .resizable()
                .scaledToFit()
                .padding(1)
        } else {
            Image(systemName: "gearshape.2")
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func refreshApplicationIcons() {
        let applications = NSWorkspace.shared.runningApplications
        var icons: [Int32: NSImage] = [:]
        var paths: [Int32: String] = [:]
        var pids: Set<Int32> = []
        for application in applications {
            guard application.activationPolicy == .regular,
                  application.bundleURL?.pathExtension == "app" else {
                continue
            }
            pids.insert(application.processIdentifier)
            if let path = application.bundleURL?.path {
                paths[application.processIdentifier] = path
            }
            if let icon = application.icon {
                icons[application.processIdentifier] = icon
            }
        }
        applicationIcons = icons
        applicationPaths = paths
        runningApplicationPIDs = pids
    }

    private func selectRequestedProcess() {
        guard let requestedSelectionID,
              selectedProcessID != requestedSelectionID,
              let process = processes.first(where: { $0.id == requestedSelectionID }) else {
            return
        }
        selectedProcessID = requestedSelectionID
        selectedProcess = process
    }
}

private struct ProcessDetailsView: View {
    let process: ProcessUsage
    let applicationPath: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(process.name, systemImage: "gearshape.2")
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .lineLimit(1)

            LabeledContent("PID", value: String(process.pid))
            LabeledContent("Parent PID", value: process.parentPID.map(String.init) ?? "Unavailable")
            LabeledContent("Threads", value: process.threadCount.map(String.init) ?? "Unavailable")
            LabeledContent("User ID", value: process.userID.map(String.init) ?? "Unavailable")
            LabeledContent("State", value: process.state ?? "Unavailable")
            LabeledContent("CPU", value: process.cpuPercent.map { String(format: "%.1f%%", $0) } ?? "—")
            LabeledContent("Memory", value: process.memoryBytes.map(DiskFormatter.formatBytes) ?? "Unavailable")
            LabeledContent("Uptime", value: process.uptime.map { ByteFormatter.formatDuration($0) } ?? "Unavailable")

            if let applicationPath {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Application")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text(applicationPath)
                        .font(.caption)
                        .textSelection(.enabled)
                        .lineLimit(3)
                }
            } else if let executablePath = process.executablePath {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Executable")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text(executablePath)
                        .font(.caption)
                        .textSelection(.enabled)
                        .lineLimit(3)
                }
            } else {
                Text("Executable path unavailable")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("CPU is the process's accumulated CPU time delta divided by elapsed wall time and may exceed 100% when multiple cores are used.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 360, alignment: .leading)
    }
}
