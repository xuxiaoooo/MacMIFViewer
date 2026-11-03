import Foundation
import simd

struct DisplayChannel: Codable, Equatable, Sendable {
    enum Palette: Int, CaseIterable, Codable, Sendable {
        case tint, grayscale, heat

        var label: String {
            switch self {
            case .tint: "伪彩"
            case .grayscale: "灰度"
            case .heat: "热度"
            }
        }
    }

    var palette: Palette = .tint
    var visible = true
    var color: SIMD3<Float>
    var low: Float = 0
    var high: Float
    var gamma: Float = 1
    var brightness: Float?
    let ceiling: Float

    static let brightnessRange: ClosedRange<Float> = 0...2
    var brightnessGain: Float { brightness ?? 1 }

    static func defaults(_ info: SlideInfo) -> [Self] {
        let colors: [SIMD3<Float>] = [
            [0.25, 0.48, 1], [0, 1, 0.45], [1, 0.24, 0.24], [1, 0.25, 0.88],
            [1, 0.86, 0.24], [0, 0.95, 1], [1, 1, 1], [1, 0.55, 0.2],
        ]
        return info.channels.enumerated().map { index, channel in
            Self(visible: channel.display?.visible ?? true, color: channel.display?.color ?? colors[index],
                 high: channel.type.maximum, gamma: channel.display?.gamma ?? 1, ceiling: channel.type.maximum)
        }
    }

    mutating func autoContrast8Bit(_ overview: Data) {
        guard ceiling == 255 else { return }
        // Ignore zero-valued background and leave headroom for finer pyramid levels.
        var histogram = [Int](repeating: 0, count: 256)
        for sample in overview { histogram[Int(sample)] += 1 }
        let nonzero = overview.count - histogram[0]
        guard nonzero >= 64 else { return }
        func percentile(_ fraction: Double) -> Int {
            let rank = max(1, Int(ceil(Double(nonzero) * fraction)))
            var cumulative = 0
            for level in 1..<256 {
                cumulative += histogram[level]
                if cumulative >= rank { return level }
            }
            return 255
        }
        let dark = percentile(0.20)
        let bright = percentile(0.998)
        guard bright - dark >= 4 else { return }
        low = Float(dark)
        high = min(255, Float(ceil(Double(bright) * 1.35)))
    }

    func mapped(_ sample: Float) -> SIMD3<Float> {
        let t = min(1, max(0, (sample - low) / max(1, high - low)))
        let intensity = powf(t, 1 / gamma)
        let rgb: SIMD3<Float>
        switch palette {
        case .tint: rgb = color * intensity
        case .grayscale: rgb = SIMD3(repeating: intensity)
        case .heat: rgb = simd_clamp(SIMD3(repeating: 3 * intensity) - SIMD3(0, 1, 2), .zero, .one)
        }
        let brightened = rgb * brightnessGain
        // Cap the whole color together so boosting a channel preserves its hue.
        return brightened / max(1, brightened.x, brightened.y, brightened.z)
    }
}

struct PointL0: Codable, Equatable, Sendable {
    let x: Double
    let y: Double
    var point: CGPoint { CGPoint(x: x, y: y) }

    init(_ point: CGPoint) {
        x = point.x
        y = point.y
    }
}

struct Region: Codable, Sendable {
    enum Kind: String, Codable, Sendable { case rectangle, polygon, line }
    let kind: Kind
    let vertices: [PointL0]

    func bounds(in level: Level) -> PixelRect? {
        guard kind != .line, vertices.count >= (kind == .polygon ? 3 : 2),
              vertices.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
        let x0 = Int(max(0, min(Double(level.width), floor(vertices.map(\.x).min()!))))
        let y0 = Int(max(0, min(Double(level.height), floor(vertices.map(\.y).min()!))))
        let x1 = Int(max(0, min(Double(level.width), ceil(vertices.map(\.x).max()!))))
        let y1 = Int(max(0, min(Double(level.height), ceil(vertices.map(\.y).max()!))))
        guard x1 > x0, y1 > y0 else { return nil }
        return PixelRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }
}

struct Viewport: Equatable {
    var origin: CGPoint = .zero
    var zoom: Double = 1
    var size: CGSize = .zero

    func viewPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: origin.x + point.x * zoom, y: origin.y + point.y * zoom)
    }

    func slidePoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: (point.x - origin.x) / zoom, y: (point.y - origin.y) / zoom)
    }

    var visible: CGRect {
        CGRect(origin: slidePoint(.zero), size: CGSize(width: size.width / zoom, height: size.height / zoom))
    }

    mutating func center(_ point: CGPoint) {
        origin = CGPoint(x: size.width / 2 - point.x * zoom, y: size.height / 2 - point.y * zoom)
    }

    mutating func fit(_ level: Level) {
        zoom = fitZoom(level)
        center(CGPoint(x: Double(level.width) / 2, y: Double(level.height) / 2))
    }

    func fitZoom(_ level: Level) -> Double {
        max(0.000000001, 0.96 * min(size.width / Double(level.width), size.height / Double(level.height)))
    }

    mutating func magnify(_ multiplier: Double, at point: CGPoint, level: Level) {
        let anchor = slidePoint(point)
        zoom = min(max(zoom * multiplier, fitZoom(level) * 0.45), 16)
        origin = CGPoint(x: point.x - anchor.x * zoom, y: point.y - anchor.y * zoom)
        constrain(level)
    }

    mutating func constrain(_ level: Level) {
        origin.x = min(size.width * 0.8, max(size.width * 0.2 - Double(level.width) * zoom, origin.x))
        origin.y = min(size.height * 0.8, max(size.height * 0.2 - Double(level.height) * zoom, origin.y))
    }
}
