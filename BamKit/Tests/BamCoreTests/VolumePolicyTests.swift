import Testing
@testable import BamCore

@Suite struct VolumePolicyTests {
    // MARK: exit — clobber guard (bug-144)

    @Test func exitWithoutAuthorityPersistsNothing() {
        // The core regression: a session that never confirmed capture must tear
        // down without writing the saved level or touching stock.
        let action = VolumePolicy.exit(applied: false, currentDeviceLevel: 0.30, stockLevel: 0.75)
        #expect(action == .teardownOnly)
    }

    @Test func exitWithAuthoritySavesCurrentAndRestoresStock() {
        let action = VolumePolicy.exit(applied: true, currentDeviceLevel: 0.42, stockLevel: 0.75)
        #expect(action == .persist(bamLevel: 0.42, thenStock: 0.75))
    }

    @Test func exitWithAuthorityButNoStockSkipsStockReset() {
        // First-ever session: bam level gets saved, but with no recorded stock
        // level we must not invent one.
        let action = VolumePolicy.exit(applied: true, currentDeviceLevel: 0.42, stockLevel: nil)
        #expect(action == .persist(bamLevel: 0.42, thenStock: nil))
    }

    // MARK: launch

    @Test func launchWithNoSavedLevelTakesAuthorityOnly() {
        #expect(VolumePolicy.launch(savedLevel: nil) == .takeAuthorityNoChange)
    }

    @Test func launchWithSavedLevelResumesIt() {
        #expect(VolumePolicy.launch(savedLevel: 0.55) == .applySaved(0.55))
    }

    // MARK: round-trip — a completed session resumes exactly where it left off

    @Test func savedLevelRoundTripsThroughExitAndLaunch() {
        guard case let .persist(bamLevel, _) =
            VolumePolicy.exit(applied: true, currentDeviceLevel: 0.6, stockLevel: 0.9)
        else { Issue.record("expected persist"); return }
        #expect(VolumePolicy.launch(savedLevel: bamLevel) == .applySaved(0.6))
    }

    @Test func abandonedSessionDoesNotDisturbPriorSavedLevel() {
        // Prior completed session saved 0.6. This session never took authority and
        // exits → teardownOnly → saved level stays 0.6 → next launch resumes 0.6.
        let priorSaved = 0.6
        let action = VolumePolicy.exit(applied: false, currentDeviceLevel: 0.1, stockLevel: 0.9)
        #expect(action == .teardownOnly)
        #expect(VolumePolicy.launch(savedLevel: priorSaved) == .applySaved(priorSaved))
    }
}
