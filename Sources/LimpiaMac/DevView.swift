import SwiftUI
import AppKit

struct DevView: View {
    @ObservedObject var dev: DevModel
    @ObservedObject var docker: DockerModel
    @State private var confirmDelete = false
    @State private var pendingPrune: DockerPrune?

    private var shown: [DevItem] {
        dev.items.sorted { (dev.sizes[$0.url] ?? -1) > (dev.sizes[$1.url] ?? -1) }
    }

    var body: some View {
        VStack(spacing: 0) {
            dockerCard
            Divider()
            rootsBar
            Divider()
            if dev.items.isEmpty {
                ContentUnavailableView(
                    dev.scanning ? "Buscando…" : (dev.hasScanned ? "No se encontró nada" : "Pulsa «Escanear»"),
                    systemImage: "hammer",
                    description: Text("node_modules, Pods, venv, target, build y cachés de proyectos."))
            } else {
                List(shown) { row($0) }
            }
            Divider()
            footer
        }
        .task { await docker.refresh() }
        .confirmationDialog(
            "¿Borrar ~\(formatBytes(dev.selectedBytes))?",
            isPresented: $confirmDelete, titleVisibility: .visible
        ) {
            Button("Borrar", role: .destructive) { Task { await dev.deleteSelected() } }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Se borran de forma permanente. Se regeneran con npm install, pod install, etc.")
        }
        .confirmationDialog(
            pendingPrune?.title ?? "", isPresented: Binding(
                get: { pendingPrune != nil }, set: { if !$0 { pendingPrune = nil } }),
            titleVisibility: .visible, presenting: pendingPrune
        ) { p in
            Button("Ejecutar", role: .destructive) { Task { await docker.prune(p) } }
            Button("Cancelar", role: .cancel) {}
        } message: { Text($0.detail) }
        .alert("LimpiaMac", isPresented: Binding(
            get: { dev.message != nil || docker.message != nil },
            set: { if !$0 { dev.message = nil; docker.message = nil } })
        ) { Button("OK") {} } message: { Text(dev.message ?? docker.message ?? "") }
    }

    // MARK: Docker

    private var dockerCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Docker", systemImage: "shippingbox").font(.headline)
                Spacer()
                if docker.working { ProgressView().controlSize(.small) }
                Button { Task { await docker.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(docker.working)
            }
            switch docker.state {
            case .loading:
                ProgressView().controlSize(.small)
            case .notInstalled:
                Text("Docker no está instalado.").foregroundStyle(.secondary)
            case .notRunning(let why):
                Text("Docker no está corriendo (\(why)). Ábrelo y pulsa refrescar.")
                    .font(.caption).foregroundStyle(.secondary)
            case .ready(let rows):
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 2) {
                    GridRow {
                        ForEach(["Tipo", "Total", "Activos", "Tamaño", "Recuperable"], id: \.self) {
                            Text($0).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    ForEach(rows) { r in
                        GridRow {
                            Text(r.type); Text(r.total); Text(r.active); Text(r.size)
                            Text(r.reclaimable).foregroundStyle(.orange)
                        }.font(.callout.monospacedDigit())
                    }
                }
                HStack {
                    ForEach([DockerPrune.builder, .system, .images]) { p in
                        Button(p.title) { pendingPrune = p }.disabled(docker.working)
                    }
                }
            }
        }
        .padding(12)
    }

    // MARK: Proyectos

    private var rootsBar: some View {
        HStack {
            Text("Buscar en:").font(.caption).foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(dev.roots, id: \.self) { r in
                        HStack(spacing: 2) {
                            Text((r.path as NSString).abbreviatingWithTildeInPath).font(.caption)
                            Button { dev.removeRoot(r) } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.plain).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(.quaternary, in: Capsule())
                    }
                }
            }
            Button { dev.addRoot() } label: { Image(systemName: "plus") }.help("Agregar carpeta")
            Button { Task { await dev.scan() } } label: { Label("Escanear", systemImage: "magnifyingglass") }
                .disabled(dev.scanning || dev.deleting || dev.roots.isEmpty)
        }
        .padding(10)
    }

    private func row(_ it: DevItem) -> some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(
                get: { dev.selected.contains(it.url) },
                set: { on in if on { dev.selected.insert(it.url) } else { dev.selected.remove(it.url) } }
            )).labelsHidden()
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(it.project).font(.headline)
                    Text(it.label).font(.caption2)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }
                Text((it.url.path as NSString).abbreviatingWithTildeInPath)
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            }
            Spacer()
            Text(activity(it.lastActive)).font(.caption).foregroundStyle(.secondary)
            if let s = dev.sizes[it.url] {
                Text(formatBytes(s)).monospacedDigit().frame(width: 80, alignment: .trailing)
            } else {
                ProgressView().controlSize(.small).frame(width: 80, alignment: .trailing)
            }
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button("Mostrar en Finder") { NSWorkspace.shared.activateFileViewerSelecting([it.url]) }
        }
    }

    private func activity(_ d: Date?) -> String {
        guard let d else { return "—" }
        let days = Calendar.current.dateComponents([.day], from: d, to: Date()).day ?? 0
        return days <= 0 ? "activo hoy" : "hace \(days) d"
    }

    private var footer: some View {
        HStack {
            if !dev.items.isEmpty {
                Text("Marcado por defecto: proyectos sin tocar hace más de \(DevModel.staleDays) días")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if dev.scanning || dev.deleting { ProgressView().controlSize(.small) }
            Button { confirmDelete = true } label: {
                Label("Borrar \(formatBytes(dev.selectedBytes))", systemImage: "trash")
            }
            .buttonStyle(.borderedProminent)
            .disabled(dev.scanning || dev.deleting || dev.selected.isEmpty)
        }
        .padding()
    }
}
