import Foundation
import AppKit
import SwiftUI

struct AppInfo: Identifiable, Sendable {
    let url: URL
    let name: String
    let bundleId: String?
    let version: String?
    var id: URL { url }
}

@MainActor
final class AppsModel: ObservableObject {
    @Published var apps: [AppInfo] = []
    @Published var sizes: [URL: Int64] = [:]
    @Published var loading = false

    func scan(volume: Volume? = nil) async {
        loading = true
        var roots = [URL(fileURLWithPath: "/Applications"),
                     CleanTarget.home.appendingPathComponent("Applications")]
        if let v = volume, !v.isBoot { roots = [v.url.appendingPathComponent("Applications"), v.url] }
        let rs = roots
        let found = await Task.detached { Self.listApps(roots: rs) }.value
        apps = found
        sizes = [:]
        await withTaskGroup(of: (URL, Int64).self) { group in
            for a in found {
                group.addTask { (a.url, allocatedSize(of: a.url)) }
            }
            for await (u, s) in group { sizes[u] = s }
        }
        loading = false
    }

    nonisolated private static func listApps(roots: [URL]) -> [AppInfo] {
        let fm = FileManager.default
        var urls: [URL] = []
        for root in roots {
            let items = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
            for it in items {
                if it.pathExtension == "app" { urls.append(it); continue }
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: it.path, isDirectory: &isDir), isDir.boolValue {
                    let sub = (try? fm.contentsOfDirectory(at: it, includingPropertiesForKeys: nil)) ?? []
                    urls += sub.filter { $0.pathExtension == "app" }
                }
            }
        }
        return urls.compactMap { u in
            let info = Bundle(url: u)?.infoDictionary
            let bid = info?["CFBundleIdentifier"] as? String
            if bid?.hasPrefix("com.apple.") == true { return nil }
            return AppInfo(url: u, name: u.deletingPathExtension().lastPathComponent,
                           bundleId: bid, version: info?["CFBundleShortVersionString"] as? String)
        }
    }
}

// MARK: - Restos

struct Leftover: Identifiable, Sendable {
    let url: URL
    let size: Int64
    let isApp: Bool
    var id: URL { url }
}

private let leftoverRoots: [String] = [
    "Library/Application Support", "Library/Caches", "Library/Preferences",
    "Library/Preferences/ByHost", "Library/Logs", "Library/Logs/DiagnosticReports",
    "Library/Containers", "Library/Group Containers", "Library/Saved Application State",
    "Library/HTTPStorages", "Library/WebKit", "Library/Cookies", "Library/LaunchAgents",
    "Library/Application Scripts",
]

/// Busca rastros de una app en ~/Library. Con `query` hace búsqueda por texto
/// (también en carpetas ocultas de ~ y en ~/.config, ~/.cache).
func findLeftoverURLs(bundleId: String?, name: String?, query: String?) -> [URL] {
    let fm = FileManager.default
    let home = CleanTarget.home
    var roots = leftoverRoots.map { home.appendingPathComponent($0) }
    if query != nil {
        roots += [home, home.appendingPathComponent(".config"), home.appendingPathComponent(".cache")]
    }
    let bid = bundleId?.lowercased()
    let nm = name?.lowercased()
    let nmNoSpace = nm?.replacingOccurrences(of: " ", with: "")
    let q = query?.lowercased()

    func matches(_ file: String, isHome: Bool) -> Bool {
        let lower = file.lowercased()
        if let q {
            if isHome && !file.hasPrefix(".") { return false }
            return lower.contains(q)
        }
        let stripped = (lower as NSString).deletingPathExtension
        if let bid {
            if lower == bid || stripped == bid || lower.hasPrefix(bid + ".") || lower.contains("." + bid) { return true }
        }
        if let nm, stripped == nm || lower == nm { return true }
        if let nmNoSpace, nmNoSpace.count >= 4, stripped == nmNoSpace { return true }
        return false
    }

    var seen = Set<URL>()
    var out: [URL] = []
    for root in roots {
        guard let items = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { continue }
        let isHome = root == home
        for it in items where matches(it.lastPathComponent, isHome: isHome) {
            if seen.insert(it).inserted { out.append(it) }
        }
    }
    return out
}

@MainActor
final class LeftoverModel: ObservableObject {
    @Published var items: [Leftover] = []
    @Published var selected: Set<URL> = []
    @Published var loading = false
    @Published var searched = false
    @Published var message: String?
    @Published var finished = false

    var selectedBytes: Int64 { items.filter { selected.contains($0.url) }.reduce(0) { $0 + $1.size } }

    func find(app: AppInfo?, query: String?) async {
        loading = true
        var urls = await Task.detached {
            findLeftoverURLs(bundleId: app?.bundleId, name: app?.name, query: query)
        }.value
        if let app { urls.insert(app.url, at: 0) }
        var result: [Leftover] = []
        await withTaskGroup(of: Leftover.self) { group in
            for u in urls {
                group.addTask { Leftover(url: u, size: allocatedSize(of: u), isApp: u == app?.url) }
            }
            for await l in group { result.append(l) }
        }
        items = result.sorted { ($0.isApp ? 1 : 0, $0.size) > ($1.isApp ? 1 : 0, $1.size) }
        selected = Set(items.map(\.url))
        loading = false
        searched = true
    }

    /// Mueve a la Papelera lo seleccionado.
    func trashSelected(app: AppInfo?) {
        if let app, selected.contains(app.url), let bid = app.bundleId,
           !NSRunningApplication.runningApplications(withBundleIdentifier: bid).isEmpty {
            message = "«\(app.name)» está abierta. Ciérrala y vuelve a intentar."
            return
        }
        let bytes = selectedBytes
        var moved = 0, failed = 0
        for item in items where selected.contains(item.url) {
            do {
                try FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
                moved += 1
            } catch { failed += 1 }
        }
        message = "Movidos \(moved) elementos a la Papelera (~\(formatBytes(bytes)))."
            + (failed > 0 ? " \(failed) fallaron (permisos)." : "")
            + " Vacía la Papelera para liberar el espacio."
        finished = true
    }
}
