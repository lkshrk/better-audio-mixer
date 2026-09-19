import BamCore
import Foundation

/// Meter sampling reads this without touching the engine actor; the actor republishes on every router or config change.
final class MeterPublication: @unchecked Sendable {
    private struct SourceSlot {
        let id: String
        let name: String
        let tap: Int?
    }

    private struct MixSlot {
        let id: String
        let name: String
        let sourceIndex: Int?
    }

    private let lock = NSLock()
    private var sources: [SourceSlot] = []
    private var mixes: [MixSlot] = []
    private var cells: RouterAtomicCells?
    private var configured = false

    func publish(config: BamConfig?, router: RouterAggregate?) {
        var sources: [SourceSlot] = []
        var mixes: [MixSlot] = []
        if let config {
            sources = config.sources.map { SourceSlot(id: $0.id, name: $0.name, tap: router?.tapIndex(sourceID: $0.id)) }
            let indexByID = Dictionary(uniqueKeysWithValues: config.sources.enumerated().map { ($0.element.id, $0.offset) })
            mixes = config.mixes.map { mix in
                MixSlot(id: mix.id, name: mix.name, sourceIndex: mix.sends.first.flatMap { indexByID[$0.source] })
            }
        }
        lock.lock()
        self.sources = sources
        self.mixes = mixes
        self.cells = router?.cells
        self.configured = config != nil
        lock.unlock()
    }

    func snapshot() -> RouterSnapshot {
        lock.lock()
        let sources = self.sources, mixes = self.mixes, cells = self.cells, configured = self.configured
        lock.unlock()
        guard configured else { return .silent }
        let floor = RMSMeter.floorDB
        var levels: [(level: Float, left: Float, right: Float)] = []
        levels.reserveCapacity(sources.count)
        let sourceMeters = sources.map { slot -> RouterSourceMeter in
            var level = floor, left = floor, right = floor
            if let cells, let tap = slot.tap {
                let meters = cells.loadMeters(tap)
                level = RMSMeter.dbFS(rms: meters.rms)
                left = RMSMeter.dbFS(rms: meters.left)
                right = RMSMeter.dbFS(rms: meters.right)
            }
            levels.append((level, left, right))
            return RouterSourceMeter(id: slot.id, name: slot.name, level: level, levelLeft: left, levelRight: right)
        }
        let mixMeters = mixes.map { slot -> MixMeter in
            // A device's level mirrors the source it groups (one source per mix).
            let cached: (level: Float, left: Float, right: Float) = slot.sourceIndex.map { levels[$0] } ?? (floor, floor, floor)
            return MixMeter(id: slot.id, name: slot.name, level: cached.level, levelLeft: cached.left, levelRight: cached.right)
        }
        return RouterSnapshot(sources: sourceMeters, mixes: mixMeters)
    }
}
