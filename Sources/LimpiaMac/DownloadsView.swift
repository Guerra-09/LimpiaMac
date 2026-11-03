import SwiftUI
import AppKit

struct DownloadsView: View {
    @ObservedObject var model: DownloadsModel
    @State private var customRoot: URL?
    @State private var confirm = false

    private var root: URL { customRoot ?? CleanTarget.home.appendingPathComponent("Downloads") }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if !model.hasScanned && !model.scanning {
                ContentUnavailableView("Pulsa «Escanear»", systemImage: "arrow.down.circle",
                    description: Text("Instaladores y comprimidos viejos, y copias de seguridad de iPhone/iPad."))
            } else {
                list
            }
            Divider()
            footer
        }
        .task { if !model.hasScanned && !model.scanning { model.scan(downloads: root) } }
        .confirmationDialog(
            "¿Mover ~\(formatBytes(model.selectedBytes)) a la Papelera?",
            isPresented: $confirm, titleVisibility: .visible
        ) {
            Button("Mover a la Papelera", role: .destructive) { model.trashSelected() }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text(model.selectionHasBackups
                 ? "Incluye copias de seguridad de dispositivos. Una vez que vacíes la Papelera no se podrán recuperar."
                 : "Es reversible hasta que vacíes la Papelera.")
        }
        .alert("LimpiaMac", isPresented: Binding(
            get: { model.message != nil }, set: { if !$0 { model.message = nil } })
        ) { Button("OK") {} } message: { Text(model.message ?? "") }
    }

    private var toolbar: some View {
        HStack {
            Picker("Sin modificar hace", selection: $model.minAgeDays) {
                Text("cualquier tiempo").tag(0)
                Text("1 mes").tag(30)
                Text("3 meses").tag(90)
                Text("6 meses").tag(180)
            }.fixedSize()
            Spacer()
            Text((root.path as NSString).abbreviatingWithTildeInPath)
                .font(.caption).foregroundStyle(.secondary)
            Button("Cambiar…") {
                let p = NSOpenPanel()
                p.canChooseDirectories = true; p.canChooseFiles = false; p.directoryURL = root
                if p.runModal() == .OK, let u = p.url { customRoot = u; model.scan(downloads: u) }
            }.disabled(model.scanning)
            if model.scanning { ProgressView().controlSize(.small) }
            Button { model.scan(downloads: root) } label: { Label("Escanear", systemImage: "magnifyingglass") }
                .buttonStyle(.borderedProminent).disabled(model.scanning)
        }
        .padding(10)
    }

    private var list: some View {
        List {
            Section("Instaladores y comprimidos") {
                if model.shownInstallers.isEmpty {
                    Text("No hay nada que mostrar.").foregroundStyle(.secondary)
                }
                ForEach(model.shownInstallers) { f in
                    HStack(spacing: 10) {
                        check(f.url)
                        Image(nsImage: NSWorkspace.shared.icon(forFile: f.url.path)).resizable().frame(width: 24, height: 24)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(f.url.lastPathComponent).lineLimit(1)
                            Text(f.kind).font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(ageText(f.modified)).font(.caption).foregroundStyle(.secondary)
                        Text(formatBytes(f.size)).monospacedDigit().frame(width: 80, alignment: .trailing)
                    }
                    .contextMenu {
                        Button("Mostrar en Finder") { NSWorkspace.shared.activateFileViewerSelecting([f.url]) }
                    }
                }
            }
            Section("Copias de seguridad de iPhone / iPad") {
                if model.backupsDenied {
                    HStack {
                        Image(systemName: "lock.shield").foregroundStyle(.orange)
                        Text("Sin acceso. Da «Acceso total al disco» a LimpiaMac y reinicia la app.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Abrir ajustes") {
                            NSWorkspace.shared.open(URL(string:
                                "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
                        }.controlSize(.small)
                    }
                } else if model.backups.isEmpty {
                    Text("No hay copias de seguridad.").foregroundStyle(.secondary)
                }
                ForEach(model.backups) { b in
                    HStack(spacing: 10) {
                        check(b.url)
                        Image(systemName: "iphone").frame(width: 24).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(b.name).font(.headline)
                            Text([b.model, b.version.map { "iOS \($0)" },
                                  b.lastBackup.map { "última copia: " + ageText($0) }]
                                    .compactMap { $0 }.joined(separator: " · "))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let s = model.sizes[b.url] {
                            Text(formatBytes(s)).monospacedDigit().frame(width: 80, alignment: .trailing)
                        } else {
                            ProgressView().controlSize(.small)
                        }
                    }
                    .contextMenu {
                        Button("Mostrar en Finder") { NSWorkspace.shared.activateFileViewerSelecting([b.url]) }
                    }
                }
            }
        }
    }

    private func check(_ u: URL) -> some View {
        Toggle("", isOn: Binding(
            get: { model.selected.contains(u) },
            set: { on in if on { model.selected.insert(u) } else { model.selected.remove(u) } }
        )).labelsHidden()
    }

    private var footer: some View {
        HStack {
            Text("Marcado por defecto: instaladores sin tocar hace más de \(DownloadsModel.staleDays) días. Las copias de iPhone nunca vienen marcadas.")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button { confirm = true } label: {
                Label("Mover a la Papelera (\(formatBytes(model.selectedBytes)))", systemImage: "trash")
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.scanning || model.selected.isEmpty)
        }
        .padding()
    }
}
