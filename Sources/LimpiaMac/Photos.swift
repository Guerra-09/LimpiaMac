import Foundation
import AppKit
import ImageIO
import Photos

struct PhotoItem: Identifiable, Sendable {
    let id: String          // ruta, o localIdentifier en la biblioteca de Fotos
    let url: URL?
    let assetID: String?
    let hash: UInt64
    let pixels: Int
    let bytes: Int64
    let date: Date?
}

struct SimilarGroup: Identifiable, Sendable {
    let id: String
    let items: [PhotoItem]  // el primero es el "mejor"
}

// MARK: - Hash perceptual (dHash 64 bits)

/// Reduce la imagen a 9x8 en grises y compara píxeles vecinos.
/// Sobrevive a cambios de tamaño, compresión y retoques leves.
func dHash(_ image: CGImage) -> UInt64 {
    var px = [UInt8](repeating: 0, count: 9 * 8)
    let ok: Bool = px.withUnsafeMutableBytes { buf in
        guard let ctx = CGContext(data: buf.baseAddress, width: 9, height: 8, bitsPerComponent: 8,
                                  bytesPerRow: 9, space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: 9, height: 8))
        return true
    }
    guard ok else { return 0 }
    var h: UInt64 = 0
    for y in 0..<8 {
        for x in 0..<8 where px[y * 9 + x] > px[y * 9 + x + 1] { h |= 1 << UInt64(y * 8 + x) }
    }
    return h
}

func thumbnailCG(_ url: URL, maxPixel: Int) -> CGImage? {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    let opts: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        kCGImageSourceCreateThumbnailWithTransform: true,
    ]
    return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
}

private let imageExts: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "gif", "webp", "bmp"]

func listImages(root: URL) -> [URL] {
    guard let en = FileManager.default.enumerator(
        at: root, includingPropertiesForKeys: nil,
        options: [.skipsPackageDescendants, .skipsHiddenFiles], errorHandler: { _, _ in true }
    ) else { return [] }
    var out: [URL] = []
    for case let u as URL in en {
        if Task.isCancelled { break }
        if imageExts.contains(u.pathExtension.lowercased()) { out.append(u) }
    }
    return out
}

func hashImageFile(_ url: URL) -> PhotoItem? {
    guard let cg = thumbnailCG(url, maxPixel: 64) else { return nil }
    let h = dHash(cg)
    guard h != 0 else { return nil }   // imagen plana: no sirve para comparar
    var pixels = 0
    if let src = CGImageSourceCreateWithURL(url as CFURL, nil),
       let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
       let w = p[kCGImagePropertyPixelWidth] as? Int, let ht = p[kCGImagePropertyPixelHeight] as? Int {
        pixels = w * ht
    }
    let v = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
    return PhotoItem(id: url.path, url: url, assetID: nil, hash: h, pixels: pixels,
                     bytes: Int64(v?.fileSize ?? 0), date: v?.contentModificationDate)
}

struct AssetBox: @unchecked Sendable { let asset: PHAsset }

func hashAsset(_ box: AssetBox) -> PhotoItem? {
    let opts = PHImageRequestOptions()
    opts.deliveryMode = .fastFormat
    opts.resizeMode = .fast
    opts.isSynchronous = true
    opts.isNetworkAccessAllowed = false
    var result: PhotoItem?
    PHImageManager.default().requestImage(
        for: box.asset, targetSize: CGSize(width: 64, height: 64), contentMode: .aspectFit, options: opts
    ) { img, _ in
        guard let cg = img?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let h = dHash(cg)
        guard h != 0 else { return }
        result = PhotoItem(id: box.asset.localIdentifier, url: nil, assetID: box.asset.localIdentifier,
                           hash: h, pixels: box.asset.pixelWidth * box.asset.pixelHeight,
                           bytes: 0, date: box.asset.creationDate)
    }
    return result
}

// MARK: - Agrupación

/// Une fotos cuyo hash difiere en <= maxDistance bits (union-find).
func groupSimilar(_ items: [PhotoItem], maxDistance: Int) -> [SimilarGroup] {
    let n = items.count
    guard n > 1 else { return [] }
    var parent = Array(0..<n)
    func find(_ x: Int) -> Int {
        var r = x
        while parent[r] != r { r = parent[r] }
        var c = x
        while parent[c] != r { let nx = parent[c]; parent[c] = r; c = nx }
        return r
    }
    let hashes = items.map(\.hash)
    for i in 0..<n {
        if i & 1023 == 0 && Task.isCancelled { return [] }
        for j in (i + 1)..<n where (hashes[i] ^ hashes[j]).nonzeroBitCount <= maxDistance {
            let a = find(i), b = find(j)
            if a != b { parent[a] = b }
        }
    }
    var buckets: [Int: [PhotoItem]] = [:]
    for i in 0..<n { buckets[find(i), default: []].append(items[i]) }
    return buckets.values.filter { $0.count > 1 }.map { g in
        let sorted = g.sorted {
            ($0.pixels, $0.bytes, -($0.date?.timeIntervalSince1970 ?? .infinity))
                > ($1.pixels, $1.bytes, -($1.date?.timeIntervalSince1970 ?? .infinity))
        }
        return SimilarGroup(id: sorted[0].id, items: sorted)
    }
    .sorted { $0.items.count > $1.items.count }
}

// MARK: - Modelo

@MainActor
final class PhotosModel: ObservableObject {
    enum Source { case library, folder }

    @Published var source: Source = .library
    @Published var folder: URL?
    @Published var groups: [SimilarGroup] = []
    @Published var selected: Set<String> = []
    @Published var scanning = false
    @Published var hasScanned = false
    @Published var done = 0
    @Published var total = 0
    @Published var skipped = 0
    @Published var authDenied = false
    @Published var message: String?
    /// Bits de diferencia permitidos (de 64): estricta 4, media 8, amplia 12.
    @Published var distance = 8

    private var all: [PhotoItem] = []
    private var task: Task<Void, Never>?

    var selectedCount: Int { selected.count }

    func reset() { task?.cancel(); groups = []; selected = []; all = []; hasScanned = false; scanning = false }
    func cancel() { task?.cancel(); scanning = false }

    func regroup() async {
        let items = all, d = distance
        groups = await Task.detached { groupSimilar(items, maxDistance: d) }.value
        selected = Set(groups.flatMap { $0.items.dropFirst().map(\.id) })
    }

    func scan() {
        task?.cancel()
        scanning = true; hasScanned = false; groups = []; selected = []; all = []
        done = 0; total = 0; skipped = 0; authDenied = false
        task = Task {
            var jobs: [@Sendable () -> PhotoItem?] = []
            switch source {
            case .folder:
                guard let root = folder else { scanning = false; return }
                let files = await Task.detached { listImages(root: root) }.value
                jobs = files.map { u in { hashImageFile(u) } }
            case .library:
                let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
                guard status == .authorized || status == .limited else {
                    authDenied = true; scanning = false; return
                }
                let fetch = PHAsset.fetchAssets(with: .image, options: nil)
                var boxes: [AssetBox] = []
                fetch.enumerateObjects { a, _, _ in boxes.append(AssetBox(asset: a)) }
                jobs = boxes.map { b in { hashAsset(b) } }
            }
            total = jobs.count
            all = await runJobs(jobs)
            guard !Task.isCancelled else { return }
            skipped = total - all.count
            await regroup()
            hasScanned = true; scanning = false
        }
    }

    /// 4 trabajadores en prioridad baja para no cargar el Mac.
    private func runJobs(_ jobs: [@Sendable () -> PhotoItem?]) async -> [PhotoItem] {
        var out: [PhotoItem] = []
        await withTaskGroup(of: PhotoItem?.self) { g in
            var next = 0
            func add() {
                guard next < jobs.count else { return }
                let j = jobs[next]; next += 1
                g.addTask(priority: .utility) { j() }
            }
            for _ in 0..<4 { add() }
            for await r in g {
                if let r { out.append(r) }
                done += 1
                if Task.isCancelled { g.cancelAll(); break }
                add()
            }
        }
        return out
    }

    func trashSelected() async {
        var protected = 0
        var ids: [String] = []
        for g in groups {
            let sel = g.items.filter { selected.contains($0.id) }.map(\.id)
            if sel.count == g.items.count { protected += 1; ids += sel.dropFirst() } else { ids += sel }
        }
        var note = ""
        if source == .folder {
            let urls = all.filter { ids.contains($0.id) }.compactMap(\.url)
            let r = trashURLs(urls)
            note = "Movidas \(r.moved) fotos a la Papelera." + (r.failed > 0 ? " \(r.failed) fallaron." : "")
        } else {
            let assets = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
            var list: [PHAsset] = []
            assets.enumerateObjects { a, _, _ in list.append(a) }
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest.deleteAssets(list as NSArray)
                }
                note = "Enviadas \(list.count) fotos a «Eliminados recientemente» en Fotos."
            } catch {
                note = "No se borró nada (cancelado o sin permiso)."
                message = note
                return
            }
        }
        if protected > 0 { note += " En \(protected) grupos tenías todas marcadas: dejé una." }
        let gone = Set(ids)
        all.removeAll { gone.contains($0.id) }
        await regroup()
        message = note
    }
}
