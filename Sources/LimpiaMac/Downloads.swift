import Foundation
import AppKit

// MARK: - Instaladores y descargas

struct Installer: Identifiable, Sendable {
    let url: URL
    let size: Int64
    let modified: Date?
    let kind: String
    var id: URL { url }
}

private func installerKind(_ name: String) -> String? {
    let n = name.lowercased()
    if n.hasSuffix(".tar.gz") { return "Comprimido" }
    switch (n as NSString).pathExtension {
    case "dmg": return "Imagen de disco"
    case "pkg", "mpkg": return "Instalador"
    case "iso": return "Imagen ISO"
    case "xip": return "Archivo .xip"
    case "zip", "rar", "7z", "tgz": return "Comprimido"
    default: return nil
    }
}

func findInstallers(root: URL) -> [Installer] {
    let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
    guard let en = FileManager.default.enumerator(
        at: root, includingPropertiesForKeys: keys,
        options: [.skipsPackageDescendants, .skipsHiddenFiles], errorHandler: { _, _ in true }
    ) else { return [] }
    var out: [Installer] = []
    for case let u as URL in en {
        if Task.isCancelled { break }
        guard let kind = installerKind(u.lastPathComponent),
              let v = try? u.resourceValues(forKeys: Set(keys)), v.isRegularFile == true
        else { continue }
        out.append(Installer(url: u, size: Int64(v.fileSize ?? 0), modified: v.contentModificationDate, kind: kind))
    }
    return out.sorted { $0.size > $1.size }
}

// MARK: - Copias de seguridad de iPhone / iPad

struct DeviceBackup: Identifiable, Sendable {
    let url: URL
    let name: String
    let model: String?
    let version: String?
    let lastBackup: Date?
    var id: URL { url }
}

let mobileSyncBackupDir = CleanTarget.home.appendingPathComponent("Library/Application Support/MobileSync/Backup")

/// (copias, sinAcceso). `sinAcceso` = existe pero macOS no deja listarla.
func readDeviceBackups() -> (items: [DeviceBackup], denied: Bool) {
    let fm = FileManager.default
    guard fm.fileExists(atPath: mobileSyncBackupDir.path) else { return ([], false) }
    guard let dirs = try? fm.contentsOfDirectory(at: mobileSyncBackupDir, includingPropertiesForKeys: nil,
                                                 options: [.skipsHiddenFiles])
    else { return ([], true) }
    let items = dirs.compactMap { d -> DeviceBackup? in
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: d.path, isDirectory: &isDir), isDir.boolValue else { return nil }
        let info = NSDictionary(contentsOf: d.appendingPathComponent("Info.plist"))
        return DeviceBackup(
            url: d,
            name: (info?["Device Name"] as? String) ?? d.lastPathComponent,
            model: info?["Product Type"] as? String,
            version: info?["Product Version"] as? String,
            lastBackup: info?["Last Backup Date"] as? Date)
    }
    return (items, false)
}

@MainActor
final class DownloadsModel: ObservableObject {
    @Published var installers: [Installer] = []
    @Published var backups: [DeviceBackup] = []
    @Published var sizes: [URL: Int64] = [:]
    @Published var selected: Set<URL> = []
    @Published var backupsDenied = false
    @Published var scanning = false
    @Published var hasScanned = false
    @Published var message: String?
    @Published var minAgeDays = 0

    static let staleDays = 30
    private var task: Task<Void, Never>?

    var shownInstallers: [Installer] {
        guard minAgeDays > 0 else { return installers }
        let cutoff = Calendar.current.date(byAdding: .day, value: -minAgeDays, to: Date()) ?? .distantPast
        return installers.filter { ($0.modified ?? .distantFuture) < cutoff }
    }

    var selectedBytes: Int64 {
        let ins = installers.filter { selected.contains($0.url) }.reduce(0) { $0 + $1.size }
        let bak = backups.filter { selected.contains($0.url) }.reduce(0) { $0 + (sizes[$1.url] ?? 0) }
        return ins + bak
    }
    var selectionHasBackups: Bool { backups.contains { selected.contains($0.url) } }

    func scan(downloads root: URL) {
        task?.cancel()
        scanning = true
        installers = []; backups = []; sizes = [:]; selected = []
        task = Task {
            async let ins = Task.detached { findInstallers(root: root) }.value
            async let bak = Task.detached { readDeviceBackups() }.value
            let (i, b) = await (ins, bak)
            guard !Task.isCancelled else { return }
            installers = i
            backups = b.items
            backupsDenied = b.denied
            let cutoff = Calendar.current.date(byAdding: .day, value: -Self.staleDays, to: Date()) ?? .distantPast
            selected = Set(i.filter { ($0.modified ?? .distantFuture) < cutoff }.map(\.url))
            hasScanned = true
            await withTaskGroup(of: (URL, Int64).self) { group in
                for d in b.items { group.addTask { (d.url, allocatedSize(of: d.url)) } }
                for await (u, s) in group { sizes[u] = s }
            }
            scanning = false
        }
    }

    func trashSelected() {
        let urls = installers.filter { selected.contains($0.url) }.map(\.url)
            + backups.filter { selected.contains($0.url) }.map(\.url)
        let bytes = selectedBytes
        let r = trashURLs(urls)
        installers.removeAll { !FileManager.default.fileExists(atPath: $0.url.path) }
        backups.removeAll { !FileManager.default.fileExists(atPath: $0.url.path) }
        selected = []
        message = "Movidos \(r.moved) elementos a la Papelera (~\(formatBytes(bytes)))."
            + (r.failed > 0 ? " \(r.failed) fallaron." : "") + " Vacía la Papelera para liberar el espacio."
    }
}
