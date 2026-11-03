import SwiftUI
import AppKit

struct DiskView: View {
    enum Mode { case list, bubbles }

    @ObservedObject var model: DiskModel
    let volume: Volume
    @State private var toTrash: DiskEntry?
    @State private var mode: Mode = .list
    @State private var layout: BubbleLayout = .empty

    private var places: [(String, URL)] {
        if volume.isBoot {
            return [
                ("Inicio", CleanTarget.home),
                ("~/Library", CleanTarget.home.appendingPathComponent("Library")),
                ("/Library", URL(fileURLWithPath: "/Library")),
                ("/private/var", URL(fileURLWithPath: "/private/var")),
                ("/Applications", URL(fileURLWithPath: "/Applications")),
            ]
        }
        return [("Raíz de \(volume.name)", volume.url)]
    }

    private var startURL: URL { volume.isBoot ? CleanTarget.home : volume.url }

    private func syncVolume() {
        if model.volumeID != volume.id {
            model.volumeID = volume.id
            model.load(startURL)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if model.entries.isEmpty && !model.scanning {
                ContentUnavailableView("Carpeta vacía o sin permiso", systemImage: "folder")
            } else if mode == .list {
                listView
            } else {
                bubbleView
            }
        }
        .onAppear {
            if model.volumeID != volume.id { syncVolume() }
            else if model.entries.isEmpty && !model.scanning { model.load(model.current) }
            relayout()
        }
        .onChange(of: volume.id) { _, _ in syncVolume() }
        .onChange(of: model.scanning) { _, s in if !s { relayout() } }
        .onChange(of: model.entries.count) { _, _ in if !model.scanning { relayout() } }
        .onChange(of: mode) { _, _ in if !model.scanning { relayout() } }
        .confirmationDialog(
            "¿Mover «\(toTrash?.name ?? "")» a la Papelera?",
            isPresented: Binding(get: { toTrash != nil }, set: { if !$0 { toTrash = nil } }),
            titleVisibility: .visible
        ) {
            Button("Mover a la Papelera", role: .destructive) {
                if let e = toTrash { model.trash(e) }
                toTrash = nil
            }
            Button("Cancelar", role: .cancel) { toTrash = nil }
        } message: {
            Text("Es reversible hasta que vacíes la Papelera.")
        }
    }

    private func relayout() {
        if mode == .bubbles { layout = packBubbles(model.entries) }
    }

    // MARK: toolbar

    private var toolbar: some View {
        HStack {
            Button { model.goUp() } label: { Image(systemName: "chevron.up") }
                .help("Subir un nivel")
            Menu("Ir a") {
                ForEach(places, id: \.0) { p in Button(p.0) { model.load(p.1) } }
                Divider()
                Button("Elegir carpeta…") { model.chooseFolder() }
            }.fixedSize()
            Text(model.current.path).font(.callout).lineLimit(1).truncationMode(.head)
            Spacer()
            if model.scanning {
                ProgressView().controlSize(.small)
                Text("\(model.pending) pendientes").font(.caption).foregroundStyle(.secondary)
            }
            Text(formatBytes(model.total)).monospacedDigit().bold()
            Picker("Vista", selection: $mode) {
                Image(systemName: "list.bullet").tag(Mode.list)
                Image(systemName: "circle.grid.2x2").tag(Mode.bubbles)
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 90)
        }
        .padding(10)
    }

    // MARK: lista

    private var listView: some View {
        List(model.entries) { e in
            row(e)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { if e.isDir { model.load(e.url) } }
                .contextMenu { menu(e) }
        }
    }

    @ViewBuilder
    private func menu(_ e: DiskEntry) -> some View {
        if e.isDir { Button("Abrir") { model.load(e.url) } }
        Button("Mostrar en Finder") { NSWorkspace.shared.activateFileViewerSelecting([e.url]) }
        Divider()
        Button("Mover a la Papelera…", role: .destructive) { toTrash = e }
    }

    private func row(_ e: DiskEntry) -> some View {
        let frac = model.total > 0 ? Double(e.size) / Double(model.total) : 0
        return HStack(spacing: 10) {
            Image(systemName: e.isDir ? "folder.fill" : "doc")
                .foregroundStyle(e.isDir ? Color.accentColor : .secondary).frame(width: 22)
            Text(e.name).lineLimit(1).frame(minWidth: 140, alignment: .leading)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(Color.accentColor.opacity(0.75))
                        .frame(width: max(2, g.size.width * frac))
                }
            }.frame(height: 8)
            Text(String(format: "%.0f%%", frac * 100)).font(.caption).foregroundStyle(.secondary)
                .frame(width: 36, alignment: .trailing)
            Text(formatBytes(e.size)).monospacedDigit().frame(width: 80, alignment: .trailing)
        }
        .padding(.vertical, 2)
    }

    // MARK: burbujas

    private var bubbleView: some View {
        ZStack {
            GeometryReader { geo in
                let w = layout.maxX - layout.minX, h = layout.maxY - layout.minY
                if w > 0 && h > 0 {
                    let s = min(geo.size.width / w, geo.size.height / h) * 0.97
                    let ox = (geo.size.width - w * s) / 2 - layout.minX * s
                    let oy = (geo.size.height - h * s) / 2 - layout.minY * s
                    ZStack(alignment: .topLeading) {
                        ForEach(layout.bubbles) { b in
                            bubble(b, d: b.r * 2 * s)
                                .position(x: ox + b.x * s, y: oy + b.y * s)
                        }
                    }
                }
            }
            .padding(8)
            if model.scanning {
                VStack(spacing: 6) {
                    ProgressView()
                    Text("Calculando tamaños… (\(model.pending) pendientes)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(14)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private func color(for e: DiskEntry) -> Color {
        guard e.isDir else { return .gray }
        let hue = e.name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) % 360 }
        return Color(hue: Double(hue) / 360, saturation: 0.55, brightness: 0.85)
    }

    private func bubble(_ b: Bubble, d: Double) -> some View {
        let c = color(for: b.entry)
        return Circle()
            .fill(c.opacity(0.75))
            .overlay(Circle().strokeBorder(c, lineWidth: 1.5))
            .overlay {
                if d > 64 {
                    VStack(spacing: 1) {
                        Text(b.entry.name).font(.system(size: min(13, max(9, d / 9)), weight: .semibold))
                            .lineLimit(2).multilineTextAlignment(.center)
                        Text(formatBytes(b.entry.size)).font(.system(size: min(12, max(8, d / 10))))
                    }
                    .foregroundStyle(.primary)
                    .padding(d * 0.12)
                }
            }
            .frame(width: d, height: d)
            .contentShape(Circle())
            .onTapGesture { if b.entry.isDir { model.load(b.entry.url) } }
            .help("\(b.entry.name) · \(formatBytes(b.entry.size))")
            .contextMenu { menu(b.entry) }
    }
}
