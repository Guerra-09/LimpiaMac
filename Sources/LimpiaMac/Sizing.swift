import Foundation

func formatBytes(_ n: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
}

/// Tamaño real en disco de un archivo o carpeta (recursivo, sin seguir symlinks).
/// Cooperativo con cancelación de Task.
func allocatedSize(of url: URL) -> Int64 {
    let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey, .isSymbolicLinkKey]
    guard let top = try? url.resourceValues(forKeys: Set(keys)) else { return 0 }
    if top.isSymbolicLink == true { return 0 }
    if top.isRegularFile == true { return Int64(top.totalFileAllocatedSize ?? 0) }

    guard let en = FileManager.default.enumerator(
        at: url, includingPropertiesForKeys: keys, options: [],
        errorHandler: { _, _ in true }
    ) else { return 0 }

    var total: Int64 = 0
    var i = 0
    for case let u as URL in en {
        i += 1
        if i & 511 == 0 && Task.isCancelled { break }
        guard let v = try? u.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
        total += Int64(v.totalFileAllocatedSize ?? 0)
    }
    return total
}
