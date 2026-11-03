import Foundation
import AppKit

struct Volume: Identifiable, Hashable, Sendable {
    let url: URL
    let name: String
    let total: Int64
    let free: Int64
    let isInternal: Bool

    var id: String { url.path }
    var isBoot: Bool { url.path == "/" }
    var used: Int64 { max(0, total - free) }
}

@MainActor
final class VolumesModel: ObservableObject {
    @Published var volumes: [Volume] = []
    @Published var selectedID: String = "/"
    /// Avisa si el disco de arranque baja de estos GB libres (0 = no avisar).
    @Published var alertGB: Int = UserDefaults.standard.object(forKey: "alertGB") as? Int ?? 10 {
        didSet { UserDefaults.standard.set(alertGB, forKey: "alertGB") }
    }

    var selected: Volume {
        volumes.first { $0.id == selectedID } ?? volumes.first
            ?? Volume(url: URL(fileURLWithPath: "/"), name: "Macintosh HD", total: 0, free: 0, isInternal: true)
    }

    init() {
        refresh()
        LowSpaceAlert.requestAuthorization()
        Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        let nc = NSWorkspace.shared.notificationCenter
        for n in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            nc.addObserver(forName: n, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        let keys: [URLResourceKey] = [
            .volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
            .volumeIsInternalKey, .volumeIsBrowsableKey,
        ]
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        var list: [Volume] = urls.compactMap { u in
            guard let v = try? u.resourceValues(forKeys: Set(keys)) else { return nil }
            let isBoot = u.path == "/"
            guard isBoot || (v.volumeIsBrowsable ?? false) else { return nil }
            let total = Int64(v.volumeTotalCapacity ?? 0)
            guard total > 0 else { return nil }
            return Volume(url: u, name: v.volumeName ?? u.lastPathComponent, total: total,
                          free: v.volumeAvailableCapacityForImportantUsage ?? 0,
                          isInternal: v.volumeIsInternal ?? isBoot)
        }
        list.sort { ($0.isBoot ? 0 : 1, $0.name) < ($1.isBoot ? 0 : 1, $1.name) }
        volumes = list
        if !list.contains(where: { $0.id == selectedID }) { selectedID = "/" }
        if let boot = list.first(where: \.isBoot) { LowSpaceAlert.check(boot, thresholdGB: alertGB) }
    }
}
