import Foundation

struct Bubble: Identifiable, Sendable {
    let entry: DiskEntry
    var x: Double
    var y: Double
    var r: Double
    var id: URL { entry.url }
}

struct BubbleLayout: Sendable {
    var bubbles: [Bubble] = []
    var minX = 0.0, maxX = 0.0, minY = 0.0, maxY = 0.0
    static let empty = BubbleLayout()
}

/// Empaqueta círculos (area ∝ tamaño) lo más cerca posible del centro.
/// `entries` debe venir ordenado de mayor a menor.
func packBubbles(_ entries: [DiskEntry], limit: Int = 45) -> BubbleLayout {
    let items = Array(entries.filter { $0.size > 0 }.prefix(limit))
    guard let maxSize = items.first?.size, maxSize > 0 else { return .empty }

    var placed: [Bubble] = []
    let gap = 0.03
    for e in items {
        let r = max(0.14, (Double(e.size) / Double(maxSize)).squareRoot())
        if placed.isEmpty {
            placed.append(Bubble(entry: e, x: 0, y: 0, r: r))
            continue
        }
        var pos: (Double, Double) = (0, 0)
        var d = 0.0
        search: while d < 200 {
            var a = 0.0
            while a < 2 * Double.pi {
                let x = d * cos(a), y = d * sin(a)
                if placed.allSatisfy({ hypot($0.x - x, $0.y - y) >= $0.r + r + gap }) {
                    pos = (x, y)
                    break search
                }
                a += 0.2
            }
            d += 0.05
        }
        placed.append(Bubble(entry: e, x: pos.0, y: pos.1, r: r))
    }

    var l = BubbleLayout(bubbles: placed)
    l.minX = placed.map { $0.x - $0.r }.min() ?? 0
    l.maxX = placed.map { $0.x + $0.r }.max() ?? 0
    l.minY = placed.map { $0.y - $0.r }.min() ?? 0
    l.maxY = placed.map { $0.y + $0.r }.max() ?? 0
    return l
}
