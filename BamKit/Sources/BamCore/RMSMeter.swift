import Foundation

public enum RMSMeter {
    public static let floorDB: Float = -120.0

    public static func rms(_ samples: UnsafeBufferPointer<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sumSquares: Float = 0
        for s in samples { sumSquares += s * s }
        return (sumSquares / Float(samples.count)).squareRoot()
    }

    public static func rms(_ samples: [Float]) -> Float {
        samples.withUnsafeBufferPointer { rms($0) }
    }

    public static func dbFS(rms: Float) -> Float {
        guard rms > 0 else { return floorDB }
        let db = 20.0 * log10(rms)
        return db.isFinite ? max(db, floorDB) : floorDB
    }

    public static func dbFS(samples: UnsafeBufferPointer<Float>) -> Float {
        dbFS(rms: rms(samples))
    }

    public static func dbFS(samples: [Float]) -> Float {
        samples.withUnsafeBufferPointer { dbFS(samples: $0) }
    }

    /// Sum source levels in linear power, return combined dBFS.
    public static func combine(_ levelsDB: [Float]) -> Float {
        let total = levelsDB.reduce(Float(0)) { acc, db in
            acc + (db <= floorDB ? 0 : pow(10.0, db / 10.0))
        }
        guard total > 0 else { return floorDB }
        let db = 10.0 * log10(total)
        return db.isFinite ? max(db, floorDB) : floorDB
    }

    public static func fraction(dbFS: Float, minDB: Float = -60.0) -> Float {
        guard dbFS > minDB else { return 0 }
        let clamped = min(dbFS, 0)
        return (clamped - minDB) / (0 - minDB)
    }
}
