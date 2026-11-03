import SwiftUI
import AppKit
import Photos

struct PhotosView: View {
    @ObservedObject var model: PhotosModel
    @State private var confirm = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            content
            Divider()
            footer
        }
        .onChange(of: model.distance) { _, _ in
            if model.hasScanned { Task { await model.regroup() } }
        }
        .confirmationDialog(
            "¿Borrar \(model.selectedCount) fotos?", isPresented: $confirm, titleVisibility: .visible
        ) {
            Button(model.source == .library ? "Enviar a Eliminados recientemente" : "Mover a la Papelera",
                   role: .destructive) { Task { await model.trashSelected() } }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text(model.source == .library
                 ? "Fotos te pedirá confirmar. Quedan 30 días en «Eliminados recientemente»."
                 : "Es reversible hasta que vacíes la Papelera.")
        }
        .alert("LimpiaMac", isPresented: Binding(
            get: { model.message != nil }, set: { if !$0 { model.message = nil } })
        ) { Button("OK") {} } message: { Text(model.message ?? "") }
    }

    private var toolbar: some View {
        VStack(spacing: 8) {
            HStack {
                Picker("", selection: $model.source) {
                    Text("Biblioteca de Fotos").tag(PhotosModel.Source.library)
                    Text("Carpeta").tag(PhotosModel.Source.folder)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 280)
                .onChange(of: model.source) { _, _ in model.reset() }
                if model.source == .folder {
                    Text(model.folder.map { ($0.path as NSString).abbreviatingWithTildeInPath } ?? "Sin carpeta")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                    Button("Elegir…") {
                        let p = NSOpenPanel()
                        p.canChooseDirectories = true; p.canChooseFiles = false
                        p.directoryURL = model.folder ?? CleanTarget.home.appendingPathComponent("Pictures")
                        if p.runModal() == .OK, let u = p.url { model.folder = u; model.reset() }
                    }.disabled(model.scanning)
                }
                Spacer()
            }
            HStack {
                Picker("Similitud", selection: $model.distance) {
                    Text("Estricta").tag(4)
                    Text("Media").tag(8)
                    Text("Amplia").tag(12)
                }.fixedSize()
                Spacer()
                if model.scanning {
                    ProgressView().controlSize(.small)
                    Text(model.total > 0 ? "Analizando \(model.done)/\(model.total)" : "Preparando…")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Cancelar") { model.cancel() }
                } else {
                    Button { model.scan() } label: { Label("Escanear", systemImage: "magnifyingglass") }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.source == .folder && model.folder == nil)
                }
            }
        }
        .padding(10)
    }

    @ViewBuilder
    private var content: some View {
        if model.authDenied {
            VStack(spacing: 10) {
                ContentUnavailableView("Sin permiso para Fotos", systemImage: "lock.shield",
                    description: Text("Da acceso a LimpiaMac en Ajustes → Privacidad y seguridad → Fotos."))
                Button("Abrir ajustes") {
                    NSWorkspace.shared.open(URL(string:
                        "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos")!)
                }
            }
        } else if model.groups.isEmpty {
            ContentUnavailableView(
                model.scanning ? "Analizando…" : (model.hasScanned ? "No hay fotos parecidas" : "Pulsa «Escanear»"),
                systemImage: "photo.on.rectangle",
                description: Text("Compara la apariencia de las fotos, no solo el contenido exacto. Corre en segundo plano con poca carga."))
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(model.groups) { g in
                        VStack(alignment: .leading, spacing: 6) {
                            Text("\(g.items.count) fotos parecidas").font(.headline)
                            ScrollView(.horizontal, showsIndicators: true) {
                                HStack(alignment: .top, spacing: 10) {
                                    ForEach(Array(g.items.enumerated()), id: \.element.id) { i, it in
                                        card(it, best: i == 0)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(14)
            }
        }
    }

    private func card(_ it: PhotoItem, best: Bool) -> some View {
        VStack(spacing: 4) {
            ZStack(alignment: .topLeading) {
                PhotoThumb(item: it)
                    .frame(width: 130, height: 130)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(model.selected.contains(it.id) ? Color.red : (best ? Color.green : .clear), lineWidth: 3))
                Toggle("", isOn: Binding(
                    get: { model.selected.contains(it.id) },
                    set: { on in if on { model.selected.insert(it.id) } else { model.selected.remove(it.id) } }
                )).labelsHidden().padding(5)
            }
            if best { Text("Mejor calidad").font(.caption2.bold()).foregroundStyle(.green) }
            Text("\(it.pixels > 0 ? dims(it.pixels) : "—")").font(.caption2).foregroundStyle(.secondary)
            if it.bytes > 0 { Text(formatBytes(it.bytes)).font(.caption2).foregroundStyle(.secondary) }
            Text(ageText(it.date)).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(width: 130)
        .contextMenu {
            if let u = it.url { Button("Mostrar en Finder") { NSWorkspace.shared.activateFileViewerSelecting([u]) } }
        }
    }

    private func dims(_ px: Int) -> String { String(format: "%.1f MP", Double(px) / 1_000_000) }

    private var footer: some View {
        HStack {
            Text("Verde = la de mayor calidad (se conserva). Marcadas en rojo = se borrarán. Nunca se borran todas las de un grupo.")
                .font(.caption).foregroundStyle(.secondary)
            if model.skipped > 0 {
                Text("\(model.skipped) no se pudieron leer.").font(.caption).foregroundStyle(.orange)
            }
            Spacer()
            Button { confirm = true } label: {
                Label("Borrar \(model.selectedCount) fotos", systemImage: "trash")
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.scanning || model.selected.isEmpty)
        }
        .padding()
    }
}

private struct AssetImageBox: @unchecked Sendable { let image: NSImage? }

struct PhotoThumb: View {
    let item: PhotoItem
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task(id: item.id) {
            let it = item
            let box = await Task.detached { () -> AssetImageBox in
                if let u = it.url, let cg = thumbnailCG(u, maxPixel: 260) {
                    return AssetImageBox(image: NSImage(cgImage: cg, size: .zero))
                }
                if let id = it.assetID,
                   let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject {
                    let o = PHImageRequestOptions()
                    o.isSynchronous = true; o.deliveryMode = .highQualityFormat
                    o.isNetworkAccessAllowed = false
                    var out: NSImage?
                    PHImageManager.default().requestImage(
                        for: asset, targetSize: CGSize(width: 260, height: 260),
                        contentMode: .aspectFill, options: o) { img, _ in out = img }
                    return AssetImageBox(image: out)
                }
                return AssetImageBox(image: nil)
            }.value
            image = box.image
        }
    }
}
