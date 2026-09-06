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
    var audio: AudioDiagnostics?
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
            controlServer: controlServer?.diagnosticsSnapshot(),
            audio: await engine.audioDiagnostics()
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
        if let audio = snapshot.audio {
            lines += [
                "audio.generation: \(audio.generation)",
                "audio.isRunning: \(audio.isRunning)",
                "audio.sampleRate: \(audio.sampleRate)",
                "audio.limiterDelayFrames: \(audio.limiterDelayFrames)",
                "audio.callbackCount: \(audio.callbackCount)",
                "audio.frames.last/min/max: \(audio.lastFrames)/\(audio.minFrames)/\(audio.maxFrames)",
                "audio.callbackMilliseconds.last/mean/max: \(audio.lastCallbackMilliseconds)/\(audio.meanCallbackMilliseconds)/\(audio.maxCallbackMilliseconds)",
                "audio.budgetRatio.last/mean/max: \(audio.lastBudgetRatio)/\(audio.meanBudgetRatio)/\(audio.maxBudgetRatio)",
                "audio.overBufferBudgetCount: \(audio.overBufferBudgetCount)",
                "audio.outputHostTimeEstimateSamples: \(audio.outputHostTimeEstimateSamples)",
                "audio.outputHostTimeEstimateMisses: \(audio.outputHostTimeEstimateMisses)",
                "audio.limiterInputOrGuardCallbacks: \(audio.limiterInputOrGuardCallbacks)",
                "audio.limiterInputOverCeilingCallbacks: \(audio.limiterInputOverCeilingCallbacks)",
                "audio.limiterGuardedSamples: \(audio.limiterGuardedSamples)",
                "audio.limiterRenderFailures: \(audio.limiterRenderFailures)",
                "audio.aggregateBuilds.attempts/successes/failures: \(audio.aggregateBuildAttempts)/\(audio.aggregateBuildSuccesses)/\(audio.aggregateBuildFailures)",
                "audio.buildMilliseconds.last/max: \(audio.lastBuildMilliseconds)/\(audio.maxBuildMilliseconds)",
                "audio.measurementNote: counters are estimates, not measured acoustic dropouts or end-to-end latency",
            ]
        }
        return lines.joined(separator: "\n")
    }
}
