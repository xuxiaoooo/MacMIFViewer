import Foundation

private struct OMEInfo {
    let dimensions: (Int, Int)
    let type: PixelType
    let ifds: [Int]
    let names: [String]
    let mppX: Double?
    let mppY: Double?
}

private final class OMEParser: NSObject, XMLParserDelegate {
    private var elements: [String] = []
    private var imageCount = 0
    private var pixels: [String: String] = [:]
    private var channels: [[String: String]] = []
    private var mappings: [[String: String]] = []
    private var invalid = false

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes: [String: String]) {
        elements.append(elementName)
        switch elements {
        case ["OME", "Image"]: imageCount += 1
        case ["OME", "Image", "Pixels"]: pixels = attributes
        case ["OME", "Image", "Pixels", "Channel"]: channels.append(attributes)
        case ["OME", "Image", "Pixels", "TiffData"]: mappings.append(attributes)
        case ["OME", "Image", "Pixels", "TiffData", "UUID"],
             ["OME", "Image", "Pixels", "BinData"],
             ["OME", "BinaryOnly"]: invalid = true
        default: break
        }
        if elements.count > 64 || channels.count > 8 || mappings.count > 8 { parser.abortParsing() }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        if !elements.isEmpty { elements.removeLast() }
    }

    private func physicalSize(_ axis: String) -> Double? {
        guard let value = pixels["PhysicalSize\(axis)"].flatMap(Double.init),
              value.isFinite, value > 0 else { return nil }
        let unit = pixels["PhysicalSize\(axis)Unit"] ?? "µm"
        let factor: Double
        switch unit {
        case "µm", "μm", "um": factor = 1
        case "nm": factor = 0.001
        case "mm": factor = 1000
        case "cm": factor = 10000
        case "m": factor = 1_000_000
        default: return nil
        }
        let size = value * factor
        return size.isFinite && size > 0 ? size : nil
    }

    func parse(_ xml: String, pages: Int) throws -> OMEInfo {
        let error = SlideError.invalid("OME-TIFF 需要单文件、单图像、单 Z/T、1–8 个独立 uint8 或 uint16 灰度通道。请检查 OME-XML 和 IFD 映射。")
        guard xml.utf8.count <= 2_000_000, !xml.contains("<!DOCTYPE") else { throw error }
        let parser = XMLParser(data: Data(xml.utf8))
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = self
        guard parser.parse(), !invalid, imageCount == 1,
              let w = pixels["SizeX"].flatMap(Int.init), w > 0,
              let h = pixels["SizeY"].flatMap(Int.init), h > 0,
              let c = pixels["SizeC"].flatMap(Int.init), (1...8).contains(c),
              pixels["SizeZ"] == "1", pixels["SizeT"] == "1",
              let order = pixels["DimensionOrder"], order.hasPrefix("XY"),
              order.count == 5, Set(order) == Set("XYZCT"),
              let type = pixels["Type"].flatMap(PixelType.init),
              channels.count == c, !mappings.isEmpty,
              channels.allSatisfy({ ($0["SamplesPerPixel"] ?? "1") == "1" }) else { throw error }

        var indices = [Int?](repeating: nil, count: c)
        var used = Set<Int>()
        for map in mappings {
            guard let start = Int(map["FirstC"] ?? "0"), (0..<c).contains(start),
                  Int(map["FirstZ"] ?? "0") == 0, Int(map["FirstT"] ?? "0") == 0,
                  let ifd = Int(map["IFD"] ?? "0"), (0..<pages).contains(ifd),
                  let count = Int(map["PlaneCount"] ?? (map["IFD"] == nil ? String(pages) : "1")),
                  count > 0, count <= pages - ifd else { throw error }
            let validCount = map["PlaneCount"] == nil && map["IFD"] == nil ? min(count, c - start) : count
            guard validCount <= c - start else { throw error }
            for k in 0..<validCount {
                guard indices[start + k] == nil, used.insert(ifd + k).inserted else { throw error }
                indices[start + k] = ifd + k
            }
        }
        let ifds = indices.compactMap { $0 }
        guard ifds.count == c else { throw error }
        return OMEInfo(dimensions: (w, h), type: type, ifds: ifds,
                       names: channels.enumerated().map { i, channel in
                           let name = channel["Name"]?.trimmingCharacters(in: .whitespacesAndNewlines)
                           return name.flatMap { $0.isEmpty ? nil : $0 } ?? "通道 \(i + 1)"
                       }, mppX: physicalSize("X"), mppY: physicalSize("Y"))
    }
}

private final class TiffFile: @unchecked Sendable {
    private let handle: UnsafeMutableRawPointer
    private let lock = NSLock()
    let pages: Int

    init(_ url: URL) throws {
        guard url.isFileURL, let handle = url.withUnsafeFileSystemRepresentation({
            $0.flatMap { mf_tiff_open($0) }
        }) else { throw SlideError.invalid("无法打开 TIFF。请检查文件完整性和读取权限。") }
        self.handle = handle
        pages = Int(mf_tiff_pages(handle))
    }

    deinit { mf_tiff_close(handle) }

    func description() -> String? {
        lock.withLock { mf_tiff_description(handle).flatMap { String(validatingUTF8: $0) } }
    }

    func page(_ ifd: Int, _ sub: Int = -1) throws -> MFPage {
        try lock.withLock {
            var page = MFPage()
            guard mf_tiff_page(handle, UInt32(ifd), Int32(sub), &page) != 0,
                  page.width > 0, page.height > 0, page.samples == 1, page.sample_format == 1,
                  page.photometric == 1 || page.photometric == 0, page.orientation == 1,
                  page.bits == 8 || page.bits == 16 else {
                throw SlideError.invalid("需要独立的 8/16-bit 无符号灰度 TIFF 通道和左上原点。RGB、调色板和其他方向暂不支持。")
            }
            guard mf_tiff_codec(page.codec) != 0, page.decoded_block_bytes > 0,
                  page.decoded_block_bytes <= 32 * 1024 * 1024 else {
                throw SlideError.invalid("TIFF 压缩方式不可用，或单个 tile/strip 超过 32 MiB。请另存为分块 TIFF。")
            }
            return page
        }
    }

    func read(ifd: Int, sub: Int, rect: PixelRect, type: PixelType) throws -> Data {
        try lock.withLock {
            let size = rect.width * rect.height * type.bytes
            var data = Data(count: size)
            let ok = data.withUnsafeMutableBytes {
                mf_tiff_read(handle, UInt32(ifd), Int32(sub), UInt32(rect.x), UInt32(rect.y),
                             UInt32(rect.width), UInt32(rect.height), $0.baseAddress, size)
            }
            guard ok != 0 else { throw SlideError.invalid("TIFF 区域解码失败。请检查 tile/strip 数据完整性。") }
            return data
        }
    }
}

final class TiffReader: SlideReader {
    private struct Plane: Sendable {
        let file: TiffFile
        let ifd: Int
    }

    let info: SlideInfo
    private let planes: [Plane]

    init(urls: [URL]) throws {
        guard (1...8).contains(urls.count), Set(urls.map { $0.resolvingSymlinksInPath() }).count == urls.count else {
            throw SlideError.invalid("请选择 1–8 个不同的 TIFF 文件。")
        }
        if urls.contains(where: { $0.pathExtension.lowercased() == "mrxs" }) {
            throw SlideError.invalid("MRXS 请单独打开。分通道模式仅接受 TIFF。")
        }
        let files = try urls.map(TiffFile.init)
        let xml = files[0].description()
        let looksOME = xml?.range(of: #"<(?:\w+:)?OME(?:\s|>)"#, options: .regularExpression) != nil
        let ome: OMEInfo?
        let names: [String]
        if urls.count == 1, looksOME, let xml {
            let parsed = try OMEParser().parse(xml, pages: files[0].pages)
            ome = parsed
            planes = parsed.ifds.map { Plane(file: files[0], ifd: $0) }
            names = parsed.names
        } else {
            guard zip(files, urls).allSatisfy({ file, url in
                file.pages == 1 && !url.lastPathComponent.lowercased().contains(".ome.")
                    && file.description()?.range(of: #"<(?:\w+:)?OME(?:\s|>)"#,
                                                  options: .regularExpression) == nil
            }) else {
                throw SlideError.invalid("分通道 TIFF 每个文件应仅含一个灰度平面，可附带 SubIFD 金字塔。多页通道请使用 OME-TIFF。")
            }
            ome = nil
            planes = files.map { Plane(file: $0, ifd: 0) }
            names = urls.map { $0.deletingPathExtension().lastPathComponent }
        }

        let pages = try planes.map { try $0.file.page($0.ifd) }
        let base = pages[0]
        guard pages.allSatisfy({ $0.width == base.width && $0.height == base.height }) else {
            throw SlideError.invalid("通道平面尺寸不一致。请导出相同区域、分辨率和 Z 位置。")
        }
        if let ome {
            guard ome.dimensions == (Int(base.width), Int(base.height)),
                  pages.allSatisfy({ Int($0.bits) == ome.type.bytes * 8 }) else {
                throw SlideError.invalid("OME-XML 与 TIFF 图像尺寸或位深不一致。")
            }
        }
        var levels = [Level(width: Int(base.width), height: Int(base.height), dx: 1, dy: 1)]
        let subCounts = Set(pages.map { Int($0.sub_count) })
        guard pages.allSatisfy({ $0.sub_count <= 32 }) else {
            throw SlideError.invalid("金字塔级数超过可读范围。")
        }
        if subCounts.count == 1 {
            for sub in 0..<Int(base.sub_count) {
                let reduced = try planes.map { try $0.file.page($0.ifd, sub) }
                let w = Int(reduced[0].width), h = Int(reduced[0].height)
                guard w <= levels.last!.width, h <= levels.last!.height,
                      w < levels.last!.width || h < levels.last!.height,
                      zip(reduced, pages).allSatisfy({ $0.width == w && $0.height == h && $0.bits == $1.bits }) else {
                    throw SlideError.invalid("SubIFD 金字塔的尺寸或位深不一致。")
                }
                levels.append(Level(width: w, height: h,
                                    dx: Double(base.width) / Double(w), dy: Double(base.height) / Double(h)))
            }
        }
        let channels = pages.enumerated().map { index, page in
            Channel(name: names[index], source: urls[ome == nil ? index : 0].lastPathComponent,
                    type: page.bits == 16 ? .uint16 : .uint8)
        }
        func consensus(_ values: [Double]) throws -> Double? {
            let known = values.filter { $0.isFinite && $0 > 0 }
            guard let first = known.first else { return nil }
            guard known.allSatisfy({ abs($0 / first - 1) < 0.0001 }) else {
                throw SlideError.invalid("分通道 TIFF 的物理像素尺寸不一致。")
            }
            return known.count == values.count ? first : nil
        }
        info = SlideInfo(title: urls.count == 1 ? urls[0].lastPathComponent : "分通道切片",
                         mode: ome == nil ? "灰度 TIFF" : "OME-TIFF",
                         levels: levels, channels: channels,
                         mppX: ome == nil ? try consensus(pages.map(\.mpp_x)) : ome?.mppX,
                         mppY: ome == nil ? try consensus(pages.map(\.mpp_y)) : ome?.mppY)
    }

    func read(channel: Int, level: Int, rect: PixelRect) throws -> Data {
        try validateRead(info, channel: channel, level: level, rect: rect)
        let plane = planes[channel]
        return try plane.file.read(ifd: plane.ifd, sub: level - 1, rect: rect,
                                   type: info.channels[channel].type)
    }
}
