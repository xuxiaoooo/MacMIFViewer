import CryptoKit
import Foundation

struct Annotation: Identifiable, Codable, Sendable {
    let id: UUID
    var name: String
    var region: Region
}

struct Calibration: Codable, Equatable, Sendable {
    enum Source: String, Codable, Sendable {
        case metadata, provisionalMetadata, manual

        var label: String {
            switch self {
            case .metadata: "文件标尺"
            case .provisionalMetadata: "MRXS 文件标尺 · 待核验"
            case .manual: "手动校准"
            }
        }
    }

    let x: Double
    let y: Double
    let source: Source

    init?(x: Double?, y: Double?, source: Source) {
        guard let x, let y, (0.000001...100_000).contains(x), (0.000001...100_000).contains(y) else { return nil }
        self.x = x
        self.y = y
        self.source = source
    }

    var valid: Bool { Self(x: x, y: y, source: source) != nil }
}

struct ScaleMark: Sendable {
    let width: Double
    let label: String

    init?(zoom: Double, target: Double, calibration: Calibration?) {
        let unitsPerPoint = (calibration?.x ?? 1) / zoom
        let extent = unitsPerPoint * target
        guard extent > 0, extent.isFinite else { return nil }
        let power = pow(10, floor(log10(extent)))
        let length = ([5.0, 2, 1].first { $0 * power <= extent } ?? 1) * power
        width = length / unitsPerPoint
        let unit = calibration == nil ? "px" : length >= 1000 ? "mm" : length < 1 ? "nm" : "µm"
        let amount = unit == "mm" ? length / 1000 : unit == "nm" ? length * 1000 : length
        label = amount.formatted(.number.precision(.fractionLength(0...4))) + " " + unit
    }
}

struct Measurement: Codable, Sendable {
    let value: Double
    let unit: String

    var label: String { value.formatted(.number.precision(.fractionLength(0...3))) + " " + unit }
}

extension Region {
    func isValid(in level: Level) -> Bool {
        let count = vertices.count
        guard (kind == .polygon ? (3...512).contains(count) : count == 2),
              vertices.allSatisfy({ (0...Double(level.width)).contains($0.x) && (0...Double(level.height)).contains($0.y) })
        else { return false }
        if kind == .polygon, !isSimplePolygon { return false }
        return measurement(calibration: nil).value > 0
    }

    private var isSimplePolygon: Bool {
        func intersects(_ a: PointL0, _ b: PointL0, _ c: PointL0, _ d: PointL0) -> Bool {
            func cross(_ p: PointL0, _ q: PointL0, _ r: PointL0) -> Double {
                (q.x - p.x) * (r.y - p.y) - (q.y - p.y) * (r.x - p.x)
            }
            return max(min(a.x, b.x), min(c.x, d.x)) <= min(max(a.x, b.x), max(c.x, d.x))
                && max(min(a.y, b.y), min(c.y, d.y)) <= min(max(a.y, b.y), max(c.y, d.y))
                && cross(a, b, c) * cross(a, b, d) <= 0
                && cross(c, d, a) * cross(c, d, b) <= 0
        }
        let n = vertices.count
        for i in vertices.indices {
            let next = (i + 1) % n
            if vertices[i] == vertices[next] { return false }
            for j in vertices.indices.dropFirst(i + 2) {
                if (j + 1) % n == i { continue }
                if intersects(vertices[i], vertices[next], vertices[j], vertices[(j + 1) % n]) { return false }
            }
        }
        return true
    }

    func measurement(calibration: Calibration?) -> Measurement {
        let x = calibration?.x ?? 1, y = calibration?.y ?? 1
        if kind == .line {
            let a = vertices[0], b = vertices[1]
            return Measurement(value: hypot((a.x - b.x) * x, (a.y - b.y) * y),
                               unit: calibration == nil ? "px" : "µm")
        }
        let area: Double
        if kind == .rectangle {
            area = abs((vertices[0].x - vertices[1].x) * (vertices[0].y - vertices[1].y))
        } else {
            area = abs(vertices.indices.reduce(0) { sum, i in
                let a = vertices[i], b = vertices[(i + 1) % vertices.count]
                return sum + a.x * b.y - b.x * a.y
            }) / 2
        }
        return Measurement(value: area * x * y, unit: calibration == nil ? "px²" : "µm²")
    }
}

struct SlideSession: Codable, Sendable {
    var settings: [DisplayChannel]
    var annotations: [Annotation]
    var calibration: Calibration?
    var showScale: Bool

    static func location(for files: [URL]) -> URL? {
        guard !files.isEmpty,
              let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        var hash = SHA256()
        for file in files {
            let url = file.resolvingSymlinksInPath()
            let sources = url.pathExtension.lowercased() == "mrxs"
                ? [url, url.deletingPathExtension().appendingPathComponent("Slidedat.ini")]
                : [url]
            for source in sources {
                let values = try? source.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                hash.update(data: Data("\(source.path)\0\(values?.fileSize ?? -1)\0\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)\0".utf8))
            }
        }
        let key = hash.finalize().map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent("Mac MIF Viewer/Sessions").appendingPathComponent(key + ".json")
    }

    static func load(from url: URL) throws -> Self? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let bytes = try Data(contentsOf: url)
        guard bytes.count <= 4 << 20 else { throw SlideError.invalid("本机切片设置文件过大。") }
        return try JSONDecoder().decode(Self.self, from: bytes)
    }

    func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
}
