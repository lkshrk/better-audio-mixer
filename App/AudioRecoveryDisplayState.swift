import Foundation

enum AudioRecoveryDisplayState: Equatable {
    case ok
    case recovering(reason: String, attempt: Int)
    case paused(reason: String, attempts: Int, window: String, cooldown: String)

    var isVisible: Bool {
        switch self {
        case .ok: false
        case .recovering, .paused: true
        }
    }

    var isActionable: Bool {
        switch self {
        case .paused: true
        case .ok, .recovering: false
        }
    }

    var icon: String {
        switch self {
        case .ok: "checkmark.circle.fill"
        case .recovering: "arrow.triangle.2.circlepath"
        case .paused: "exclamationmark.triangle.fill"
        }
    }

    var title: String {
        switch self {
        case .ok: "Audio healthy"
        case .recovering: "Recovering"
        case .paused: "Paused"
        }
    }

    var detail: String {
        switch self {
        case .ok:
            "No recovery activity"
        case .recovering(let reason, let attempt):
            "Attempt \(attempt): \(reason)"
        case .paused(let reason, let attempts, let window, let cooldown):
            "\(attempts) rebuilds in \(window). Cooldown \(cooldown). Last: \(reason)."
        }
    }

    var explanationTitle: String {
        switch self {
        case .ok: "Audio healthy"
        case .recovering: "Automatic recovery running"
        case .paused: "Automatic recovery paused"
        }
    }

    var explanation: String {
        switch self {
        case .ok:
            "bam is not recovering audio right now."
        case .recovering(let reason, let attempt):
            "bam is rebuilding audio routing after \(reason). Attempt \(attempt) is running."
        case .paused(_, let attempts, let window, _):
            "bam rebuilt audio routing \(attempts) times in \(window) and paused automatic recovery."
        }
    }

    var attempts: String {
        switch self {
        case .ok: "0"
        case .recovering(_, let attempt): "\(attempt)"
        case .paused(_, let attempts, let window, _): "\(attempts) in \(window)"
        }
    }

    var reason: String {
        switch self {
        case .ok: "none"
        case .recovering(let reason, _): reason
        case .paused(let reason, _, _, _): reason
        }
    }

    var cooldown: String? {
        if case .paused(_, _, _, let cooldown) = self { return cooldown }
        return nil
    }
}
