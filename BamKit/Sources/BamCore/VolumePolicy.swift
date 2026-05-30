import Foundation

/// Pure decision logic for the launch/exit volume hand-off, extracted from the
/// view model so the clobber-guard invariants are unit-testable.
///
/// The hazard this guards against: a session that never took authority over the
/// device volume (capture never confirmed / restore cancelled) must NOT persist
/// the current stock/dimmed level as the bam level, nor reset to stock — doing so
/// clobbers the genuine saved level from a prior, completed session.
public enum VolumePolicy {
    /// What to do with persisted state + the device when the app exits.
    public enum ExitAction: Equatable {
        /// We never owned the volume this session: tear down only, persist nothing.
        case teardownOnly
        /// We owned it: save `bamLevel` as the resume level, then — after teardown —
        /// set the device back to `thenStock` (nil if no stock level was recorded).
        case persist(bamLevel: Double, thenStock: Double?)
    }

    /// What to do on launch once the saved state is read.
    public enum LaunchAction: Equatable {
        /// No bam level recorded yet: leave the device, but take authority so exit
        /// can save whatever level the user lands on this first session.
        case takeAuthorityNoChange
        /// Resume the saved bam level (applied only after capture readiness).
        case applySaved(Double)
    }

    public static func exit(applied: Bool,
                            currentDeviceLevel: Double,
                            stockLevel: Double?) -> ExitAction {
        guard applied else { return .teardownOnly }
        return .persist(bamLevel: currentDeviceLevel, thenStock: stockLevel)
    }

    public static func launch(savedLevel: Double?) -> LaunchAction {
        guard let saved = savedLevel else { return .takeAuthorityNoChange }
        return .applySaved(saved)
    }
}
