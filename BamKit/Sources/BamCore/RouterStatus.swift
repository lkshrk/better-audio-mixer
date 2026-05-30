import Foundation

/// Why the router is not fully online. Drives cause-aware recovery: each cause
/// has a different natural trigger that will let a retry succeed, so the view
/// model can wait for the right event instead of blind-polling forever.
public enum RouterFailureCause: String, Sendable, Equatable {
    /// Fully live (or nothing to route) — not a failure.
    case ok
    /// No hardware destination and no system default output to mix into.
    /// Heals when an output device appears (device-list change).
    case noOutput
    /// Taps exist but the aggregate could not be built — almost always the
    /// audio-capture (TCC) consent not yet granted. Heals when the user accepts;
    /// that grant fires no CoreAudio list change, so only a heartbeat catches it.
    case permissionPending
    /// No grouped app is currently producing audio, so there is nothing to tap.
    /// Not an error: the devices are idle, not broken. Heals when an app starts
    /// (process-list change).
    case noSourcesRunning
    /// Aggregate build failed for some other reason. Retry with backoff.
    case buildFailed
}

/// Outcome of a `startRouter` call: which mixes could not be brought online and
/// the single dominant reason. `failedMixIDs` is empty on success and for the
/// benign `noSourcesRunning` case (idle, not offline).
public struct RouterStatus: Sendable, Equatable {
    public var failedMixIDs: [String]
    public var cause: RouterFailureCause

    public init(failedMixIDs: [String] = [], cause: RouterFailureCause = .ok) {
        self.failedMixIDs = failedMixIDs
        self.cause = cause
    }

    public static let ok = RouterStatus()

    /// True only for causes a user would see as broken. `ok` and
    /// `noSourcesRunning` are healthy/idle and must NOT show offline.
    public var isFailure: Bool {
        switch cause {
        case .ok, .noSourcesRunning: return false
        case .noOutput, .permissionPending, .buildFailed: return true
        }
    }

    /// Whether a later retry could plausibly succeed without user config changes.
    public var isRecoverable: Bool { cause != .ok }
}
