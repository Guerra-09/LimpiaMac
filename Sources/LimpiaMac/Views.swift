import SwiftUI
import AppKit

@main
struct LimpiaMacApp: App {
    init() { NSApplication.shared.setActivationPolicy(.regular) }
    var body: some Scene {
        WindowGroup("LimpiaMac") { RootView() }
            .defaultSize(width: 900, height: 620)
    }
}

enum Tab: String, CaseIterable, Identifiable {
    case clean = "Limpieza", disk = "Explorador de disco", apps = "Aplicaciones", dev = "Desarrollo", files = "Archivos"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .clean: "sparkles"
        case .disk: "chart.pie"
        case .apps: "square.grid.2x2"
        case .dev: "hammer"
        case .files: "doc.on.doc"
        }
    }
}

struct RootView: View {
    @State private var tab: Tab = .clean
    @StateObject private var cleaner = CleanerModel()
    @StateObject private var disk = DiskModel()
    @StateObject private var apps = AppsModel()
    @StateObject private var dev = DevModel()
    @StateObject private var docker = DockerModel()
    @StateObject private var bigFiles = BigFilesModel()
    @StateObject private var dups = DuplicatesModel()
    @StateObject private var volumes = VolumesModel()

    var body: some View {
        NavigationSplitView {
            List(Tab.allCases, selection: $tab) { t in
                Label(t.rawValue, systemImage: t.icon).tag(t)
            }
            .safeAreaInset(edge: .top) { volumePicker }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220)
        } detail: {
            switch tab {
            case .clean: CleanView(model: cleaner)
            case .disk: DiskView(model: disk, volume: volumes.selected)
            case .apps: AppsView(model: apps, volume: volumes.selected)
            case .dev: DevView(dev: dev, docker: docker)
            case .files: FilesView(big: bigFiles, dups: dups, volume: volumes.selected)
            }
        }
        .frame(minWidth: 780, minHeight: 520)
        .onChange(of: volumes.selectedID) { _, _ in
            let v = volumes.selected
            Task { await cleaner.setVolume(v) }
        }
    }

    private var volumePicker: some View {
        let v = volumes.selected
        return VStack(alignment: .leading, spacing: 6) {
            Picker("Disco", selection: $volumes.selectedID) {
                ForEach(volumes.volumes) { vol in
                    Label(vol.name, systemImage: vol.isInternal ? "internaldrive" : "externaldrive")
                        .tag(vol.id)
                }
            }
            .labelsHidden()
            ProgressView(value: Double(v.used), total: Double(max(1, v.total)))
            Text("\(formatBytes(v.free)) libres de \(formatBytes(v.total))")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }
}

// MARK: - Limpieza

struct CleanView: View {
    @ObservedObject var model: CleanerModel
    @State private var confirm = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            List(model.targets) { t in
                HStack(spacing: 12) {
                    Toggle("", isOn: Binding(
                        get: { model.selected.contains(t.id) },
                        set: { on in
                            if on { model.selected.insert(t.id) } else { model.selected.remove(t.id) }
                        })).labelsHidden()
                    Image(systemName: t.icon).frame(width: 24).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t.name).font(.headline)
                        Text(t.detail).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.noAccess.contains(t.id) {
                        Label("Sin acceso", systemImage: "lock").font(.caption).foregroundStyle(.orange)
                    } else if let s = model.sizes[t.id] {
                        Text(formatBytes(s)).monospacedDigit().foregroundStyle(.secondary)
                    } else if model.scanning {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("—").foregroundStyle(.tertiary)
                    }
                }
                .padding(.vertical, 4)
            }
            Divider()
            footer
        }
        .task { await model.scan() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if !model.scanning && !model.cleaning { Task { await model.scan() } }
        }
        .confirmationDialog(
            "¿Borrar ~\(formatBytes(model.selectedBytes))?",
            isPresented: $confirm, titleVisibility: .visible
        ) {
            Button("Borrar", role: .destructive) { Task { await model.clean() } }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Se borra de forma permanente el contenido de las categorías marcadas. No toca documentos, fotos ni datos de apps.")
        }
        .alert("LimpiaMac", isPresented: Binding(
            get: { model.message != nil }, set: { if !$0 { model.message = nil } })
        ) { Button("OK") {} } message: { Text(model.message ?? "") }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(model.volumeName).font(.title2.bold())
                Spacer()
                Text("\(formatBytes(model.diskFree)) libres de \(formatBytes(model.diskTotal))")
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: Double(max(0, model.diskTotal - model.diskFree)),
                         total: Double(max(1, model.diskTotal)))
            if model.isBoot && !model.hasFullDiskAccess {
                HStack {
                    Image(systemName: "lock.shield").foregroundStyle(.orange)
                    Text("Para leer la Papelera y algunos logs, da «Acceso total al disco» a LimpiaMac y reinicia la app.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Abrir ajustes") {
                        NSWorkspace.shared.open(URL(string:
                            "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
                    }.controlSize(.small)
                    Button("Reiniciar app") { relaunchApp() }.controlSize(.small)
                }
            }
        }
        .padding()
    }

    private var footer: some View {
        HStack {
            Button { Task { await model.scan() } } label: { Label("Reescanear", systemImage: "arrow.clockwise") }
                .disabled(model.scanning || model.cleaning)
            Spacer()
            if model.cleaning { ProgressView().controlSize(.small) }
            Button {
                confirm = true
            } label: {
                Label("Limpiar \(formatBytes(model.selectedBytes))", systemImage: "sparkles")
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.scanning || model.cleaning || model.selected.isEmpty)
        }
        .padding()
    }
}

