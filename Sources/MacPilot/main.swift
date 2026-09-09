import SwiftUI
import AppKit
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

    private var timer: Timer?
    private var previousCPU = host_cpu_load_info_data_t()

    init() {
        refresh()
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

    func formatBytes(_ value: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .file)
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
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 6) { Text("Good evening.").font(.system(size: 32, weight: .bold, design: .rounded)); Text("Your Mac at a glance.").foregroundStyle(.secondary) }
            Spacer()
            HStack(spacing: 10) { Circle().fill(Color.mint).frame(width: 8, height: 8); Text("LIVE").font(.system(size: 11, weight: .bold, design: .monospaced)); Text(model.lastUpdated, style: .time).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary) }.padding(.horizontal, 13).padding(.vertical, 9).background(Color.panel).clipShape(Capsule())
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
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading).background(Color.panel).overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.06))).clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

@MainActor
struct WindowPanel: View {
    @Bindable var model: SystemModel
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PanelTitle(title: "Window manager", action: "Arrange all", icon: "square.grid.2x2")
            Text("A calm place for every window.").foregroundStyle(.secondary).font(.system(size: 13))
            VStack(spacing: 8) { WindowRow(name: "MacPilot", detail: "Dashboard", color: .mint, shortcut: "⌘ 1"); WindowRow(name: "Safari", detail: "Documentation", color: .sky, shortcut: "⌘ 2"); WindowRow(name: "Terminal", detail: "zsh", color: .amber, shortcut: "⌘ 3") }
            HStack { Image(systemName: "info.circle").foregroundStyle(.secondary); Text("Window control needs Accessibility permission.").font(.system(size: 11)).foregroundStyle(.secondary); Spacer(); Button("Open Settings") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!) }.buttonStyle(.borderless).foregroundStyle(Color.mint) }
        }.padding(22).frame(maxWidth: .infinity, alignment: .leading).background(Color.panel).clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

@MainActor
struct StoragePanel: View {
    let model: SystemModel
    @Binding var isCleaning: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PanelTitle(title: "Storage health", action: "Scan", icon: "externaldrive")
            HStack(alignment: .lastTextBaseline) { Text(model.formatBytes(model.diskUsed)).font(.system(size: 28, weight: .semibold, design: .rounded)); Text("used").foregroundStyle(.secondary); Spacer(); Text("\(Int(model.diskUsed / max(1, model.diskTotal) * 100))%").font(.system(size: 13, design: .monospaced)).foregroundStyle(Color.amber) }
            GeometryReader { proxy in ZStack(alignment: .leading) { Capsule().fill(Color.white.opacity(0.08)); Capsule().fill(LinearGradient(colors: [.amber, .coral], startPoint: .leading, endPoint: .trailing)).frame(width: proxy.size.width * min(1, model.diskUsed / max(1, model.diskTotal))) } }.frame(height: 9)
            HStack { StorageLegend(color: .amber, title: "System", value: "142 GB"); Spacer(); StorageLegend(color: .sky, title: "Documents", value: "86 GB"); Spacer(); StorageLegend(color: .secondary, title: "Free", value: model.formatBytes(model.diskFree)) }
            Button { isCleaning = true } label: { Label("Find space to reclaim", systemImage: "wand.and.stars") }.buttonStyle(.borderedProminent).tint(Color.mint).foregroundStyle(.black).frame(maxWidth: .infinity)
        }.padding(22).frame(width: 360, alignment: .leading).background(Color.panel).clipShape(RoundedRectangle(cornerRadius: 14)).sheet(isPresented: $isCleaning) { CleaningSheet() }
    }
}

struct CleaningSheet: View { @Environment(\.dismiss) private var dismiss; var body: some View { VStack(spacing: 18) { Image(systemName: "sparkles").font(.system(size: 34)).foregroundStyle(Color.mint); Text("Ready to scan").font(.title2.bold()); Text("MacPilot will look for caches, logs, and old installers. Nothing is removed without your review.").multilineTextAlignment(.center).foregroundStyle(.secondary); Button("Start scan") { dismiss() }.buttonStyle(.borderedProminent).tint(.mint).foregroundStyle(.black) }.padding(38).frame(width: 380) } }

struct PanelTitle: View { let title: String; let action: String; let icon: String; var body: some View { HStack { Label(title, systemImage: icon).font(.system(size: 15, weight: .semibold, design: .rounded)); Spacer(); Button(action) {}.buttonStyle(.borderless).foregroundStyle(Color.mint).font(.system(size: 12, weight: .medium)) } } }
struct WindowRow: View { let name: String; let detail: String; let color: Color; let shortcut: String; var body: some View { HStack { RoundedRectangle(cornerRadius: 5).fill(color).frame(width: 8, height: 28); VStack(alignment: .leading) { Text(name).font(.system(size: 13, weight: .medium)); Text(detail).font(.system(size: 11)).foregroundStyle(.secondary) }; Spacer(); Text(shortcut).font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary) }.padding(11).background(Color.white.opacity(0.035)).clipShape(RoundedRectangle(cornerRadius: 8)) } }
struct StorageLegend: View { let color: Color; let title: String; let value: String; var body: some View { VStack(alignment: .leading, spacing: 4) { HStack { Circle().fill(color).frame(width: 6, height: 6); Text(title).font(.system(size: 11)).foregroundStyle(.secondary) }; Text(value).font(.system(size: 12, design: .monospaced)) } } }
struct NavItem: View { let icon: String; let title: String; let selected: Bool; var body: some View { HStack(spacing: 12) { Image(systemName: icon).frame(width: 18); Text(title); Spacer() }.font(.system(size: 13, weight: selected ? .semibold : .regular)).foregroundStyle(selected ? .white : .secondary).padding(.vertical, 10).padding(.horizontal, 10).background(selected ? Color.white.opacity(0.08) : .clear).clipShape(RoundedRectangle(cornerRadius: 7)) } }

extension Text { func labelStyle() -> some View { self.font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(.tertiary).tracking(1.5).padding(.bottom, 8) } }
extension Color { static let canvas = Color(red: 0.055, green: 0.065, blue: 0.075); static let sidebar = Color(red: 0.075, green: 0.085, blue: 0.095); static let panel = Color(red: 0.105, green: 0.12, blue: 0.13); static let mint = Color(red: 0.39, green: 0.91, blue: 0.69); static let sky = Color(red: 0.42, green: 0.72, blue: 1); static let amber = Color(red: 1, green: 0.72, blue: 0.31); static let coral = Color(red: 1, green: 0.39, blue: 0.35) }
