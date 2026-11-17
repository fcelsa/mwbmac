// Schema della disposizione Mac/PC per le impostazioni: mostra da che parte sta il PC,
// il tratto del bordo che porta al PC e, se esclusi, gli angoli.

import MWBEdgeLogic
import SwiftUI

struct EdgeDiagram: View {
    let edge: ScreenEdge
    let range: ClosedRange<Double>
    let blockCorners: Bool

    /// Quota illustrativa degli angoli esclusi (100 punti su uno schermo di circa 1000).
    private static let cornerFraction = 0.1

    var body: some View {
        Canvas { context, size in
            let (mac, pc) = layout(in: size)
            let screenShape = Path(roundedRect: mac, cornerRadius: 6)
            context.fill(screenShape, with: .color(.secondary.opacity(0.15)))
            context.stroke(screenShape, with: .color(.secondary.opacity(0.6)), lineWidth: 1.5)
            let pcShape = Path(roundedRect: pc, cornerRadius: 6)
            context.fill(pcShape, with: .color(.accentColor.opacity(0.12)))
            context.stroke(pcShape, with: .color(.accentColor.opacity(0.7)), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))

            context.draw(Text(verbatim: "Mac").font(.headline).foregroundColor(.secondary), at: CGPoint(x: mac.midX, y: mac.midY))
            context.draw(Text(verbatim: "PC").font(.headline).foregroundColor(.accentColor), at: CGPoint(x: pc.midX, y: pc.midY))

            // Bordo verso il PC: tratto attivo in evidenza, angoli esclusi in rosso.
            context.stroke(segment(of: mac, from: 0, to: 1), with: .color(.secondary.opacity(0.4)), lineWidth: 2)
            context.stroke(segment(of: mac, from: range.lowerBound, to: range.upperBound),
                           with: .color(.accentColor), style: StrokeStyle(lineWidth: 5, lineCap: .round))
            if blockCorners {
                let c = EdgeDiagram.cornerFraction
                for (from, to) in [(0.0, c), (1 - c, 1.0)] {
                    context.stroke(segment(of: mac, from: from, to: to), with: .color(.red.opacity(0.8)),
                                   style: StrokeStyle(lineWidth: 5, lineCap: .butt))
                }
            }
        }
        .frame(height: 140)
        .accessibilityElement()
        .accessibilityLabel(L("Arrangement of the Mac and the PC"))
    }

    private func layout(in size: CGSize) -> (mac: CGRect, pc: CGRect) {
        let gap: CGFloat = 14
        let height = size.height - 8
        switch edge {
        case .left, .right:
            let mac = CGSize(width: height * 1.5, height: height)
            let pc = CGSize(width: height * 1.1, height: height * 0.72)
            let total = mac.width + gap + pc.width
            let originX = (size.width - total) / 2
            let macX = edge == .right ? originX : originX + pc.width + gap
            let pcX = edge == .right ? originX + mac.width + gap : originX
            return (CGRect(x: macX, y: 4, width: mac.width, height: mac.height),
                    CGRect(x: pcX, y: 4 + (mac.height - pc.height) / 2, width: pc.width, height: pc.height))
        case .top, .bottom:
            let macHeight = (height - gap) * 0.58
            let pcHeight = height - gap - macHeight
            let mac = CGSize(width: macHeight * 1.6, height: macHeight)
            let pc = CGSize(width: mac.width * 0.75, height: pcHeight)
            let macY = edge == .bottom ? 4 : 4 + pcHeight + gap
            let pcY = edge == .bottom ? 4 + macHeight + gap : 4
            return (CGRect(x: (size.width - mac.width) / 2, y: macY, width: mac.width, height: mac.height),
                    CGRect(x: (size.width - pc.width) / 2, y: pcY, width: pc.width, height: pc.height))
        }
    }

    /// Tratto del bordo del Mac verso il PC, da `from` a `to` (0…1: dall'alto in basso
    /// per i bordi laterali, da sinistra a destra per quelli orizzontali, come `EdgeDetector`).
    private func segment(of rect: CGRect, from: Double, to: Double) -> Path {
        var path = Path()
        switch edge {
        case .left, .right:
            let x = edge == .right ? rect.maxX : rect.minX
            path.move(to: CGPoint(x: x, y: rect.minY + rect.height * from))
            path.addLine(to: CGPoint(x: x, y: rect.minY + rect.height * to))
        case .top, .bottom:
            let y = edge == .bottom ? rect.maxY : rect.minY
            path.move(to: CGPoint(x: rect.minX + rect.width * from, y: y))
            path.addLine(to: CGPoint(x: rect.minX + rect.width * to, y: y))
        }
        return path
    }
}
