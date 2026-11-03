import Foundation
import SwiftUI
import AppKit

struct CleanTarget: Identifiable, Sendable {
    enum Action: Sendable {
        /// Borra el CONTENIDO de estas carpetas (la carpeta queda).
        case emptyFolders([URL])
        /// `xcrun simctl delete unavailable`
        case simctlUnavailable
        /// Borra .DS_Store, ._* (AppleDouble) y .TemporaryItems de un disco.
        case junkFiles(root: URL)
    }

    let id: String
    let name: String
    let detail: String
    let icon: String
    let defaultOn: Bool
    let action: Action

    var urls: [URL] {
        if case .emptyFolders(let u) = action { return u }
        return []
    }

    static let home = FileManager.default.homeDirectoryForCurrentUser
    private static func h(_ p: String) -> URL { home.appendingPathComponent(p) }

    /// Categorías para un disco que no es el de arranque.
    static func volumeTargets(_ v: Volume) -> [CleanTarget] {
        let trash = v.url.appendingPathComponent(".Trashes/\(getuid())")
        return [
            .init(id: "junk", name: "Archivos basura de macOS",
                  detail: ".DS_Store, ._* y .TemporaryItems · metadatos que macOS regenera",
                  icon: "doc.badge.gearshape", defaultOn: true, action: .junkFiles(root: v.url)),
            .init(id: "trash", name: "Papelera de este disco",
                  detail: ".Trashes · se borra de forma permanente",
                  icon: "trash", defaultOn: false, action: .emptyFolders([trash])),
        ]
    }

    static let all: [CleanTarget] = [
        .init(id: "caches", name: "Cachés de aplicaciones",
              detail: "~/Library/Caches · las apps los regeneran solas",
              icon: "internaldrive", defaultOn: true,
              action: .emptyFolders([h("Library/Caches")])),
        .init(id: "logs", name: "Logs e informes de errores",
              detail: "~/Library/Logs · incluye DiagnosticReports",
              icon: "doc.text", defaultOn: true,
              action: .emptyFolders([h("Library/Logs")])),
        .init(id: "derived", name: "Xcode DerivedData",
              detail: "Builds intermedios · se recompilan al abrir el proyecto",
              icon: "hammer", defaultOn: true,
              action: .emptyFolders([h("Library/Developer/Xcode/DerivedData")])),
        .init(id: "devicesupport", name: "Xcode iOS DeviceSupport",
              detail: "Símbolos de dispositivos · se vuelven a bajar al conectar el iPhone",
              icon: "iphone", defaultOn: true,
              action: .emptyFolders([h("Library/Developer/Xcode/iOS DeviceSupport"),
                                     h("Library/Developer/Xcode/watchOS DeviceSupport")])),
        .init(id: "simctl", name: "Simuladores obsoletos",
              detail: "simctl delete unavailable · runtimes que ya no sirven",
              icon: "ipad.and.iphone", defaultOn: true,
              action: .simctlUnavailable),
        .init(id: "devcaches", name: "Cachés de desarrollo",
              detail: "npm, Gradle, Yarn · se re-descargan cuando hace falta",
              icon: "shippingbox", defaultOn: true,
              action: .emptyFolders([h(".npm/_cacache"), h(".gradle/caches"), h(".cache")])),
        .init(id: "trash", name: "Papelera",
              detail: "Se borra de forma permanente",
              icon: "trash", defaultOn: false,
              action: .emptyFolders([h(".Trash")])),
    ]
}

/// Borra el contenido de una carpeta. Devuelve cuántos elementos fallaron.
@discardableResult
func emptyFolder(_ dir: URL) -> Int {
    let fm = FileManager.default
    guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: []) else { return 0 }
    var failed = 0
    for item in items {
        do { try fm.removeItem(at: item) } catch { failed += 1 }
    }
    return failed
}

/// true si la carpeta existe pero macOS no deja listarla (falta Acceso total al disco).
func isUnreadable(_ dir: URL) -> Bool {
    guard FileManager.default.fileExists(atPath: dir.path) else { return false }
    return (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) == nil
}

/// Sondea una carpeta protegida por TCC: si se puede listar, hay Acceso total al disco.
func checkFullDiskAccess() -> Bool {
    let probe = CleanTarget.home.appendingPathComponent("Library/Safari").path
    guard FileManager.default.fileExists(atPath: probe) else { return true }
    return (try? FileManager.default.contentsOfDirectory(atPath: probe)) != nil
}

func relaunchApp() {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    p.arguments = ["-n", Bundle.main.bundlePath]
    try? p.run()
    NSApplication.shared.terminate(nil)
}

private let appleDoubleMagic: [UInt8] = [0x00, 0x05, 0x16, 0x07]

private func isAppleDouble(_ url: URL) -> Bool {
    guard let h = try? FileHandle(forReadingFrom: url) else { return false }
    defer { try? h.close() }
    return Array((try? h.read(upToCount: 4)) ?? Data()) == appleDoubleMagic
}

/// Archivos basura de macOS dentro de un disco. No toca Time Machine ni índices del sistema.
func junkFiles(in root: URL) -> [URL] {
    let fm = FileManager.default
    if fm.fileExists(atPath: root.appendingPathComponent("Backups.backupdb").path) { return [] }
    guard let en = fm.enumerator(at: root, includingPropertiesForKeys: nil, options: [],
                                 errorHandler: { _, _ in true }) else { return [] }
    let skip: Set<String> = [".Spotlight-V100", ".fseventsd", ".Trashes", ".DocumentRevisions-V100"]
    var out: [URL] = []
    var i = 0
    for case let u as URL in en {
        i += 1
        if i & 511 == 0 && Task.isCancelled { break }
        let n = u.lastPathComponent
        if skip.contains(n) { en.skipDescendants(); continue }
        if n == ".TemporaryItems" { out.append(u); en.skipDescendants() }
        else if n == ".DS_Store" { out.append(u) }
        else if n.hasPrefix("._"), isAppleDouble(u) { out.append(u) }
    }
    return out
}

func runSimctlDeleteUnavailable() {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    p.arguments = ["simctl", "delete", "unavailable"]
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try? p.run()
    p.waitUntilExit()
}

@MainActor
final class CleanerModel: ObservableObject {
    @Published var sizes: [String: Int64] = [:]
    @Published var noAccess: Set<String> = []
    @Published var hasFullDiskAccess = true
    @Published var selected: Set<String> = Set(CleanTarget.all.filter(\.defaultOn).map(\.id))
    @Published var scanning = false
    @Published var cleaning = false
    @Published var message: String?
    @Published var diskTotal: Int64 = 0
    @Published var diskFree: Int64 = 0

    @Published var targets = CleanTarget.all
    @Published var volume: Volume?

    var isBoot: Bool { volume?.isBoot ?? true }
    var volumeName: String { volume?.name ?? "Disco" }

    func setVolume(_ v: Volume) async {
        volume = v
        targets = v.isBoot ? CleanTarget.all : CleanTarget.volumeTargets(v)
        selected = Set(targets.filter(\.defaultOn).map(\.id))
        sizes = [:]
        noAccess = []
        message = nil
        await scan()
    }

    var selectedBytes: Int64 {
        selected.reduce(0) { $0 + (sizes[$1] ?? 0) }
    }

    func refreshDisk() {
        let v = try? (volume?.url ?? CleanTarget.home).resourceValues(forKeys: [
            .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
        diskTotal = Int64(v?.volumeTotalCapacity ?? 0)
        diskFree = v?.volumeAvailableCapacityForImportantUsage ?? 0
    }

    func scan() async {
        scanning = true
        refreshDisk()
        hasFullDiskAccess = checkFullDiskAccess()
        let ts = targets
        await withTaskGroup(of: (String, Int64?, Bool).self) { group in
            for t in ts {
                group.addTask {
                    if case .junkFiles(let root) = t.action {
                        return (t.id, junkFiles(in: root).reduce(Int64(0)) { $0 + allocatedSize(of: $1) }, false)
                    }
                    guard case .emptyFolders(let urls) = t.action else { return (t.id, nil, false) }
                    let denied = urls.contains { isUnreadable($0) }
                    return (t.id, urls.reduce(Int64(0)) { $0 + allocatedSize(of: $1) }, denied)
                }
            }
            for await (id, size, denied) in group {
                if let size { sizes[id] = size }
                if denied { noAccess.insert(id) } else { noAccess.remove(id) }
            }
        }
        scanning = false
    }

    func clean() async {
        let chosen = targets.filter { selected.contains($0.id) }
        let before = selectedBytes
        cleaning = true
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
        cleaning = false
        await scan()
        let freed = max(0, before - selectedBytes)
        message = "Listo. Se liberaron ~\(formatBytes(freed))."
    }
}
