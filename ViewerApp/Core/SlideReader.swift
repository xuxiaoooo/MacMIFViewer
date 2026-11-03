import Foundation

enum SlideError: LocalizedError {
    case invalid(String)

    var errorDescription: String? {
        switch self { case .invalid(let message): message }
    }
}

enum PixelType: String, Codable, Sendable {
    case uint8, uint16
    var bytes: Int { self == .uint8 ? 1 : 2 }
    var maximum: Float { self == .uint8 ? 255 : 65_535 }
}

struct PixelRect: Codable, Hashable, Sendable {
    let x: Int
    let y: Int
    let width: Int
    let height: Int

    func within(_ level: Level) -> Bool {
        x >= 0 && y >= 0 && width > 0 && height > 0
            && x < level.width && y < level.height
            && width <= level.width - x && height <= level.height - y
    }
}

struct Level: Equatable, Sendable {
    let width: Int
    let height: Int
    let dx: Double
    let dy: Double
}

struct ChannelDisplay: Sendable {
    let color: SIMD3<Float>?
    let gamma: Float
    let visible: Bool
}

struct Channel: Sendable {
    let name: String
    let source: String
    let type: PixelType
    var display: ChannelDisplay? = nil
}

struct SlideInfo: Sendable {
    let title: String
    let mode: String
    let levels: [Level]
    let channels: [Channel]
    let mppX: Double?
    let mppY: Double?
    var base: Level { levels[0] }
}

protocol SlideReader: AnyObject, Sendable {
    var info: SlideInfo { get }
    var supportsRawExport: Bool { get }
    func read(channel: Int, level: Int, rect: PixelRect) throws -> Data
    func readPlanes(channels: [Int], level: Int, rect: PixelRect) throws -> [Data]
}

extension SlideReader {
    var supportsRawExport: Bool { true }

    func readPlanes(channels: [Int], level: Int, rect: PixelRect) throws -> [Data] {
        try channels.map {
            try Task.checkCancellation()
            return try read(channel: $0, level: level, rect: rect)
        }
    }
}

func validateRead(_ info: SlideInfo, channel: Int, level: Int, rect: PixelRect) throws {
    guard info.levels.indices.contains(level), info.channels.indices.contains(channel),
          rect.width <= 512, rect.height <= 512, rect.within(info.levels[level]) else {
        throw SlideError.invalid("读取区域或通道超出边界。")
    }
}

final class SyntheticReader: SlideReader {
    let info = SlideInfo(
        title: "六通道演示切片", mode: "合成演示",
        levels: [1, 2, 4, 8, 16].map {
            Level(width: 4096 / $0, height: 3072 / $0, dx: Double($0), dy: Double($0))
        },
        channels: (0..<6).map { Channel(name: "演示通道 \($0 + 1)", source: "Synthetic", type: .uint16) },
        mppX: 0.325, mppY: 0.325
    )

    static func value(channel: Int, x: Int, y: Int) -> UInt16 {
        let centerX = 750 + (channel % 3) * 1280
        let centerY = 780 + (channel / 3) * 1320
        let dx = x - centerX
        let dy = y - centerY
        let radius = 790 * 790
        let envelope = max(0, radius - dx * dx - dy * dy)
        let cell = ((x + channel * 15) % 51 - 25, (y + channel * 27) % 49 - 24)
        let dot = cell.0 * cell.0 + cell.1 * cell.1 < 95
        let wave = (x * (channel + 3) + y * (channel + 5)) % 181
        return UInt16(min(65535, envelope / 19 * (dot ? 2 : 1) + wave * 4))
    }

    func read(channel: Int, level: Int, rect: PixelRect) throws -> Data {
        try validateRead(info, channel: channel, level: level, rect: rect)
        let step = Int(info.levels[level].dx)
        var result = Data(count: rect.width * rect.height * 2)
        result.withUnsafeMutableBytes { bytes in
            let pixels = bytes.bindMemory(to: UInt16.self)
            for row in 0..<rect.height {
                for col in 0..<rect.width {
                    pixels[row * rect.width + col] = Self.value(
                        channel: channel, x: (rect.x + col) * step, y: (rect.y + row) * step)
                }
            }
        }
        return result
    }
}
