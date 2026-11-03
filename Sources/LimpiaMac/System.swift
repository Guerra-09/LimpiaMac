import Foundation
import AppKit
import UserNotifications

// MARK: - Snapshots locales de Time Machine

struct LocalSnapshot: Identifiable, Sendable {
    let stamp: String   // 2026-11-03-120000
    let date: Date?
    var id: String { stamp }
}

private let stampPattern = #"^\d{4}-\d{2}-\d{2}-\d{6}$"#

@MainActor
final class SnapshotsModel: ObservableObject {
    @Published var snapshots: [LocalSnapshot] = []
    @Published var purgeable: Int64 = 0
    @Published var loading = false
    @Published var message: String?

    /// Comando equivalente, para pegar en la Terminal.
    var command: String {
        snapshots.map { "sudo tmutil deletelocalsnapshots \($0.stamp)" }.joined(separator: " && ")
    }

    func refresh() async {
        loading = true
        let r = await runProcess("/usr/bin/tmutil", ["listlocalsnapshotdates", "/"])
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        snapshots = r.output.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.range(of: stampPattern, options: .regularExpression) != nil }
            .map { LocalSnapshot(stamp: $0, date: f.date(from: $0)) }
            .sorted { $0.stamp > $1.stamp }

        let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [
            .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
        let important = v?.volumeAvailableCapacityForImportantUsage ?? 0
        let plain = Int64(v?.volumeAvailableCapacity ?? 0)
        purgeable = max(0, important - plain)
        loading = false
    }

    func copyCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        message = "Comando copiado. Pégalo en la Terminal."
    }

    /// Borra todos los snapshots; macOS pide la contraseña de administrador.
    func deleteAll() async {
        let stamps = snapshots.map(\.stamp)
        guard !stamps.isEmpty else { return }
        loading = true
        let script = stamps.map { "/usr/bin/tmutil deletelocalsnapshots \($0)" }.joined(separator: "; ")
        let error: String? = await Task.detached {
            var err: NSDictionary?
            NSAppleScript(source: "do shell script \"\(script)\" with administrator privileges")?
                .executeAndReturnError(&err)
            return err?[NSAppleScript.errorMessage] as? String
        }.value
        message = error.map { "No se pudo: \($0)" } ?? "Snapshots eliminados."
        await refresh()
    }
}

// MARK: - Aviso de poco espacio

@MainActor
enum LowSpaceAlert {
    static var lastAlert: Date?

    static func requestAuthorization() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Avisa como máximo una vez cada 6 horas.
    static func check(_ v: Volume, thresholdGB: Int) {
        guard thresholdGB > 0, Bundle.main.bundleIdentifier != nil,
              v.free < Int64(thresholdGB) * 1_000_000_000 else { return }
        if let last = lastAlert, Date().timeIntervalSince(last) < 6 * 3600 { return }
        lastAlert = Date()
        let c = UNMutableNotificationContent()
        c.title = "Poco espacio en \(v.name)"
        c.body = "Quedan \(formatBytes(v.free)) libres. Abre LimpiaMac para liberar espacio."
        c.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "lowspace", content: c, trigger: nil))
    }
}
