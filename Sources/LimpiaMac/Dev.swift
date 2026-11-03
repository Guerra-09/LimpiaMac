import Foundation
import AppKit

// MARK: - Basura de proyectos

struct DevItem: Identifiable, Sendable {
    let url: URL
    let label: String
    let lastActive: Date?
    var id: URL { url }
    var project: String { url.deletingLastPathComponent().lastPathComponent }
}

private let devCandidateNames: Set<String> = [
    "node_modules", "Pods", ".venv", "venv", "env", "target", "build", ".gradle",
    ".next", ".nuxt", ".angular", ".svelte-kit", ".turbo", ".build", ".dart_tool",
]
private let devSkipNames: Set<String> = [".git", "Library", ".Trash", "Applications"]

/// Carpeta regenerable de un proyecto, o nil. Exige un archivo del proyecto al lado
/// para no confundir una carpeta cualquiera llamada "build" o "target".
private func devLabel(for url: URL) -> String? {
    let fm = FileManager.default
    let parent = url.deletingLastPathComponent()
    func sibling(_ names: String...) -> Bool {
        names.contains { fm.fileExists(atPath: parent.appendingPathComponent($0).path) }
    }
    switch url.lastPathComponent {
    case "node_modules": return "node_modules"
    case "Pods": return sibling("Podfile") ? "CocoaPods" : nil
    case ".venv", "venv", "env":
        return fm.fileExists(atPath: url.appendingPathComponent("pyvenv.cfg").path) ? "Python venv" : nil
    case "target":
        if sibling("Cargo.toml") { return "Rust target" }
        return sibling("pom.xml") ? "Maven target" : nil
    case "build": return sibling("build.gradle", "build.gradle.kts") ? "Gradle build" : nil
    case ".gradle": return sibling("build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts") ? "Gradle caché" : nil
    case ".next", ".nuxt", ".angular", ".svelte-kit", ".turbo":
        return sibling("package.json") ? url.lastPathComponent : nil
    case ".build": return sibling("Package.swift") ? "SwiftPM .build" : nil
    case ".dart_tool": return sibling("pubspec.yaml") ? "Dart tool" : nil
    default: return nil
    }
}

/// Última modificación entre los archivos del proyecto (sin contar la carpeta regenerable).
private func lastActivity(of project: URL, excluding junk: URL) -> Date? {
    let items = (try? FileManager.default.contentsOfDirectory(
        at: project, includingPropertiesForKeys: [.contentModificationDateKey],
        options: [.skipsHiddenFiles])) ?? []
    return items.filter { $0 != junk }
        .compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
        .max()
}

func findDevJunk(roots: [URL]) -> [DevItem] {
    let fm = FileManager.default
    var seen = Set<URL>()
    var out: [DevItem] = []
    for root in roots where fm.fileExists(atPath: root.path) {
        guard let en = fm.enumerator(
            at: root, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsPackageDescendants], errorHandler: { _, _ in true }
        ) else { continue }
        for case let u as URL in en {
            if Task.isCancelled { return out }
            let name = u.lastPathComponent
            guard devCandidateNames.contains(name) || devSkipNames.contains(name),
                  (try? u.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            else { continue }
            if let label = devLabel(for: u) {
                en.skipDescendants()
                if seen.insert(u).inserted {
                    out.append(DevItem(url: u, label: label,
                                       lastActive: lastActivity(of: u.deletingLastPathComponent(), excluding: u)))
                }
            } else if devSkipNames.contains(name) {
                en.skipDescendants()
            }
        }
    }
    return out
}

@MainActor
final class DevModel: ObservableObject {
    @Published var roots: [URL] = []
    @Published var items: [DevItem] = []
    @Published var sizes: [URL: Int64] = [:]
    @Published var selected: Set<URL> = []
    @Published var scanning = false
    @Published var deleting = false
    @Published var hasScanned = false
    @Published var message: String?

    private static let key = "devRoots"
    /// Proyectos sin tocar hace más de esto vienen marcados por defecto.
    static let staleDays = 30

    init() {
        let saved = UserDefaults.standard.stringArray(forKey: Self.key)
        if let saved {
            roots = saved.map { URL(fileURLWithPath: $0) }
        } else {
            let h = CleanTarget.home
            roots = ["Desktop", "Documents", "Developer", "dev", "Projects", "Code", "Sites"]
                .map { h.appendingPathComponent($0) }
                .filter { FileManager.default.fileExists(atPath: $0.path) }
        }
    }

    private func persist() {
        UserDefaults.standard.set(roots.map(\.path), forKey: Self.key)
    }

    func addRoot() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.allowsMultipleSelection = true
        if p.runModal() == .OK {
            for u in p.urls where !roots.contains(u) { roots.append(u) }
            persist()
        }
    }

    func removeRoot(_ u: URL) {
        roots.removeAll { $0 == u }
        persist()
    }

    var selectedBytes: Int64 { selected.reduce(0) { $0 + (sizes[$1] ?? 0) } }
    var totalBytes: Int64 { sizes.values.reduce(0, +) }

    func scan() async {
        scanning = true
        items = []; sizes = [:]; selected = []
        let rs = roots
        let found = await Task.detached { findDevJunk(roots: rs) }.value
        items = found
        let cutoff = Calendar.current.date(byAdding: .day, value: -Self.staleDays, to: Date()) ?? .distantPast
        selected = Set(found.filter { ($0.lastActive ?? .distantPast) < cutoff }.map(\.url))
        hasScanned = true
        await withTaskGroup(of: (URL, Int64).self) { group in
            for it in found { group.addTask { (it.url, allocatedSize(of: it.url)) } }
            for await (u, s) in group { sizes[u] = s }
        }
        scanning = false
    }

    func deleteSelected() async {
        let chosen = items.filter { selected.contains($0.url) }
        let bytes = selectedBytes
        deleting = true
        let failed = await Task.detached {
            var f = 0
            for it in chosen {
                do { try FileManager.default.removeItem(at: it.url) } catch { f += 1 }
            }
            return f
        }.value
        deleting = false
        items.removeAll { !FileManager.default.fileExists(atPath: $0.url.path) }
        selected = selected.filter { u in items.contains { $0.url == u } }
        message = "Listo. Se liberaron ~\(formatBytes(bytes))." + (failed > 0 ? " \(failed) fallaron (permisos)." : "")
    }
}

// MARK: - Docker

func runProcess(_ path: String, _ args: [String]) async -> (status: Int32, output: String) {
    await Task.detached {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = (URL(fileURLWithPath: path).deletingLastPathComponent().path)
            + ":/usr/local/bin:/opt/homebrew/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }.value
}

struct DockerRow: Identifiable, Sendable {
    let type: String, total: String, active: String, size: String, reclaimable: String
    var id: String { type }
}

enum DockerPrune: String, Identifiable {
    case builder, system, images
    var id: String { rawValue }

    var title: String {
        switch self {
        case .builder: "Limpiar caché de build"
        case .system: "Limpiar lo sin usar"
        case .images: "Borrar imágenes sin usar"
        }
    }
    var detail: String {
        switch self {
        case .builder: "Borra la caché de build. Las imágenes y contenedores no se tocan."
        case .system: "Borra contenedores detenidos, redes sin usar e imágenes huérfanas. No toca volúmenes."
        case .images: "Borra todas las imágenes que ningún contenedor usa. Se vuelven a descargar al necesitarlas."
        }
    }
    var args: [String] {
        switch self {
        case .builder: ["builder", "prune", "-f"]
        case .system: ["system", "prune", "-f"]
        case .images: ["image", "prune", "-a", "-f"]
        }
    }
}

@MainActor
final class DockerModel: ObservableObject {
    enum State { case loading, notInstalled, notRunning(String), ready([DockerRow]) }

    @Published var state: State = .loading
    @Published var working = false
    @Published var message: String?

    private var binary: String? {
        let fm = FileManager.default
        let tail = "Docker.app/Contents/Resources/bin/docker"
        var candidates = ["/usr/local/bin/docker", "/opt/homebrew/bin/docker",
                          "/Applications/" + tail,
                          CleanTarget.home.appendingPathComponent(".docker/bin/docker").path]
        // Docker instalado en un disco externo
        for v in (try? fm.contentsOfDirectory(atPath: "/Volumes")) ?? [] {
            candidates.append("/Volumes/\(v)/Applications/" + tail)
        }
        return candidates.first { fm.isExecutableFile(atPath: $0) }
    }

    func refresh() async {
        guard let bin = binary else { state = .notInstalled; return }
        let r = await runProcess(bin, ["system", "df", "--format", "{{json .}}"])
        guard r.status == 0 else {
            state = .notRunning(r.output.split(separator: "\n").first.map(String.init) ?? "Docker no responde")
            return
        }
        let rows: [DockerRow] = r.output.split(separator: "\n").compactMap { line in
            guard let d = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: String]
            else { return nil }
            return DockerRow(type: d["Type"] ?? "?", total: d["TotalCount"] ?? "", active: d["Active"] ?? "",
                             size: d["Size"] ?? "", reclaimable: d["Reclaimable"] ?? "")
        }
        state = .ready(rows)
    }

    func prune(_ kind: DockerPrune) async {
        guard let bin = binary else { return }
        working = true
        let r = await runProcess(bin, kind.args)
        working = false
        if r.status == 0 {
            let line = r.output.split(separator: "\n").last { $0.contains("reclaimed") }
            message = line.map(String.init) ?? "Listo."
        } else {
            message = "Falló: " + (r.output.split(separator: "\n").first.map(String.init) ?? "error desconocido")
        }
        await refresh()
    }
}
