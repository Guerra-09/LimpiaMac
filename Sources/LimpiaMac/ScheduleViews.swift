import SwiftUI
import AppKit
import ServiceManagement

struct ScheduleCard: View {
    @ObservedObject var schedule: ScheduleModel
    @State private var confirmRun = false
    @State private var loginOn = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Label("Limpieza automática", systemImage: "calendar.badge.clock").font(.headline)
                Toggle("Limpiar automáticamente", isOn: $schedule.enabled)
                Picker("Frecuencia", selection: $schedule.intervalDays) {
                    Text("Cada día").tag(1)
                    Text("Cada semana").tag(7)
                    Text("Cada mes").tag(30)
                }
                .fixedSize().disabled(!schedule.enabled)
                DisclosureGroup("Qué se limpia") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(CleanTarget.all) { t in
                            Toggle(isOn: Binding(
                                get: { schedule.ids.contains(t.id) },
                                set: { on in if on { schedule.ids.insert(t.id) } else { schedule.ids.remove(t.id) } }
                            )) {
                                Text(t.id == "trash" ? "\(t.name) (borra de forma permanente)" : t.name)
                            }
                        }
                    }.padding(.top, 4)
                }
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Última: " + (schedule.lastRun.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "nunca"))
                        if let n = schedule.nextRun {
                            Text("Próxima: " + n.formatted(date: .abbreviated, time: .shortened))
                        }
                        if let r = schedule.lastResult { Text(r).foregroundStyle(.green) }
                    }.font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if schedule.running { ProgressView().controlSize(.small) }
                    Button("Ejecutar ahora") { confirmRun = true }
                        .disabled(schedule.running || schedule.ids.isEmpty)
                }
                Divider()
                Toggle("Abrir LimpiaMac al iniciar sesión", isOn: $loginOn)
                    .onChange(of: loginOn) { _, on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                            loginError = nil
                        } catch {
                            loginError = error.localizedDescription
                            loginOn = SMAppService.mainApp.status == .enabled
                        }
                    }
                if let e = loginError { Text(e).font(.caption).foregroundStyle(.orange) }
                Text("La limpieza automática solo corre mientras LimpiaMac está abierta (queda en la barra superior). Si Xcode está abierto, no toca DerivedData.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(6)
        }
        .confirmationDialog("¿Ejecutar la limpieza ahora?", isPresented: $confirmRun, titleVisibility: .visible) {
            Button("Ejecutar", role: .destructive) { Task { await schedule.run(auto: false) } }
            Button("Cancelar", role: .cancel) {}
        } message: { Text("Se borra de forma permanente el contenido de las categorías marcadas.") }
    }
}

struct MemoryCard: View {
    @ObservedObject var model: MemoryModel
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Memoria", systemImage: "memorychip").font(compact ? .headline : .title3.bold())
            ProgressView(value: Double(model.used), total: Double(max(1, model.total)))
                .tint(Double(model.used) / Double(max(1, model.total)) > 0.85 ? .orange : .accentColor)
            Text("\(formatBytes(model.used)) en uso de \(formatBytes(model.total))")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(model.apps.prefix(compact ? 6 : 12)) { a in
                HStack(spacing: 8) {
                    if let p = a.path {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: p)).resizable().frame(width: 18, height: 18)
                    } else {
                        Image(systemName: "gearshape").frame(width: 18).foregroundStyle(.secondary)
                    }
                    Text(a.name).lineLimit(1)
                    Spacer()
                    Text(formatBytes(a.bytes)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    if a.canQuit {
                        Button("Cerrar") { model.quit(a) }
                            .controlSize(.small)
                            .contextMenu { Button("Forzar cierre") { model.quit(a, force: true) } }
                    }
                }
            }
            if !compact {
                Text("Cifras aproximadas: las apps con varios procesos (navegadores) se suman. «Cerrar» pide a la app que se cierre; clic derecho para forzar. macOS gestiona la RAM solo: cerrar apps que no usas es lo único que ayuda de verdad.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }
}
