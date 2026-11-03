import SwiftUI
import AppKit

struct SystemView: View {
    @ObservedObject var model: SnapshotsModel
    @ObservedObject var memory: MemoryModel
    @ObservedObject var schedule: ScheduleModel
    @State private var confirm = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ScheduleCard(schedule: schedule)
                MemoryCard(model: memory)
                Divider()
                Label("Time Machine · snapshots locales", systemImage: "clock.arrow.circlepath")
                    .font(.title3.bold())
                Text("macOS guarda copias locales del disco aunque no tengas el disco de Time Machine conectado. Las borra solo cuando falta espacio, pero si tu System Data está inflado puedes eliminarlas a mano.")
                    .font(.callout).foregroundStyle(.secondary)

                GroupBox {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Espacio purgable").font(.caption).foregroundStyle(.secondary)
                            Text(formatBytes(model.purgeable)).font(.title2.monospacedDigit())
                        }
                        Spacer()
                        Text("Incluye snapshots y cachés que macOS libera si lo necesita. No se puede medir cada snapshot por separado.")
                            .font(.caption).foregroundStyle(.secondary).frame(maxWidth: 320, alignment: .trailing)
                    }.padding(6)
                }

                if model.snapshots.isEmpty {
                    Text(model.loading ? "Buscando…" : "No hay snapshots locales.")
                        .foregroundStyle(.secondary)
                } else {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(model.snapshots) { s in
                                HStack {
                                    Image(systemName: "clock").foregroundStyle(.secondary)
                                    Text(s.date.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? s.stamp)
                                    Spacer()
                                    Text(s.stamp).font(.caption.monospaced()).foregroundStyle(.secondary)
                                }
                            }
                        }.padding(6)
                    }
                    HStack {
                        Button(role: .destructive) { confirm = true } label: {
                            Label("Eliminar todos…", systemImage: "trash")
                        }.disabled(model.loading)
                        Button { model.copyCommand() } label: {
                            Label("Copiar comando para la Terminal", systemImage: "doc.on.clipboard")
                        }
                    }
                    Text("Se pedirá tu contraseña de administrador. Esto solo quita puntos de restauración locales; tus backups en el disco de Time Machine no se tocan.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                HStack {
                    Button { Task { await model.refresh() } } label: { Label("Refrescar", systemImage: "arrow.clockwise") }
                    if model.loading { ProgressView().controlSize(.small) }
                }
            }
            .padding(20)
        }
        .task { await model.refresh() }
        .confirmationDialog("¿Eliminar \(model.snapshots.count) snapshots locales?",
                            isPresented: $confirm, titleVisibility: .visible) {
            Button("Eliminar", role: .destructive) { Task { await model.deleteAll() } }
            Button("Cancelar", role: .cancel) {}
        } message: { Text("No se puede deshacer. macOS te pedirá la contraseña.") }
        .alert("LimpiaMac", isPresented: Binding(
            get: { model.message != nil }, set: { if !$0 { model.message = nil } })
        ) { Button("OK") {} } message: { Text(model.message ?? "") }
    }
}

// MARK: - Menú de la barra superior

struct MenuBarLabel: View {
    @ObservedObject var volumes: VolumesModel
    var body: some View {
        let boot = volumes.volumes.first { $0.isBoot }
        HStack(spacing: 4) {
            Image(systemName: "internaldrive")
            if let boot { Text(formatBytes(boot.free)) }
        }
    }
}

struct MenuBarView: View {
    @ObservedObject var volumes: VolumesModel
    @ObservedObject var memory: MemoryModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(volumes.volumes) { v in
                VStack(alignment: .leading, spacing: 3) {
                    Label(v.name, systemImage: v.isInternal ? "internaldrive" : "externaldrive").font(.headline)
                    ProgressView(value: Double(v.used), total: Double(max(1, v.total)))
                    Text("\(formatBytes(v.free)) libres de \(formatBytes(v.total))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Divider()
            MemoryCard(model: memory, compact: true)
            Divider()
            Picker("Avisar si quedan menos de", selection: $volumes.alertGB) {
                Text("No avisar").tag(0)
                Text("5 GB").tag(5)
                Text("10 GB").tag(10)
                Text("20 GB").tag(20)
                Text("50 GB").tag(50)
            }
            HStack {
                Button("Abrir LimpiaMac") {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                Spacer()
                Button("Salir") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 320)
    }
}
