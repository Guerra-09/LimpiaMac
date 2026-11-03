import Foundation
import CryptoKit
import AppKit

private let fileSkipNames: Set<String> = [
    ".git", "node_modules", "Pods", ".Trash", ".Trashes", ".Spotlight-V100", ".fseventsd",
    "Backups.backupdb", ".DocumentRevisions-V100",
]

/// Mueve a la Papelera. Devuelve (movidos, fallidos).
func trashURLs(_ urls: [URL]) -> (moved: Int, failed: Int) {
    var moved = 0, failed = 0
    for u in urls {
        do { try FileManager.default.trashItem(at: u, resultingItemURL: nil); moved += 1 }
        catch { failed += 1 }
    }
    return (moved, failed)
}

func ageText(_ d: Date?) -> String {
    guard let d else { return "—" }
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .short
    return f.localizedString(for: d, relativeTo: Date())
}

// MARK: - Archivos grandes

struct BigFile: Identifiable, Sendable {
    let url: URL
    let size: Int64
    let modified: Date?
    let isPackage: Bool
    var id: URL { url }
}

func findBigFiles(root: URL, minSize: Int64) -> [BigFile] {
    let fm = FileManager.default
    let home = CleanTarget.home
    let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isPackageKey,
                                  .totalFileAllocatedSizeKey, .contentModificationDateKey]
    guard let en = fm.enumerator(at: root, includingPropertiesForKeys: keys, options: [],
                                 errorHandler: { _, _ in true }) else { return [] }
    var out: [BigFile] = []
    for case let u as URL in en {
        if Task.isCancelled { break }
        let name = u.lastPathComponent
        guard let v = try? u.resourceValues(forKeys: Set(keys)) else { continue }
        if v.isDirectory == true {
            if fileSkipNames.contains(name) || (name == "Library" && u.deletingLastPathComponent() == home) {
                en.skipDescendants(); continue
            }
            if v.isPackage == true {
                en.skipDescendants()
                if u.pathExtension != "app" {
                    let s = allocatedSize(of: u)
                    if s >= minSize { out.append(BigFile(url: u, size: s, modified: v.contentModificationDate, isPackage: true)) }
                }
            }
        } else if v.isRegularFile == true {
            let s = Int64(v.totalFileAllocatedSize ?? 0)
            if s >= minSize { out.append(BigFile(url: u, size: s, modified: v.contentModificationDate, isPackage: false)) }
        }
    }
    return out.sorted { $0.size > $1.size }.prefix(500).map { $0 }
}

@MainActor
final class BigFilesModel: ObservableObject {
    @Published var files: [BigFile] = []
    @Published var selected: Set<URL> = []
    @Published var scanning = false
    @Published var hasScanned = false
    @Published var message: String?
    @Published var minSize: Int64 = 500_000_000
    @Published var minAgeDays = 0

    private var task: Task<Void, Never>?

    var shown: [BigFile] {
        guard minAgeDays > 0 else { return files }
        let cutoff = Calendar.current.date(byAdding: .day, value: -minAgeDays, to: Date()) ?? .distantPast
        return files.filter { ($0.modified ?? .distantFuture) < cutoff }
    }
    var selectedBytes: Int64 { files.filter { selected.contains($0.url) }.reduce(0) { $0 + $1.size } }

    func reset() { task?.cancel(); files = []; selected = []; hasScanned = false; scanning = false }

    func scan(root: URL) {
        task?.cancel()
        scanning = true; files = []; selected = []
        let min = minSize
        task = Task {
            let found = await Task.detached { findBigFiles(root: root, minSize: min) }.value
            guard !Task.isCancelled else { return }
            files = found; hasScanned = true; scanning = false
        }
    }

    func cancel() { task?.cancel(); scanning = false }

    func trashSelected() {
        let urls = files.filter { selected.contains($0.url) }.map(\.url)
        let bytes = selectedBytes
        let r = trashURLs(urls)
        files.removeAll { !FileManager.default.fileExists(atPath: $0.url.path) }
        selected = []
        message = "Movidos \(r.moved) elementos a la Papelera (~\(formatBytes(bytes)))."
            + (r.failed > 0 ? " \(r.failed) fallaron." : "") + " Vacía la Papelera para liberar el espacio."
    }
}

// MARK: - Duplicados exactos

struct DupGroup: Identifiable, Sendable {
    let id: String
    let size: Int64
    let files: [DupFile]
    var wasted: Int64 { size * Int64(files.count - 1) }
}

struct DupFile: Identifiable, Sendable {
    let url: URL
    let modified: Date?
    var id: URL { url }
}

private func sha256(of url: URL, firstBytes limit: Int? = nil) -> String? {
    guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? h.close() }
    var hasher = SHA256()
    var total = 0
    while !Task.isCancelled {
        let want = limit.map { min(1 << 20, $0 - total) } ?? (1 << 20)
        if want <= 0 { break }
        guard let d = try? h.read(upToCount: want), !d.isEmpty else { break }
        hasher.update(data: d)
        total += d.count
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

/// Lista archivos por tamaño; descarta enlaces duros (mismo inode).
private func listBySize(root: URL, minSize: Int64) -> [Int64: [(URL, Date?)]] {
    let fm = FileManager.default
    let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isPackageKey, .fileSizeKey,
                                  .contentModificationDateKey, .fileResourceIdentifierKey]
    guard let en = fm.enumerator(at: root, includingPropertiesForKeys: keys,
                                 options: [.skipsPackageDescendants], errorHandler: { _, _ in true })
    else { return [:] }
    let home = CleanTarget.home
    var bySize: [Int64: [(URL, Date?, NSObject?)]] = [:]
    for case let u as URL in en {
        if Task.isCancelled { break }
        guard let v = try? u.resourceValues(forKeys: Set(keys)) else { continue }
        if v.isDirectory == true {
            let n = u.lastPathComponent
            if fileSkipNames.contains(n) || (n == "Library" && u.deletingLastPathComponent() == home) {
                en.skipDescendants()
            }
            continue
        }
        guard v.isRegularFile == true, let s = v.fileSize, Int64(s) >= minSize else { continue }
        bySize[Int64(s), default: []].append((u, v.contentModificationDate, v.fileResourceIdentifier as? NSObject))
    }
    var out: [Int64: [(URL, Date?)]] = [:]
    for (size, items) in bySize where items.count > 1 {
        var ids = Set<NSObject>()
        let unique = items.filter { item in
            guard let id = item.2 else { return true }
            return ids.insert(id).inserted
        }
        if unique.count > 1 { out[size] = unique.map { ($0.0, $0.1) } }
    }
    return out
}

private func findDuplicates(size: Int64, items: [(URL, Date?)]) -> [DupGroup] {
    var byPartial: [String: [(URL, Date?)]] = [:]
    for it in items {
        if Task.isCancelled { return [] }
        if let h = sha256(of: it.0, firstBytes: 65_536) { byPartial[h, default: []].append(it) }
    }
    var groups: [DupGroup] = []
    for (_, cand) in byPartial where cand.count > 1 {
        var byFull: [String: [(URL, Date?)]] = [:]
        for it in cand {
            if Task.isCancelled { return [] }
            if let h = sha256(of: it.0) { byFull[h, default: []].append(it) }
        }
        for (h, same) in byFull where same.count > 1 {
            let files = same.sorted { ($0.1 ?? .distantFuture) < ($1.1 ?? .distantFuture) }
                .map { DupFile(url: $0.0, modified: $0.1) }
            groups.append(DupGroup(id: h, size: size, files: files))
        }
    }
    return groups
}

@MainActor
final class DuplicatesModel: ObservableObject {
    @Published var groups: [DupGroup] = []
    @Published var selected: Set<URL> = []
    @Published var phase = ""
    @Published var scanning = false
    @Published var hasScanned = false
    @Published var done = 0
    @Published var total = 0
    @Published var message: String?
    @Published var minSize: Int64 = 1_000_000

    private var task: Task<Void, Never>?

    var wasted: Int64 { groups.reduce(0) { $0 + $1.wasted } }
    var selectedBytes: Int64 {
        groups.reduce(0) { acc, g in acc + g.size * Int64(g.files.filter { selected.contains($0.url) }.count) }
    }

    func reset() { task?.cancel(); groups = []; selected = []; hasScanned = false; scanning = false }

    func scan(root: URL) {
        task?.cancel()
        scanning = true; groups = []; selected = []; done = 0; total = 0
        phase = "Listando archivos…"
        let min = minSize
        task = Task {
            let bySize = await Task.detached { listBySize(root: root, minSize: min) }.value
            guard !Task.isCancelled else { return }
            total = bySize.count
            phase = "Comparando contenido…"
            var found: [DupGroup] = []
            await withTaskGroup(of: [DupGroup].self) { group in
                var iterator = bySize.makeIterator()
                func addNext() -> Bool {
                    guard let (size, items) = iterator.next() else { return false }
                    group.addTask { findDuplicates(size: size, items: items) }
                    return true
                }
                for _ in 0..<4 { _ = addNext() }
                for await r in group {
                    found += r
                    done += 1
                    _ = addNext()
                }
            }
            guard !Task.isCancelled else { return }
            groups = found.sorted { $0.wasted > $1.wasted }
            // Por defecto se conserva el más antiguo de cada grupo.
            selected = Set(groups.flatMap { $0.files.dropFirst().map(\.url) })
            hasScanned = true; scanning = false
        }
    }

    func cancel() { task?.cancel(); scanning = false }

    func trashSelected() {
        // Nunca borra todas las copias de un grupo.
        var urls: [URL] = []
        var protected = 0
        for g in groups {
            let sel = g.files.filter { selected.contains($0.url) }
            if sel.count == g.files.count { protected += 1; urls += sel.dropFirst().map(\.url) }
            else { urls += sel.map(\.url) }
        }
        let bytes = selectedBytes
        let r = trashURLs(urls)
        groups = groups.compactMap { g in
            let left = g.files.filter { FileManager.default.fileExists(atPath: $0.url.path) }
            return left.count > 1 ? DupGroup(id: g.id, size: g.size, files: left) : nil
        }
        selected = selected.filter { u in groups.contains { $0.files.contains { $0.url == u } } }
        message = "Movidos \(r.moved) archivos a la Papelera (~\(formatBytes(bytes)))."
            + (protected > 0 ? " En \(protected) grupos tenías todas las copias marcadas: dejé una." : "")
            + (r.failed > 0 ? " \(r.failed) fallaron." : "")
    }
}
