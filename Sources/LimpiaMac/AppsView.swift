import SwiftUI
import AppKit

struct AppsView: View {
    @ObservedObject var model: AppsModel
    let volume: Volume
    @State private var filter = ""
    @State private var uninstalling: AppInfo?
    @State private var showSearch = false

    private var shown: [AppInfo] {
        let base = filter.isEmpty ? model.apps
            : model.apps.filter { $0.name.localizedCaseInsensitiveContains(filter) }
        return base.sorted { (model.sizes[$0.url] ?? -1) > (model.sizes[$1.url] ?? -1) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Filtrar aplicaciones", text: $filter).textFieldStyle(.roundedBorder)
                if model.loading { ProgressView().controlSize(.small) }
                Button { showSearch = true } label: {
                    Label("Buscar restos de una app borrada…", systemImage: "magnifyingglass")
                }
            }
            .padding(10)
            Divider()
            List(shown) { a in
                HStack(spacing: 12) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: a.url.path))
                        .resizable().frame(width: 32, height: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(a.name).font(.headline)
                        Text([a.version, a.bundleId].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let s = model.sizes[a.url] {
                        Text(formatBytes(s)).monospacedDigit().foregroundStyle(.secondary)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                    Button("Desinstalar…") { uninstalling = a }
                }
                .padding(.vertical, 3)
            }
        }
        .task(id: volume.id) { await model.scan(volume: volume) }
        .sheet(item: $uninstalling) { a in
            LeftoversSheet(app: a) { Task { await model.scan(volume: volume) } }
        }
        .sheet(isPresented: $showSearch) {
            LeftoversSheet(app: nil) {}
        }
    }
}

struct LeftoversSheet: View {
    let app: AppInfo?
    let onDone: () -> Void
    @StateObject private var model = LeftoverModel()
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(app.map { "Desinstalar «\($0.name)»" } ?? "Buscar restos de una app borrada")
                .font(.title3.bold())
            if app == nil {
                HStack {
                    TextField("Nombre o parte del nombre (ej. antigravity)", text: $query)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(search)
                    Button("Buscar", action: search)
                        .disabled(query.trimmingCharacters(in: .whitespaces).count < 3 || model.loading)
                }
            } else {
                Text("Se moverán a la Papelera la app y los archivos asociados marcados. Revisa la lista.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            if model.loading {
                HStack { ProgressView().controlSize(.small); Text("Buscando…") }
            } else if model.searched && model.items.isEmpty {
                Text("No se encontró nada.").foregroundStyle(.secondary)
            }

            if !model.items.isEmpty {
                List(model.items) { it in
                    HStack {
                        Toggle("", isOn: Binding(
                            get: { model.selected.contains(it.url) },
                            set: { on in
                                if on { model.selected.insert(it.url) } else { model.selected.remove(it.url) }
                            })).labelsHidden()
                        VStack(alignment: .leading, spacing: 1) {
                            Text(it.url.lastPathComponent).font(.callout.weight(it.isApp ? .bold : .regular))
                            Text((it.url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(formatBytes(it.size)).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                .frame(minHeight: 220)
            }

            if let m = model.message { Text(m).font(.callout).foregroundStyle(.orange) }

            HStack {
                Spacer()
                Button(model.finished ? "Cerrar" : "Cancelar") {
                    if model.finished { onDone() }
                    dismiss()
                }
                if !model.finished {
                    Button("Mover a la Papelera (\(formatBytes(model.selectedBytes)))") {
                        model.trashSelected(app: app)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.selected.isEmpty || model.loading)
                }
            }
        }
        .padding(20)
        .frame(width: 600, height: 480)
        .task { if let app { await model.find(app: app, query: nil) } }
    }

    private func search() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= 3 else { return }
        Task { await model.find(app: nil, query: q) }
    }
}
