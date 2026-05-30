import BamCore
import SwiftUI

struct MeterBar: View {
    let level: Float

    var body: some View {
        GeometryReader { geo in
            let frac = CGFloat(RMSMeter.fraction(dbFS: level))
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(color(frac))
                    .frame(width: max(2, geo.size.width * frac))
            }
        }
        .frame(height: 8)
        .animation(.linear(duration: 0.08), value: level)
    }

    private func color(_ frac: CGFloat) -> Color {
        switch frac {
        case ..<0.7: return .green
        case ..<0.9: return .yellow
        default: return .red
        }
    }
}
