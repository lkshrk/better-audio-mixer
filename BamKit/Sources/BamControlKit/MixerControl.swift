import BamCore
import Foundation

// MARK: - Wire snapshot types

/// Full snapshot of one mix as served on the wire.
public struct MixSnapshot: Sendable, Equatable {
    public let id: String
    public let name: String
    public let emoji: String
    public let pos: Double      // perceptual position 0…1 (AudioTaper)
    public let pct: Int         // pos * 100, rounded
    public let muted: Bool
    public let level: Float     // raw dBFS

    public init(id: String, name: String, emoji: String,
                pos: Double, pct: Int, muted: Bool, level: Float) {
        self.id = id
        self.name = name
        self.emoji = emoji
        self.pos = pos
        self.pct = pct
        self.muted = muted
        self.level = level
    }
}

/// Full snapshot of the master as served on the wire.
public struct MasterSnapshot: Sendable, Equatable {
    public let pos: Double      // 0…1 (linear — hardware scalar already perceptual)
    public let pct: Int
    public let muted: Bool
    public let level: Float     // raw dBFS
    public let icon: String     // SF Symbol name of the current output device (app's icon)

    public init(pos: Double, pct: Int, muted: Bool, level: Float, icon: String = "hifispeaker.fill") {
        self.pos = pos
        self.pct = pct
        self.muted = muted
        self.level = level
        self.icon = icon
    }
}

/// One selectable hardware output as served on the wire.
public struct OutputSnapshot: Sendable, Equatable {
    public let uid: String
    public let name: String
    public let active: Bool
    /// SF Symbol matching the hardware (same logic the app's UI uses), so remote
    /// controllers render an icon identical to the console.
    public let icon: String

    public init(uid: String, name: String, active: Bool, icon: String = "hifispeaker.fill") {
        self.uid = uid
        self.name = name
        self.active = active
        self.icon = icon
    }
}

/// Point-in-time view the ControlServer reads from the model.
public struct ControlSnapshot: Sendable, Equatable {
    public let mixes: [MixSnapshot]
    public let master: MasterSnapshot

    public init(mixes: [MixSnapshot], master: MasterSnapshot) {
        self.mixes = mixes
        self.master = master
    }
}

// MARK: - Protocol

/// The abstraction the ControlServer drives. Implemented by ConsoleViewModel (live)
/// and MockMixerControl (tests). All methods run on @MainActor because the live
/// implementation stores state on the main actor.
@MainActor
public protocol MixerControl: AnyObject {
    // MARK: Snapshot
    var controlSnapshot: ControlSnapshot { get }

    // MARK: Per-mix mutators
    func setPos(mixID: String, pos: Double)
    func nudgePos(mixID: String, delta: Double)
    func setMuted(mixID: String, muted: Bool)
    func toggleMuted(mixID: String)

    // MARK: Master mutators
    func setMasterPos(pos: Double)
    func nudgeMasterPos(delta: Double)
    func setMasterMuted(muted: Bool)

    // MARK: Queries
    func listMixes() -> [MixSnapshot]

    // MARK: Output selection
    func listOutputs() -> [OutputSnapshot]
    /// Returns true if the switch was applied. v2 returns false (unsupported until v3).
    func setOutputDevice(uid: String) -> Bool
}
