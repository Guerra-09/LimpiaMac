import Foundation
import AppKit
import Darwin
import UserNotifications

enum Notifier {
    static func send(title: String, body: String) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }
}

/// Ejecuta las acciones de limpieza fuera del hilo principal.
func performClean(_ chosen: [CleanTarget]) async {
    await Task.detached {
        for t in chosen {
            switch t.action {
            case .emptyFolders(let urls): urls.forEach { emptyFolder($0) }
            case .simctlUnavailable: runSimctlDeleteUnavailable()
            case .junkFiles(let root):
                for u in junkFiles(in: root) { try? FileManager.default.removeItem(at: u) }
            }
        }
    }.value
}

// MARK: - Limpieza programada

@MainActor
final class ScheduleModel: ObservableObject {
    @Published var enabled: Bool { didSet { save(); if enabled && lastRun == nil { lastRun = Date() } } }
    @Published var intervalDays: Int { didSet { save() } }
    @Published var ids: Set<String> { didSet { save() } }
    @Published var lastRun: Date? { didSet { save() } }
    @Published var lastResult: String?
    @Published var running = false

    private let d = UserDefaults.standard

    init() {
        enabled = d.bool(forKey: "sch.enabled")
        intervalDays = d.object(forKey: "sch.days") as? Int ?? 7
        lastRun = d.object(forKey: "sch.last") as? Date
        if let saved = d.stringArray(forKey: "sch.ids") {
            ids = Set(saved)
        } else {
            ids = Set(CleanTarget.all.filter { $0.defaultOn && $0.id != "trash" }.map(\.id))
        }
        Timer.scheduledTimer(withTimeInterval: 1800, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        Task { try? await Task.sleep(nanoseconds: 30_000_000_000); tick() }
    }

    private func save() {
        d.set(enabled, forKey: "sch.enabled")
        d.set(intervalDays, forKey: "sch.days")
        d.set(lastRun, forKey: "sch.last")
        d.set(Array(ids), forKey: "sch.ids")
    }

    var nextRun: Date? {
        guard enabled, let lastRun else { return nil }
        return Calendar.current.date(byAdding: .day, value: intervalDays, to: lastRun)
    }

    private func tick() {
        guard enabled, !running, let next = nextRun, next <= Date() else { return }
        Task { await run(auto: true) }
    }

    func run(auto: Bool) async {
        guard !running else { return }
        running = true
        var chosen = CleanTarget.all.filter { ids.contains($0.id) }
        // No toca los builds si Xcode está abierto.
        if auto, !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dt.Xcode").isEmpty {
            chosen.removeAll { $0.id == "derived" || $0.id == "devicesupport" }
        }
        let before = await Task.detached {
            chosen.reduce(Int64(0)) { acc, t in acc + t.urls.reduce(0) { $0 + allocatedSize(of: $1) } }
        }.value
        await performClean(chosen)
        lastRun = Date()
        lastResult = "Se liberaron ~\(formatBytes(before))."
        if auto { Notifier.send(title: "Limpieza automática", body: lastResult ?? "") }
        running = false
    }
}

// MARK: - Memoria

struct MemApp: Identifiable, Sendable {
    let id: String
    let name: String
    let path: String?
    let bytes: Int64
    var canQuit: Bool
}

private let protectedBundles: Set<String> = [
    "com.apple.finder", "com.apple.dock", "com.apple.systemuiserver", "com.apple.loginwindow",
]

@MainActor
final class MemoryModel: ObservableObject {
    @Published var used: Int64 = 0
    @Published var total: Int64 = Int64(ProcessInfo.processInfo.physicalMemory)
    @Published var apps: [MemApp] = []

    private var timer: Timer?
    private var viewers = 0

    func start() {
        viewers += 1
        guard timer == nil else { return }
        Task { await refresh() }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    func stop() {
        viewers = max(0, viewers - 1)
        if viewers == 0 { timer?.invalidate(); timer = nil }
    }

    private static func usedMemory() -> Int64 {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let r = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard r == KERN_SUCCESS else { return 0 }
        let page = Int64(sysconf(_SC_PAGESIZE))
        return (Int64(stats.active_count) + Int64(stats.wire_count) + Int64(stats.compressor_page_count)) * page
    }

    func refresh() async {
        used = Self.usedMemory()
        let r = await runProcess("/bin/ps", ["-axo", "pid=,rss=,comm="])
        var groups: [String: (bytes: Int64, path: String?)] = [:]
        for line in r.output.split(separator: "\n") {
            let p = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard p.count == 3, let kb = Int64(p[1]) else { continue }
            let comm = String(p[2])
            if let range = comm.range(of: ".app/") {
                let bundle = String(comm[..<range.lowerBound]) + ".app"
                groups[bundle, default: (0, bundle)].bytes += kb * 1024
            } else {
                let key = (comm as NSString).lastPathComponent
                groups[key, default: (0, nil)].bytes += kb * 1024
            }
        }
        let running = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        let me = Bundle.main.bundleIdentifier
        apps = groups.map { key, v in
            let name = v.path.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent } ?? key
            var can = false
            if let path = v.path,
               let app = running.first(where: { $0.bundleURL?.path == path }),
               let bid = app.bundleIdentifier {
                can = !protectedBundles.contains(bid) && bid != me
            }
            return MemApp(id: key, name: name, path: v.path, bytes: v.bytes, canQuit: can)
        }
        .sorted { $0.bytes > $1.bytes }
        .prefix(12).map { $0 }
    }

    func quit(_ app: MemApp, force: Bool = false) {
        guard let path = app.path,
              let r = NSWorkspace.shared.runningApplications.first(where: { $0.bundleURL?.path == path })
        else { return }
        if force { r.forceTerminate() } else { r.terminate() }
        Task { try? await Task.sleep(nanoseconds: 1_500_000_000); await refresh() }
    }
}
