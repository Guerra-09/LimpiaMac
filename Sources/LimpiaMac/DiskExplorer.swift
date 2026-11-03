import Foundation
import AppKit

struct DiskEntry: Identifiable, Sendable {
    let url: URL
    let size: Int64
    let isDir: Bool
    var id: URL { url }
    var name: String { url.lastPathComponent }
}

@MainActor
final class DiskModel: ObservableObject {
    @Published var current: URL = CleanTarget.home
    @Published var entries: [DiskEntry] = []
    @Published var scanning = false
    @Published var pending = 0

    var volumeID = ""
    private var task: Task<Void, Never>?
    private var generation = 0

    var total: Int64 { entries.reduce(0) { $0 + $1.size } }

    func load(_ url: URL) {
        task?.cancel()
        generation += 1
        let gen = generation
        current = url
        entries = []
        scanning = true

        task = Task {
            let fm = FileManager.default
            let children = (try? fm.contentsOfDirectory(
                at: url, includingPropertiesForKeys: nil, options: [])) ?? []
            pending = children.count

            await withTaskGroup(of: DiskEntry.self) { group in
                for child in children {
                    group.addTask {
                        var isDir: ObjCBool = false
                        fm.fileExists(atPath: child.path, isDirectory: &isDir)
                        let link = (try? child.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
                        return DiskEntry(url: child, size: allocatedSize(of: child),
                                         isDir: isDir.boolValue && !link)
                    }
                }
                for await e in group {
                    guard gen == generation, !Task.isCancelled else { continue }
                    let idx = entries.firstIndex { $0.size < e.size } ?? entries.endIndex
                    entries.insert(e, at: idx)
                    pending -= 1
                }
            }
            if gen == generation { scanning = false; pending = 0 }
        }
    }

    func goUp() {
        let parent = current.deletingLastPathComponent()
        if parent != current { load(parent) }
    }

    func trash(_ e: DiskEntry) {
        do {
            try FileManager.default.trashItem(at: e.url, resultingItemURL: nil)
            entries.removeAll { $0.id == e.id }
        } catch {
            NSSound.beep()
        }
    }

    func chooseFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.directoryURL = current
        if p.runModal() == .OK, let u = p.url { load(u) }
    }
}
