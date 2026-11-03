import Foundation

struct TileKey: Hashable, Sendable {
    static let side = 256
    let level: Int
    let x: Int
    let y: Int

    func rect(in level: Level) -> PixelRect {
        let x = x * Self.side
        let y = y * Self.side
        return PixelRect(x: x, y: y, width: min(Self.side, level.width - x),
                         height: min(Self.side, level.height - y))
    }
}

struct TilePixels: Sendable {
    let width: Int
    let height: Int
    let channels: [Data]
    let footprint: CGRect
}

func visibleTiles(info: SlideInfo, viewport: Viewport) -> [TileKey] {
    let rect = viewport.visible.intersection(CGRect(x: 0, y: 0,
        width: info.base.width, height: info.base.height))
    guard !rect.isNull, !rect.isEmpty else { return [] }
    let levels = info.levels.indices
    let target = levels.last { level in
        max(info.levels[level].dx, info.levels[level].dy) * viewport.zoom <= 1.25
    } ?? 0
    for index in target..<levels.count {
        let level = info.levels[index]
        let side = Double(TileKey.side)
        let minX = Int(floor(rect.minX / level.dx / side))
        let minY = Int(floor(rect.minY / level.dy / side))
        let maxX = min((level.width - 1) / TileKey.side, Int(ceil(rect.maxX / level.dx / side)) - 1)
        let maxY = min((level.height - 1) / TileKey.side, Int(ceil(rect.maxY / level.dy / side)) - 1)
        guard minX <= maxX, minY <= maxY else { continue }
        let cols = maxX - minX + 1, rows = maxY - minY + 1
        guard cols <= 72, rows <= 72, cols * rows <= 72 else { continue }
        let cx = Double(minX + maxX) / 2
        let cy = Double(minY + maxY) / 2
        return (minY...maxY).flatMap { y in
            (minX...maxX).map { x in TileKey(level: index, x: x, y: y) }
        }.sorted { a, b in
            abs(Double(a.x) - cx) + abs(Double(a.y) - cy)
                < abs(Double(b.x) - cx) + abs(Double(b.y) - cy)
        }
    }
    return []
}

func readTile(_ reader: any SlideReader, _ key: TileKey) throws -> TilePixels {
    let level = reader.info.levels[key.level]
    let rect = key.rect(in: level)
    let channels = try reader.readPlanes(channels: Array(reader.info.channels.indices), level: key.level, rect: rect)
    return TilePixels(width: rect.width, height: rect.height, channels: channels,
        footprint: CGRect(x: Double(rect.x) * level.dx, y: Double(rect.y) * level.dy,
                          width: Double(rect.width) * level.dx, height: Double(rect.height) * level.dy))
}

func readOverview(_ reader: any SlideReader) throws -> (TilePixels, Bool) {
    let info = reader.info
    let last = info.levels.count - 1
    let level = info.levels[last]
    let bounds = CGRect(x: 0, y: 0, width: info.base.width, height: info.base.height)
    if level.width <= 512 && level.height <= 512 {
        let rect = PixelRect(x: 0, y: 0, width: level.width, height: level.height)
        let planes = try reader.readPlanes(channels: Array(info.channels.indices), level: last, rect: rect)
        return (TilePixels(width: level.width, height: level.height, channels: planes, footprint: bounds), false)
    }
    // Bound the initial work for a large non-pyramidal slide to 16×16 samples per plane.
    let width = max(1, Int((16 * Double(level.width) / Double(max(level.width, level.height))).rounded()))
    let height = max(1, Int((16 * Double(level.height) / Double(max(level.width, level.height))).rounded()))
    let planes = try info.channels.indices.map { channel -> Data in
        var data = Data(capacity: width * height * info.channels[channel].type.bytes)
        for y in 0..<height {
            for x in 0..<width {
                try Task.checkCancellation()
                let px = min(level.width - 1, (2 * x + 1) * level.width / (2 * width))
                let py = min(level.height - 1, (2 * y + 1) * level.height / (2 * height))
                data.append(try reader.read(channel: channel, level: last,
                    rect: PixelRect(x: px, y: py, width: 1, height: 1)))
            }
        }
        return data
    }
    return (TilePixels(width: width, height: height, channels: planes, footprint: bounds), true)
}

func thumbnailPixels(_ source: TilePixels, channels: [Channel]) -> TilePixels {
    let scale = max(1, Double(max(source.width, source.height)) / 144)
    guard scale > 1 else { return source }
    let width = max(1, Int(Double(source.width) / scale))
    let height = max(1, Int(Double(source.height) / scale))
    let planes = zip(source.channels, channels).map { plane, channel -> Data in
        let bytes = channel.type.bytes
        var output = Data(count: width * height * bytes)
        output.withUnsafeMutableBytes { out in
            plane.withUnsafeBytes { input in
                for row in 0..<height {
                    for col in 0..<width {
                        let src = (row * source.height / height * source.width + col * source.width / width) * bytes
                        let dest = (row * width + col) * bytes
                        out.baseAddress!.advanced(by: dest).copyMemory(from: input.baseAddress!.advanced(by: src),
                                                                      byteCount: bytes)
                    }
                }
            }
        }
        return output
    }
    return TilePixels(width: width, height: height, channels: planes, footprint: source.footprint)
}
