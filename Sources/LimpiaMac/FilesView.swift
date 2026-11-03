import SwiftUI
import AppKit

struct FilesView: View {
    enum Mode { case big, dups }

    @ObservedObject var big: BigFilesModel
    @ObservedObject var dups: DuplicatesModel
    let volume: Volume

    @State private var mode: Mode = .big
    @State private var customRoot: URL?
    @State private var confirm = false

    private var root: URL { customRoot ?? (volume.isBoot ? CleanTarget.home : volume.url) }
    private var scanning: Bool { mode == .big ? big.scanning : dups.scanning }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if mode == .big { bigList } else { dupList }
            Divider()
            footer
        }
        .onChange(of: volume.id) { _, _ in
            customRoot = nil; big.reset(); dups.reset()
        }
        .confirmationDialog(
            "¿Mover ~\(formatBytes(mode == .big ? big.selectedBytes : dups.selectedBytes)) a la Papelera?",
            isPresented: $confirm, titleVisibility: .visible
        ) {
            Button("Mover a la Papelera", role: .destructive) {
                if mode == .big { big.trashSelected() } else { dups.trashSelected() }
            }
            Button("Cancelar", role: .cancel) {}
        } message: { Text("Es reversible hasta que vacíes la Papelera.") }
        .alert("LimpiaMac", isPresented: Binding(
            get: { big.message != nil || dups.message != nil },
            set: { if !$0 { big.message = nil; dups.message = nil } })
        ) { Button("OK") {} } message: { Text(big.message ?? dups.message ?? "") }
    }

    // MARK: toolbar

    private var toolbar: some View {
        VStack(spacing: 8) {
            HStack {
                Picker("", selection: $mode) {
                    Text("Archivos grandes").tag(Mode.big)
                    Text("Duplicados exactos").tag(Mode.dups)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 320)
                Spacer()
                Text((root.path as NSString).abbreviatingWithTildeInPath)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                Button("Cambiar…") { chooseRoot() }.disabled(scanning)
            }
            HStack {
                if mode == .big {
                    Picker("Mayores de", selection: $big.minSize) {
                        Text("100 MB").tag(Int64(100_000_000))
                        Text("500 MB").tag(Int64(500_000_000))
                        Text("1 GB").tag(Int64(1_000_000_000))
                        Text("5 GB").tag(Int64(5_000_000_000))
                    }.fixedSize()
                    Picker("Sin modificar hace", selection: $big.minAgeDays) {
                        Text("cualquier tiempo").tag(0)
                        Text("3 meses").tag(90)
                        Text("6 meses").tag(180)
                        Text("1 año").tag(365)
                    }.fixedSize()
                } else {
                    Picker("Mayores de", selection: $dups.minSize) {
                        Text("100 KB").tag(Int64(100_000))
                        Text("1 MB").tag(Int64(1_000_000))
                        Text("10 MB").tag(Int64(10_000_000))
                        Text("100 MB").tag(Int64(100_000_000))
                    }.fixedSize()
                }
                Spacer()
                if scanning {
                    ProgressView().controlSize(.small)
                    if mode == .dups {
                        Text(dups.total > 0 ? "\(dups.phase) \(dups.done)/\(dups.total)" : dups.phase)
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("Buscando…").font(.caption).foregroundStyle(.secondary)
                    }
                    Button("Cancelar") { if mode == .big { big.cancel() } else { dups.cancel() } }
                } else {
                    Button { startScan() } label: { Label("Escanear", systemImage: "magnifyingglass") }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(10)
    }

    private func startScan() {
        if mode == .big { big.scan(root: root) } else { dups.scan(root: root) }
    }

    private func chooseRoot() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.directoryURL = root
        if p.runModal() == .OK, let u = p.url { customRoot = u; big.reset(); dups.reset() }
    }

    // MARK: grandes

    @ViewBuilder
    private var bigList: some View {
        if big.shown.isEmpty {
            ContentUnavailableView(
                big.scanning ? "Buscando…" : (big.hasScanned ? "No hay archivos con esos filtros" : "Pulsa «Escanear»"),
                systemImage: "doc.richtext",
                description: Text("No incluye ~/Library, node_modules ni apps."))
        } else {
            List(big.shown) { f in
                HStack(spacing: 10) {
                    Toggle("", isOn: Binding(
                        get: { big.selected.contains(f.url) },
                        set: { on in if on { big.selected.insert(f.url) } else { big.selected.remove(f.url) } }
                    )).labelsHidden()
                    fileLabel(f.url, subtitle: f.isPackage ? "Paquete" : nil)
                    Spacer()
                    Text(ageText(f.modified)).font(.caption).foregroundStyle(.secondary)
                    Text(formatBytes(f.size)).monospacedDigit().frame(width: 80, alignment: .trailing)
                }
                .contextMenu { finderItem(f.url) }
            }
        }
    }

    // MARK: duplicados

    @ViewBuilder
    private var dupList: some View {
        if dups.groups.isEmpty {
            ContentUnavailableView(
                dups.scanning ? "Buscando…" : (dups.hasScanned ? "No hay duplicados" : "Pulsa «Escanear»"),
                systemImage: "doc.on.doc",
                description: Text("Compara el contenido real (hash), no solo el nombre. Los enlaces duros no cuentan."))
        } else {
            List {
                ForEach(dups.groups) { g in
                    Section {
                        ForEach(g.files) { f in
                            HStack(spacing: 10) {
                                Toggle("", isOn: Binding(
                                    get: { dups.selected.contains(f.url) },
                                    set: { on in if on { dups.selected.insert(f.url) } else { dups.selected.remove(f.url) } }
                                )).labelsHidden()
                                fileLabel(f.url, subtitle: nil)
                                Spacer()
                                Text(ageText(f.modified)).font(.caption).foregroundStyle(.secondary)
                            }
                            .contextMenu { finderItem(f.url) }
                        }
                    } header: {
                        Text("\(g.files.count) copias · \(formatBytes(g.size)) c/u · se pueden liberar \(formatBytes(g.wasted))")
                    }
                }
            }
        }
    }

    // MARK: piezas

    private func fileLabel(_ url: URL, subtitle: String?) -> some View {
        HStack(spacing: 8) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(url.lastPathComponent).lineLimit(1)
                Text((url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
                     + (subtitle.map { " · " + $0 } ?? ""))
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            }
        }
    }

    @ViewBuilder
    private func finderItem(_ url: URL) -> some View {
        Button("Mostrar en Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }

    private var footer: some View {
        HStack {
            if mode == .dups && !dups.groups.isEmpty {
                Text("Se pueden liberar \(formatBytes(dups.wasted)) en total. Marcado por defecto: todo menos la copia más antigua.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if mode == .big && !big.files.isEmpty {
                Text("\(big.shown.count) archivos").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            let bytes = mode == .big ? big.selectedBytes : dups.selectedBytes
            let empty = mode == .big ? big.selected.isEmpty : dups.selected.isEmpty
            Button { confirm = true } label: {
                Label("Mover a la Papelera (\(formatBytes(bytes)))", systemImage: "trash")
            }
            .buttonStyle(.borderedProminent)
            .disabled(scanning || empty)
        }
        .padding()
    }
}
