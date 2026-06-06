import BamCore
import BamControlKit
import Foundation

struct ConsoleDiagnostics: Equatable {
    var driverEnabled: Bool
    var routerCause: RouterFailureCause
    var failedMixIDs: [String]
    var audioRecoveryState: AudioRecoveryDisplayState
    var boundOutputUID: String?
    var selectedOutputUID: String?
    var outputDeviceCount: Int
    var runningAppCount: Int
    var mixCount: Int
    var sourceCount: Int
    var configPath: String?
    var controlServer: ControlServerDiagnostics?
}

extension ConsoleViewModel {
    func diagnosticsSnapshot() async -> ConsoleDiagnostics {
        ConsoleDiagnostics(
            driverEnabled: driverEnabled,
            routerCause: routerStatus.cause,
            failedMixIDs: Array(failedMixIDs).sorted(),
            audioRecoveryState: audioRecoveryDisplayState,
            boundOutputUID: await engine.boundOutputUID(),
            selectedOutputUID: systemOutputUID,
            outputDeviceCount: outputDevices.count,
            runningAppCount: runningApps.count,
            mixCount: config.mixes.count,
            sourceCount: config.sources.count,
            configPath: configURL?.path,
            controlServer: controlServer?.diagnosticsSnapshot()
        )
    }

    func diagnosticsReport() async -> String {
        let snapshot = await diagnosticsSnapshot()
        var lines: [String] = [
            "bam diagnostics",
            "driverEnabled: \(snapshot.driverEnabled)",
            "routerCause: \(snapshot.routerCause.rawValue)",
            "failedMixIDs: \(snapshot.failedMixIDs.isEmpty ? "none" : snapshot.failedMixIDs.joined(separator: ","))",
            "audioRecoveryState: \(snapshot.audioRecoveryState.reason)",
            "boundOutputUID: \(snapshot.boundOutputUID ?? "none")",
            "selectedOutputUID: \(snapshot.selectedOutputUID ?? "none")",
            "outputDeviceCount: \(snapshot.outputDeviceCount)",
            "runningAppCount: \(snapshot.runningAppCount)",
            "mixCount: \(snapshot.mixCount)",
            "sourceCount: \(snapshot.sourceCount)",
            "configPath: \(snapshot.configPath ?? "none")",
        ]
        if let control = snapshot.controlServer {
            lines.append("control.isListening: \(control.isListening)")
            lines.append("control.activeClients: \(control.activeClients)")
            lines.append("control.acceptedClients: \(control.acceptedClients)")
            lines.append("control.malformedFrames: \(control.malformedFrames)")
            lines.append("control.sendFailures: \(control.sendFailures)")
        }
        return lines.joined(separator: "\n")
    }
}
