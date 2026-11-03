import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers
import simd

enum ExportFormat: String, CaseIterable, Identifiable, Sendable {
    case raw = "Raw OME-TIFF"
    case renderedTiff = "Rendered TIFF"
    case renderedPNG = "Rendered PNG"
    case renderedJPEG = "Rendered JPEG"
    var id: String { rawValue }
}

private struct ExportMetadata: Codable {
    let region: Region
    let annotationName: String?
    let calibration: Calibration?
    let measurement: Measurement
    let renderedScaleBar: String?
    let boundingBox: PixelRect
    let pixelSizeXUm: Double?
    let pixelSizeYUm: Double?
    let channelNames: [String]
    let pixelTypes: [PixelType]
    let display: [DisplayChannel]?
    let soloChannelIndex: Int?
    let format: String
    let sourceMode: String
    let pixelPolicy: String
}

enum ROIExporter {
    private static let tileSize = 256

    static func export(reader: any SlideReader, region: Region, format: ExportFormat,
                       settings: [DisplayChannel], solo: Int?, destination: URL,
                       annotationName: String? = nil, calibration: Calibration? = nil, includeScale: Bool = false,
                       progress: @Sendable (Double) -> Void = { _ in }) throws {
        let info = reader.info
        guard let roi = region.bounds(in: info.base), region.isValid(in: info.base),
              settings.count == info.channels.count,
              solo.map(info.channels.indices.contains) ?? true else {
            throw SlideError.invalid("请先完成一个有效的 ROI。")
        }
        if format == .raw, !reader.supportsRawExport {
            throw SlideError.invalid("此 MRXS 的通道和坐标尚未通过厂商对照，仅支持预览导出。")
        }
        if format == .raw, Set(info.channels.map(\.type)).count != 1 {
            throw SlideError.invalid("原始 OME-TIFF 需要相同位深的通道。当前切片含混合位深。")
        }
        if format == .renderedPNG || format == .renderedJPEG {
            guard roi.width <= 8192, roi.height <= 8192, roi.width * roi.height <= 12_000_000 else {
                throw SlideError.invalid("PNG/JPEG 的 ROI 上限是 1200 万像素且单边不超过 8192。更大的区域请使用分块 TIFF。")
            }
        }
        let scale = calibration ?? Calibration(x: info.mppX, y: info.mppY,
            source: reader.supportsRawExport ? .metadata : .provisionalMetadata)
        let stamp = try includeScale && format != .raw ? ExportScale(roi: roi, calibration: scale) : nil
        let fm = FileManager.default
        let destination = destination.standardizedFileURL
        let parent = destination.deletingLastPathComponent()
        let temporary = parent.appendingPathComponent(".MacMIF-\(UUID().uuidString)", isDirectory: true)
        guard !fm.fileExists(atPath: destination.path) else {
            throw SlideError.invalid("导出目录已存在。请使用新名称。")
        }
        try fm.createDirectory(at: temporary, withIntermediateDirectories: false,
                               attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: temporary) }
        switch format {
        case .raw, .renderedTiff:
            let name = format == .raw ? "raw.ome.tiff" : "rendered.tiff"
            try writeTiff(reader, roi, format, settings, solo, temporary.appendingPathComponent(name), stamp, progress)
        case .renderedPNG, .renderedJPEG:
            let type: UTType = format == .renderedJPEG ? .jpeg : .png
            let name = format == .renderedJPEG ? "rendered.jpeg" : "rendered.png"
            try writeRaster(reader, roi, settings, solo, temporary.appendingPathComponent(name), type, stamp, progress)
        }
        let metadata = ExportMetadata(
            region: region, annotationName: annotationName, calibration: scale,
            measurement: region.measurement(calibration: scale), renderedScaleBar: stamp?.label,
            boundingBox: roi, pixelSizeXUm: info.mppX, pixelSizeYUm: info.mppY,
            channelNames: info.channels.map(\.name), pixelTypes: info.channels.map(\.type),
            display: format == .raw ? nil : settings, soloChannelIndex: format == .raw ? nil : solo,
            format: format.rawValue, sourceMode: info.mode,
            pixelPolicy: reader.supportsRawExport
                ? "Level-0 bounding rectangle. Pixel coordinates are top-left, zero-based. Polygon vertices are stored separately."
                : "Rendered preview of the MRXS candidate grid. Channel slots and coordinates are unverified. Unscanned tiles are black."
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(metadata).write(to: temporary.appendingPathComponent("roi.json"), options: .atomic)
        let vertices = region.vertices.enumerated().map { index, point in
            "\(index),\(point.x),\(point.y)"
        }.joined(separator: "\n")
        try Data("vertex,x_l0,y_l0\n\(vertices)\n".utf8)
            .write(to: temporary.appendingPathComponent("roi.csv"), options: .atomic)
        try Task.checkCancellation()
        try fm.moveItem(at: temporary, to: destination)
        progress(1)
    }

    private static func tiles(_ roi: PixelRect, _ body: (Int, Int, PixelRect) throws -> Void) throws {
        for y in stride(from: 0, to: roi.height, by: tileSize) {
            for x in stride(from: 0, to: roi.width, by: tileSize) {
                try Task.checkCancellation()
                try body(x, y, PixelRect(x: roi.x + x, y: roi.y + y, width: min(tileSize, roi.width - x),
                                        height: min(tileSize, roi.height - y)))
            }
        }
    }

    private static func writeTiff(_ reader: any SlideReader, _ roi: PixelRect, _ format: ExportFormat,
                                  _ settings: [DisplayChannel], _ solo: Int?, _ url: URL, _ stamp: ExportScale?,
                                  _ progress: @Sendable (Double) -> Void) throws {
        guard let file = url.withUnsafeFileSystemRepresentation({ $0.flatMap { mf_tiff_create($0) } }) else {
            throw SlideError.invalid("无法创建 TIFF。")
        }
        defer { mf_tiff_close(file) }
        let raw = format == .raw
        let count = raw ? reader.info.channels.count : 1
        let bytesPerPixel = raw ? reader.info.channels[0].type.bytes : 3
        let xml = raw ? omeXML(reader.info, roi) : ""
        let total = Double((roi.width + tileSize - 1) / tileSize)
            * Double((roi.height + tileSize - 1) / tileSize) * Double(count)
        var done: Double = 0
        for channel in 0..<count {
            let begin = xml.withCString { desc in
                mf_tiff_begin(file, UInt32(roi.width), UInt32(roi.height), raw ? UInt16(bytesPerPixel * 8) : 8,
                              raw ? 1 : 3, raw && channel == 0 ? desc : nil,
                              reader.supportsRawExport ? reader.info.mppX ?? 0 : 0,
                              reader.supportsRawExport ? reader.info.mppY ?? 0 : 0)
            }
            guard begin != 0 else { throw SlideError.invalid("无法写入 TIFF 元数据。") }
            try tiles(roi) { x, y, rect in
                var packed = try raw ? reader.read(channel: channel, level: 0, rect: rect)
                    : composite(reader, rect, settings, solo)
                stamp?.apply(to: &packed, x: x, y: y, width: rect.width, height: rect.height)
                var padded = Data(count: tileSize * tileSize * bytesPerPixel)
                copyRows(packed, to: &padded, sourceWidth: rect.width, height: rect.height,
                         destinationWidth: tileSize, x: 0, y: 0, bytesPerPixel: bytesPerPixel)
                let size = padded.count
                let written = padded.withUnsafeMutableBytes {
                    mf_tiff_write(file, UInt32(x), UInt32(y), $0.baseAddress, size)
                }
                guard written != 0 else { throw SlideError.invalid("TIFF tile 写入失败。") }
                done += 1
                if Int(done) % 16 == 0 { progress(done / total) }
            }
            guard mf_tiff_finish(file) != 0 else { throw SlideError.invalid("TIFF 通道目录写入失败。") }
        }
    }

    private static func writeRaster(_ reader: any SlideReader, _ roi: PixelRect,
                                    _ settings: [DisplayChannel], _ solo: Int?, _ url: URL, _ type: UTType,
                                    _ stamp: ExportScale?, _ progress: @Sendable (Double) -> Void) throws {
        var rgb = Data(count: roi.width * roi.height * 3)
        var pixels = 0
        try tiles(roi) { x, y, rect in
            var packed = try composite(reader, rect, settings, solo)
            stamp?.apply(to: &packed, x: x, y: y, width: rect.width, height: rect.height)
            copyRows(packed, to: &rgb, sourceWidth: rect.width, height: rect.height,
                     destinationWidth: roi.width, x: x, y: y, bytesPerPixel: 3)
            pixels += rect.width * rect.height
            progress(Double(pixels) / Double(roi.width * roi.height))
        }
        try Task.checkCancellation()
        let properties = type == .jpeg ? [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary : nil
        guard let image = rgbImage(rgb, width: roi.width, height: roi.height),
              let encoder = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw SlideError.invalid("无法创建渲染图像。")
        }
        CGImageDestinationAddImage(encoder, image, properties)
        guard CGImageDestinationFinalize(encoder) else { throw SlideError.invalid("渲染图像写入失败。") }
    }

    private static func copyRows(_ from: Data, to target: inout Data, sourceWidth: Int, height: Int,
                                 destinationWidth: Int, x: Int, y: Int, bytesPerPixel: Int) {
        target.withUnsafeMutableBytes { out in
            from.withUnsafeBytes { input in
                for row in 0..<height {
                    let dest = ((y + row) * destinationWidth + x) * bytesPerPixel
                    let start = row * sourceWidth * bytesPerPixel
                    out.baseAddress!.advanced(by: dest).copyMemory(
                        from: input.baseAddress!.advanced(by: start), byteCount: sourceWidth * bytesPerPixel)
                }
            }
        }
    }

    private static func composite(_ reader: any SlideReader, _ rect: PixelRect,
                                  _ settings: [DisplayChannel], _ solo: Int?) throws -> Data {
        let active = settings.indices.filter { channel in solo.map { $0 == channel } ?? settings[channel].visible }
        let data = try reader.readPlanes(channels: active, level: 0, rect: rect)
        var planes = [Data?](repeating: nil, count: settings.count)
        for (channel, plane) in zip(active, data) { planes[channel] = plane }
        return composeRGB(planes: planes, settings: settings, count: rect.width * rect.height, solo: solo)
    }

    private static func omeXML(_ info: SlideInfo, _ rect: PixelRect) -> String {
        func escape(_ value: String) -> String {
            let filtered = String(value.unicodeScalars.filter { $0.value >= 32 || [9, 10, 13].contains($0.value) })
            return filtered.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        let x = info.mppX.map { " PhysicalSizeX=\"\($0)\" PhysicalSizeXUnit=\"µm\"" } ?? ""
        let y = info.mppY.map { " PhysicalSizeY=\"\($0)\" PhysicalSizeYUnit=\"µm\"" } ?? ""
        let channels = info.channels.enumerated().map {
            "<Channel ID=\"Channel:0:\($0.offset)\" Name=\"\(escape($0.element.name))\" SamplesPerPixel=\"1\"/>"
        }.joined()
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <OME xmlns="http://www.openmicroscopy.org/Schemas/OME/2016-06"><Image ID="Image:0"><Pixels ID="Pixels:0" DimensionOrder="XYCZT" Type="\(info.channels[0].type.rawValue)" SizeX="\(rect.width)" SizeY="\(rect.height)" SizeC="\(info.channels.count)" SizeZ="1" SizeT="1"\(x)\(y)>\(channels)<TiffData IFD="0" PlaneCount="\(info.channels.count)"/></Pixels></Image></OME>
        """
    }
}

private struct ExportScale {
    let label: String
    private let x: Int
    private let y: Int
    private let width: Int
    private let height: Int
    private let bytes: Data

    init(roi: PixelRect, calibration: Calibration?) throws {
        let tooSmall = SlideError.invalid("ROI 太小，无法放入标尺。请扩大选区，或关闭标尺后导出。")
        guard let mark = ScaleMark(zoom: 1, target: min(1600, Double(roi.width) * 0.23), calibration: calibration)
        else { throw tooSmall }
        let label = (calibration?.source == .provisionalMetadata ? "≈ " : "") + mark.label
        let fontSize = CGFloat(min(36, max(10, min(roi.width, roi.height) / 28)))
        let margin = max(4, Int(fontSize / 2))
        let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: label, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1),
        ]))
        let bar = max(1, Int(mark.width.rounded()))
        let width = max(bar, Int(ceil(CTLineGetTypographicBounds(line, nil, nil, nil)))) + margin * 2
        let height = Int(ceil(fontSize * 1.45)) + margin * 2
        guard width + margin * 2 <= roi.width, height + margin * 2 <= roi.height else { throw tooSmall }

        var data = Data(count: width * height)
        let ok = data.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(CGRect(x: margin, y: margin, width: bar, height: max(2, Int(fontSize / 6))))
            context.textPosition = CGPoint(x: margin, y: margin + Int(fontSize / 3) + 4)
            CTLineDraw(line, context)
            return true
        }
        guard ok else { throw SlideError.invalid("无法生成导出标尺。") }
        self.label = label
        x = margin
        y = roi.height - height - margin
        self.width = width
        self.height = height
        bytes = data
    }

    func apply(to rgb: inout Data, x tileX: Int, y tileY: Int, width tileW: Int, height tileH: Int) {
        let x0 = max(x, tileX), x1 = min(x + width, tileX + tileW)
        let y0 = max(y, tileY), y1 = min(y + height, tileY + tileH)
        guard x0 < x1, y0 < y1 else { return }
        rgb.withUnsafeMutableBytes { raw in
            let pixels = raw.bindMemory(to: UInt8.self)
            for row in y0..<y1 {
                for col in x0..<x1 {
                    let value = bytes[(row - y) * width + col - x]
                    let start = ((row - tileY) * tileW + col - tileX) * 3
                    pixels[start] = value
                    pixels[start + 1] = value
                    pixels[start + 2] = value
                }
            }
        }
    }
}

func composeRGB(planes: [Data?], settings: [DisplayChannel], count: Int, solo: Int?) -> Data {
    var linear = [SIMD3<Float>](repeating: .zero, count: count)
    for index in settings.indices {
        let setting = settings[index]
        guard solo.map({ $0 == index }) ?? setting.visible, let data = planes[index] else { continue }
        data.withUnsafeBytes { bytes in
            if setting.ceiling == 255 {
                let samples = bytes.bindMemory(to: UInt8.self)
                for pixel in 0..<count { linear[pixel] += setting.mapped(Float(samples[pixel])) }
            } else {
                let samples = bytes.bindMemory(to: UInt16.self)
                for pixel in 0..<count { linear[pixel] += setting.mapped(Float(samples[pixel])) }
            }
        }
    }
    var rgb = Data(count: count * 3)
    rgb.withUnsafeMutableBytes { bytes in
        let pixels = bytes.bindMemory(to: UInt8.self)
        for i in 0..<count {
            for c in 0..<3 { pixels[i * 3 + c] = UInt8((min(1, linear[i][c]) * 255).rounded()) }
        }
    }
    return rgb
}

func rgbImage(_ data: Data, width: Int, height: Int) -> CGImage? {
    guard let provider = CGDataProvider(data: data as CFData) else { return nil }
    return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 24,
                   bytesPerRow: width * 3, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                   provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
}
