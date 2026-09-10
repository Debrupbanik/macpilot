#if os(macOS)
import SwiftUI
import AppKit
import ApplicationServices
import Darwin
import Observation

@main
@MainActor
struct MacPilotApp: App {
    @State private var model = SystemModel()

    var body: some Scene {
        WindowGroup("MacPilot") {
            DashboardView(model: model)
                .frame(minWidth: 1000, minHeight: 680)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) { }
        }

        MenuBarExtra {
            MenuBarWidget(model: model)
                .frame(width: 320)
                .preferredColorScheme(.dark)
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "waveform.path.ecg")
                Text("CPU \(Int(model.cpuUsage))%")
                Text("MEM \(Int(model.memoryUsed / max(1, model.memoryTotal) * 100))%")
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 11, weight: .medium, design: .monospaced))
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
struct MenuBarWidget: View {
    @Bindable var model: SystemModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("MACPILOT", systemImage: "waveform.path.ecg")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                Spacer()
                Circle()
                    .fill(Color.mint)
                    .frame(width: 7, height: 7)
                Text("LIVE")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                TopbarMetric(title: "CPU", value: "\(Int(model.cpuUsage))%", tint: .mint, progress: model.cpuUsage / 100)
                TopbarMetric(title: "MEM", value: "\(Int(model.memoryUsed / max(1, model.memoryTotal) * 100))%", tint: .sky, progress: model.memoryUsed / max(1, model.memoryTotal))
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Storage", systemImage: "externaldrive")
                    Spacer()
                    Text("\(Int(model.diskUsed / max(1, model.diskTotal) * 100))%")
                        .foregroundStyle(Color.amber)
                }
                ProgressView(value: model.diskUsed / max(1, model.diskTotal))
                    .tint(Color.amber)
                Text("\(model.formatBytes(model.diskFree)) free")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Divider()

            HStack(spacing: 10) {
                Button { NSApp.activate(ignoringOtherApps: true) } label: {
                    Label("Open dashboard", systemImage: "rectangle.inset.filled")
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.mint)
                .foregroundStyle(.black)

                Button { NSApplication.shared.terminate(nil) } label: {
                    Image(systemName: "power")
                }
                .buttonStyle(.borderless)
                .help("Quit MacPilot")
            }
        }
        .padding(18)
        .background(Color.canvas)
    }
}

struct TopbarMetric: View {
    let title: String
    let value: String
    let tint: Color
    let progress: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 22, weight: .semibold, design: .rounded))
            ProgressView(value: progress)
                .tint(tint)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.panel)
        .clipShape(RoundedRectangle(cornerRadius: 9))
    }
}

@MainActor
@Observable
final class SystemModel {
    var cpuUsage: Double = 0
    var memoryUsed: Double = 0
    var memoryTotal: Double = Double(ProcessInfo.processInfo.physicalMemory)
    var diskUsed: Double = 0
    var diskTotal: Double = 0
    var diskFree: Double = 0
    var lastUpdated = Date()
    var gpuState = "Public telemetry unavailable"
    var gpuDetail = "macOS does not expose GPU utilization through a public API"
    var spaces = ["Main", "Work", "Play", "Chat"]
    var selectedSpace = "Main"
    var scanResults: [CleanupCandidate] = []
    var isScanning = false
    var windows: [ManagedWindow] = []
    var windowMessage = "Loading windows..."

    private var timer: Timer?
    private var previousCPU = host_cpu_load_info_data_t()

    init() {
        refresh()
        refreshWindows()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
    }

    func refresh() {
        cpuUsage = readCPUUsage()
        let vm = ProcessInfo.processInfo.physicalMemory
        memoryTotal = Double(vm)
        let used = Double(vm) - Double(readFreeMemory())
        memoryUsed = max(0, min(used, memoryTotal))
        if let values = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory()),
           let total = values[.systemSize] as? NSNumber,
           let free = values[.systemFreeSize] as? NSNumber {
            diskTotal = total.doubleValue
            diskFree = free.doubleValue
            diskUsed = max(0, diskTotal - diskFree)
        }
        lastUpdated = Date()
    }

    func refreshWindows() {
        guard AXIsProcessTrusted() else {
            windows = []
            windowMessage = "Accessibility permission required"
            return
        }

        var discovered: [ManagedWindow] = []
        for application in NSWorkspace.shared.runningApplications where application.activationPolicy == .regular {
            guard application.processIdentifier != ProcessInfo.processInfo.processIdentifier,
                  let name = application.localizedName else { continue }
            let appElement = AXUIElementCreateApplication(application.processIdentifier)
            guard let windowElements = attributeValue(kAXWindowsAttribute, from: appElement) as? [AXUIElement] else { continue }

            for windowElement in windowElements {
                let title = (attributeValue(kAXTitleAttribute, from: windowElement) as? String) ?? "Untitled window"
                discovered.append(ManagedWindow(id: UUID(), appName: name, title: title, element: windowElement))
            }
        }

        windows = discovered
        windowMessage = discovered.isEmpty ? "No manageable windows found" : "\(discovered.count) windows detected"
    }

    func arrangeWindows() {
        refreshWindows()
        guard !windows.isEmpty else { return }
        guard let screen = NSScreen.main else { return }

        let frame = screen.visibleFrame.insetBy(dx: 24, dy: 24)
        let columns = max(1, Int(ceil(sqrt(Double(windows.count)))))
        let rows = Int(ceil(Double(windows.count) / Double(columns)))
        let cellWidth = frame.width / CGFloat(columns)
        let cellHeight = frame.height / CGFloat(rows)

        for (index, window) in windows.enumerated() {
            let column = index % columns
            let row = index / columns
            let target = CGRect(
                x: frame.minX + CGFloat(column) * cellWidth + 8,
                y: frame.maxY - CGFloat(row + 1) * cellHeight + 8,
                width: max(240, cellWidth - 16),
                height: max(180, cellHeight - 16)
            )
            setPosition(target.origin, on: window.element)
            setSize(target.size, on: window.element)
        }
        refreshWindows()
    }

    private func attributeValue(_ attribute: String, from element: AXUIElement) -> AnyObject? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as AnyObject?
    }

    private func setPosition(_ position: CGPoint, on element: AXUIElement) {
        var position = position
        guard let value = AXValueCreate(.cgPoint, &position) else { return }
        AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value)
    }

    private func setSize(_ size: CGSize, on element: AXUIElement) {
        var size = size
        guard let value = AXValueCreate(.cgSize, &size) else { return }
        AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value)
    }

    func formatBytes(_ value: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .file)
    }

    func scanForReclaimableSpace() {
        isScanning = true
        let fileManager = FileManager.default
        var results: [CleanupCandidate] = []
        let home = NSHomeDirectory()
        let locations = [
            ("Caches", "\(home)/Library/Caches"),
            ("Logs", "\(home)/Library/Logs")
        ]

        for (category, path) in locations {
            let size = folderSize(at: path, fileManager: fileManager)
            if size > 0 {
                results.append(CleanupCandidate(name: category, location: path, size: size, category: category))
            }
        }

        let downloads = "\(home)/Downloads"
        if let files = fileManager.enumerator(at: URL(fileURLWithPath: downloads), includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey], options: [.skipsHiddenFiles]) {
            for case let fileURL as URL in files {
                guard ["dmg", "pkg", "zip"].contains(fileURL.pathExtension.lowercased()),
                      let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]),
                      values.isRegularFile == true,
                      let modified = values.contentModificationDate,
                      Date().timeIntervalSince(modified) > 30 * 24 * 60 * 60,
                      let size = values.fileSize else { continue }
                results.append(CleanupCandidate(name: fileURL.lastPathComponent, location: fileURL.path, size: Double(size), category: "Old installers"))
            }
        }

        scanResults = results.sorted { $0.size > $1.size }
        isScanning = false
    }

    private func folderSize(at path: String, fileManager: FileManager) -> Double {
        guard let files = fileManager.enumerator(at: URL(fileURLWithPath: path), includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return 0 }
        var total = 0.0
        for case let fileURL as URL in files {
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), values.isRegularFile == true, let size = values.fileSize else { continue }
            total += Double(size)
        }
        return total
    }

    private func readFreeMemory() -> UInt64 {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        let pageSize = UInt64(getpagesize())
        return UInt64(stats.free_count + stats.inactive_count) * pageSize
    }

    private func readCPUUsage() -> Double {
        var load = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &load) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        let user = Double(load.cpu_ticks.0)
        let system = Double(load.cpu_ticks.1)
        let idle = Double(load.cpu_ticks.2)
        let nice = Double(load.cpu_ticks.3)
        let previous = Double(previousCPU.cpu_ticks.0 + previousCPU.cpu_ticks.1 + previousCPU.cpu_ticks.2 + previousCPU.cpu_ticks.3)
        let current = user + system + idle + nice
        let delta = max(1, current - previous)
        let active = (user + system + nice) - Double(previousCPU.cpu_ticks.0 + previousCPU.cpu_ticks.1 + previousCPU.cpu_ticks.3)
        previousCPU = load
        return max(0, min(100, active / delta * 100))
    }
}

@MainActor
struct DashboardView: View {
    @Bindable var model: SystemModel
    @State private var isCleaning = false
    @State private var showAllSpaces = false

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(model: model)
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    Header(model: model)
                    metricsGrid
                    HStack(alignment: .top, spacing: 18) {
                        WindowPanel(model: model)
                        StoragePanel(model: model, isCleaning: $isCleaning)
                    }
                }
                .padding(36)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color.canvas)
        }
        .background(Color.canvas)
    }

    private var metricsGrid: some View {
        HStack(spacing: 16) {
            MetricCard(title: "CPU LOAD", value: "\(Int(model.cpuUsage))%", caption: "All cores", icon: "cpu", tint: .mint, progress: model.cpuUsage / 100)
            MetricCard(title: "MEMORY", value: model.formatBytes(model.memoryUsed), caption: "of \(model.formatBytes(model.memoryTotal))", icon: "memorychip", tint: .sky, progress: model.memoryUsed / max(1, model.memoryTotal))
            MetricCard(title: "GPU LOAD", value: "--", caption: "Telemetry unavailable", icon: "rectangle.3.group", tint: .amber, progress: nil)
        }
    }
}

@MainActor
struct Sidebar: View {
    @Bindable var model: SystemModel
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                ZStack { RoundedRectangle(cornerRadius: 9).fill(Color.mint); Image(systemName: "waveform.path.ecg").foregroundStyle(.black).font(.system(size: 17, weight: .bold)) }.frame(width: 34, height: 34)
                Text("MACPILOT").font(.system(size: 15, weight: .bold, design: .rounded)).tracking(1.8)
            }.padding(.bottom, 42)
            Text("OVERVIEW").labelStyle()
            NavItem(icon: "chart.xyaxis.line", title: "Dashboard", selected: true)
            NavItem(icon: "rectangle.3.group", title: "Windows", selected: false)
            NavItem(icon: "externaldrive", title: "Storage", selected: false)
            Spacer()
            Text("SPACES").labelStyle()
            ForEach(model.spaces, id: \.self) { space in
                Button { model.selectedSpace = space } label: {
                    HStack { Circle().fill(model.selectedSpace == space ? Color.mint : Color.white.opacity(0.2)).frame(width: 6, height: 6); Text(space); Spacer(); if space == model.selectedSpace { Image(systemName: "checkmark").font(.caption2) } }.padding(.vertical, 9).foregroundStyle(model.selectedSpace == space ? .white : .secondary)
                }.buttonStyle(.plain)
            }
            Divider().padding(.vertical, 22)
            NavItem(icon: "gearshape", title: "Settings", selected: false)
            Text("v0.1.0 · Native macOS").font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary).padding(.top, 18)
        }.padding(28).frame(width: 220).background(Color.sidebar)
    }
}

@MainActor
struct Header: View {
    let model: SystemModel
    var body: some View {
        HStack(alignment: .bottom, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("SYSTEM OVERVIEW")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.mint)
                    .tracking(1.6)
                Text("Good evening.")
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                Text("Your Mac at a glance.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 12) {
                HStack(spacing: 8) {
                    Circle().fill(Color.mint).frame(width: 7, height: 7)
                    Text("LIVE").font(.system(size: 11, weight: .bold, design: .monospaced))
                    Text(model.lastUpdated, style: .time)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 13)
                .padding(.vertical, 10)
                .background(Color.panel)
                .clipShape(Capsule())

                Button { model.refresh() } label: {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.bordered)
                .tint(Color.mint)
                .help("Refresh system metrics")
            }
        }
    }
}

struct MetricCard: View {
    let title: String; let value: String; let caption: String; let icon: String; let tint: Color; let progress: Double?
    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            HStack { Image(systemName: icon).foregroundStyle(tint); Text(title).font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundStyle(.secondary); Spacer(); Image(systemName: "ellipsis").foregroundStyle(.tertiary) }
            Text(value).font(.system(size: 28, weight: .semibold, design: .rounded))
            HStack { Text(caption).font(.system(size: 12)).foregroundStyle(.secondary); Spacer(); if let progress { Text("\(Int(progress * 100))%").font(.system(size: 11, design: .monospaced)).foregroundStyle(tint) } }
            if let progress { ProgressView(value: progress).tint(tint).scaleEffect(x: 1, y: 0.7, anchor: .center) }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.panel)
        .overlay(alignment: .topTrailing) {
            Circle()
                .fill(tint.opacity(0.12))
                .frame(width: 90, height: 90)
                .blur(radius: 2)
                .offset(x: 28, y: -32)
        }
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.06)))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

@MainActor
struct WindowPanel: View {
    @Bindable var model: SystemModel
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PanelTitle(title: "Window manager", action: "Arrange all", icon: "square.grid.2x2") { model.arrangeWindows() }
            Text("A calm place for every window.").foregroundStyle(.secondary).font(.system(size: 13))
            VStack(spacing: 8) {
                if model.windows.isEmpty {
                    HStack(spacing: 10) {
                        Image(systemName: "macwindow.on.rectangle").foregroundStyle(Color.mint)
                        Text(model.windowMessage).font(.system(size: 12)).foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(14)
                    .background(Color.white.opacity(0.035))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    ForEach(model.windows) { window in
                        WindowRow(name: window.appName, detail: window.title, color: .mint, shortcut: "")
                    }
                }
            }
            HStack {
                Image(systemName: "info.circle").foregroundStyle(.secondary)
                Text(model.windowMessage).font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("Open Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Color.mint)
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, minHeight: 282, alignment: .topLeading)
        .background(Color.panel)
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.06)))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

@MainActor
struct StoragePanel: View {
    let model: SystemModel
    @Binding var isCleaning: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PanelTitle(title: "Storage health", action: "Scan", icon: "externaldrive") { isCleaning = true }
            HStack(alignment: .lastTextBaseline) { Text(model.formatBytes(model.diskUsed)).font(.system(size: 28, weight: .semibold, design: .rounded)); Text("used").foregroundStyle(.secondary); Spacer(); Text("\(Int(model.diskUsed / max(1, model.diskTotal) * 100))%").font(.system(size: 13, design: .monospaced)).foregroundStyle(Color.amber) }
            GeometryReader { proxy in ZStack(alignment: .leading) { Capsule().fill(Color.white.opacity(0.08)); Capsule().fill(LinearGradient(colors: [.amber, .coral], startPoint: .leading, endPoint: .trailing)).frame(width: proxy.size.width * min(1, model.diskUsed / max(1, model.diskTotal))) } }.frame(height: 9)
            HStack { StorageLegend(color: .amber, title: "System", value: "142 GB"); Spacer(); StorageLegend(color: .sky, title: "Documents", value: "86 GB"); Spacer(); StorageLegend(color: .secondary, title: "Free", value: model.formatBytes(model.diskFree)) }
            Button { isCleaning = true } label: { Label("Find space to reclaim", systemImage: "wand.and.stars") }.buttonStyle(.borderedProminent).tint(Color.mint).foregroundStyle(.black).frame(maxWidth: .infinity)
        }
        .padding(22)
        .frame(width: 360, alignment: .topLeading)
        .frame(minHeight: 282, alignment: .topLeading)
        .background(Color.panel)
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.06)))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .sheet(isPresented: $isCleaning) { CleaningSheet(model: model) }
    }
}

@MainActor
struct CleaningSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: SystemModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Image(systemName: model.isScanning ? "arrow.triangle.2.circlepath" : "sparkles")
                    .font(.system(size: 28))
                    .foregroundStyle(Color.mint)
                VStack(alignment: .leading) {
                    Text(model.scanResults.isEmpty ? "Find reclaimable space" : "Scan complete")
                        .font(.title3.bold())
                    Text("Read-only scan · nothing is removed")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            if model.scanResults.isEmpty && !model.isScanning {
                Text("MacPilot checks user caches, logs, and installer files older than 30 days.")
                    .foregroundStyle(.secondary)
            } else if model.isScanning {
                ProgressView("Scanning your home folder...")
            } else {
                let total = model.scanResults.reduce(0) { $0 + $1.size }
                Text("Found \(model.formatBytes(total)) that can be reviewed.")
                    .font(.system(size: 14, weight: .medium))
                ForEach(model.scanResults) { result in
                    HStack {
                        Image(systemName: result.category == "Old installers" ? "shippingbox" : "folder")
                            .foregroundStyle(Color.amber)
                        VStack(alignment: .leading) {
                            Text(result.name).font(.system(size: 13, weight: .medium))
                            Text(result.category).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(model.formatBytes(result.size)).font(.system(size: 11, design: .monospaced))
                        Button { NSWorkspace.shared.selectFile(result.location, inFileViewerRootedAtPath: "") } label: {
                            Image(systemName: "arrow.up.forward.square")
                        }.buttonStyle(.borderless).help("Reveal in Finder")
                    }
                }
            }

            HStack {
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                if !model.isScanning {
                    Button(model.scanResults.isEmpty ? "Start scan" : "Scan again") {
                        model.scanForReclaimableSpace()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.mint)
                    .foregroundStyle(.black)
                }
            }
        }
        .padding(28)
        .frame(width: 500)
    }
}

struct CleanupCandidate: Identifiable {
    let id = UUID()
    let name: String
    let location: String
    let size: Double
    let category: String
}

struct ManagedWindow: Identifiable {
    let id: UUID
    let appName: String
    let title: String
    let element: AXUIElement
}

struct PanelTitle: View { let title: String; let action: String; let icon: String; let onAction: () -> Void; init(title: String, action: String, icon: String, onAction: @escaping () -> Void = {}) { self.title = title; self.action = action; self.icon = icon; self.onAction = onAction }; var body: some View { HStack { Label(title, systemImage: icon).font(.system(size: 15, weight: .semibold, design: .rounded)); Spacer(); Button(action, action: onAction).buttonStyle(.borderless).foregroundStyle(Color.mint).font(.system(size: 12, weight: .medium)) } } }
struct WindowRow: View { let name: String; let detail: String; let color: Color; let shortcut: String; var body: some View { HStack { RoundedRectangle(cornerRadius: 5).fill(color).frame(width: 8, height: 28); VStack(alignment: .leading) { Text(name).font(.system(size: 13, weight: .medium)); Text(detail).font(.system(size: 11)).foregroundStyle(.secondary) }; Spacer(); Text(shortcut).font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary) }.padding(11).background(Color.white.opacity(0.035)).clipShape(RoundedRectangle(cornerRadius: 8)) } }
struct StorageLegend: View { let color: Color; let title: String; let value: String; var body: some View { VStack(alignment: .leading, spacing: 4) { HStack { Circle().fill(color).frame(width: 6, height: 6); Text(title).font(.system(size: 11)).foregroundStyle(.secondary) }; Text(value).font(.system(size: 12, design: .monospaced)) } } }
struct NavItem: View { let icon: String; let title: String; let selected: Bool; var body: some View { HStack(spacing: 12) { Image(systemName: icon).frame(width: 18); Text(title); Spacer() }.font(.system(size: 13, weight: selected ? .semibold : .regular)).foregroundStyle(selected ? .white : .secondary).padding(.vertical, 10).padding(.horizontal, 10).background(selected ? Color.white.opacity(0.08) : .clear).clipShape(RoundedRectangle(cornerRadius: 7)) } }

extension Text { func labelStyle() -> some View { self.font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(.tertiary).tracking(1.5).padding(.bottom, 8) } }
extension Color { static let canvas = Color(red: 0.055, green: 0.065, blue: 0.075); static let sidebar = Color(red: 0.075, green: 0.085, blue: 0.095); static let panel = Color(red: 0.105, green: 0.12, blue: 0.13); static let mint = Color(red: 0.39, green: 0.91, blue: 0.69); static let sky = Color(red: 0.42, green: 0.72, blue: 1); static let amber = Color(red: 1, green: 0.72, blue: 0.31); static let coral = Color(red: 1, green: 0.39, blue: 0.35) }

#else

import Foundation

@main
struct MacPilotLinux {
    static func main() {
        print("MacPilot Linux")
        print(String(repeating: "-", count: 42))
        print("CPU load:  \(readLoad())")
        print("Memory:    \(readMemory())")
        print("Disk:      \(readDisk())")
        print("")
        print("Window management")
        print("Linux window arrangement depends on your desktop session.")
        print("Use your desktop's tiling features on Wayland, or install wmctrl for X11.")
        print("")
        print("Run again with: swift run MacPilot")
    }

    private static func readLoad() -> String {
        guard let contents = try? String(contentsOfFile: "/proc/loadavg", encoding: .utf8) else {
            return "Unavailable"
        }
        return contents.split(separator: " ").first.map(String.init) ?? "Unavailable"
    }

    private static func readMemory() -> String {
        guard let contents = try? String(contentsOfFile: "/proc/meminfo", encoding: .utf8) else {
            return "Unavailable"
        }
        let values = contents.split(separator: "\n").reduce(into: [String: Int64]()) { result, line in
            let parts = line.split(whereSeparator: { $0 == " " || $0 == ":" }).filter { !$0.isEmpty }
            if parts.count >= 2, let value = Int64(parts[1]) {
                result[String(parts[0])] = value
            }
        }
        guard let total = values["MemTotal"], let available = values["MemAvailable"] else {
            return "Unavailable"
        }
        let used = total - available
        return "\(formatMegabytes(used)) used / \(formatMegabytes(total)) total"
    }

    private static func readDisk() -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/df")
        process.arguments = ["-h", "/"]
        process.standardOutput = output
        guard (try? process.run()) != nil else { return "Unavailable" }
        process.waitUntilExit()
        let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let line = text.split(separator: "\n").last.map(String.init) ?? ""
        let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard fields.count >= 5 else { return "Unavailable" }
        return "\(fields[2]) used / \(fields[1]) total (\(fields[4]) free)"
    }

    private static func formatMegabytes(_ kibibytes: Int64) -> String {
        let megabytes = Double(kibibytes) / 1024
        return String(format: "%.0f MB", megabytes)
    }
}

#endif
