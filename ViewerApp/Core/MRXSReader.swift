import Foundation

private struct SlideINI {
    private var sections: [String: [String: String]] = [:]

    init(_ url: URL) throws {
        let bytes = try boundedFile(url, limit: 4 << 20)
        guard let text = String(data: bytes, encoding: .utf8) else {
            throw SlideError.invalid("无法读取 Slidedat.ini 的文本编码。")
        }
        var section = ""
        for line in text.split(whereSeparator: \.isNewline) {
            let value = line.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}"))
            if value.isEmpty || value.hasPrefix(";") || value.hasPrefix("#") { continue }
            if value.hasPrefix("[") && value.hasSuffix("]") {
                section = String(value.dropFirst().dropLast()).lowercased()
                continue
            }
            let pair = value.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard !section.isEmpty, pair.count == 2 else {
                throw SlideError.invalid("Slidedat.ini 的结构无效。")
            }
            let key = pair[0].trimmingCharacters(in: .whitespaces).lowercased()
            let field = pair[1].trimmingCharacters(in: .whitespaces)
            guard sections[section, default: [:]].updateValue(field, forKey: key) == nil else {
                throw SlideError.invalid("Slidedat.ini 中有重复字段。")
            }
        }
    }

    subscript(_ section: String) -> [String: String] { sections[section.lowercased()] ?? [:] }
}

private func boundedFile(_ url: URL, limit: Int) throws -> Data {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    guard let data = try handle.read(upToCount: limit + 1), !data.isEmpty, data.count <= limit else {
        throw SlideError.invalid("MRXS 的元数据或索引为空，或超出读取上限。")
    }
    return data
}

final class MRXSReader: SlideReader {
    private struct Block: Sendable {
        let file: Int
        let offset: Int
        let size: Int
    }

    private struct GridLevel: Sendable {
        let step: Int
        let width: Int
        let height: Int
        let groups: [Int: [Int: Block]]
    }

    private struct Mapping: Hashable, Sendable {
        let group: Int
        let slot: Int
    }

    let info: SlideInfo
    let supportsRawExport = false
    private let levels: [GridLevel]
    private let files: [URL]
    private let mappings: [Mapping]
    private let gridWidth: Int

    init(url: URL) throws {
        let entry = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard url.pathExtension.lowercased() == "mrxs", entry?.isRegularFile == true,
              (entry?.fileSize ?? 0) > 0 else {
            throw SlideError.invalid("请选择有效的 .mrxs 入口文件。")
        }
        let sidecar = url.deletingPathExtension()
        func sibling(_ name: String?) throws -> URL {
            guard let name, !name.isEmpty, name != ".", name != "..", !name.contains("/") else {
                throw SlideError.invalid("MRXS 的配套文件名无效。")
            }
            let file = sidecar.appendingPathComponent(name)
            let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values?.isRegularFile == true, values?.isSymbolicLink != true else {
                throw SlideError.invalid("找不到 MRXS 的同名目录或所需的配套文件。请将它们放在同一位置。")
            }
            return file
        }

        let ini = try SlideINI(sibling("Slidedat.ini"))
        let general = ini["general"]
        let hier = ini["hierarchical"]
        func unsupported(_ reason: String) -> SlideError {
            .invalid("此 MRXS 布局暂不支持直读。\n原因：\(reason)\n目前支持单焦平面、无位置偏移的 8-bit 荧光 JPEG 网格。")
        }

        guard general["slide_type"] == "SLIDE_TYPE_FLUORESCENCE" else {
            throw unsupported("切片类型不是荧光。")
        }
        guard general["vimslide_slide_bitdepth"] == "8" else {
            throw unsupported("位深不是 8-bit，或缺少位深字段。")
        }
        guard Int(general["cameraimagedivisionsperside"] ?? "1") == 1,
              Double(general["camera_rotation"] ?? "0") == 0 else {
            throw unsupported("相机图像分块或旋转方式不受支持。")
        }
        let expected = ["slide zoom level", "slide zoom mask level2", "slide filter level", "microscope focus level"]
        guard hier["hier_count"] == "4",
              expected.enumerated().allSatisfy({ hier["hier_\($0.offset)_name"]?.lowercased() == $0.element }),
              hier["hier_1_count"] == "2", hier["hier_1_val_0"] == "ZoomMaskDefault",
              hier["hier_1_val_1"] == "ZoomMaskData" else {
            throw unsupported("图像金字塔或掩膜的层级结构不同。")
        }
        guard hier["hier_3_count"] == "1", hier["hier_3_val_0"] == "ExtFocusLevel" else {
            throw unsupported("焦平面结构不同。")
        }
        guard let n = hier["nonhier_count"].flatMap(Int.init), (0...16).contains(n),
              (0..<n).allSatisfy({ ["VIMSLIDE_HISTOGRAM_DATA", "Scan data layer"].contains(hier["nonhier_\($0)_name"] ?? "") }) else {
            throw unsupported("辅助数据层结构不同，可能包含位置偏移或其他扩展。")
        }
        guard let nx = general["imagenumber_x"].flatMap(Int.init), (1...8192).contains(nx),
              let ny = general["imagenumber_y"].flatMap(Int.init), (1...8192).contains(ny), nx * ny <= 1_000_000,
              let depth = hier["hier_0_count"].flatMap(Int.init), (1...16).contains(depth) else {
            throw unsupported("图像网格尺寸或金字塔级数超出支持范围。")
        }
        guard let filters = hier["hier_2_count"].flatMap(Int.init), (1...8).contains(filters) else {
            throw unsupported("荧光通道数不在 1–8 范围内。")
        }
        guard let id = general["slide_id"], !id.isEmpty, id.utf8.count <= 128 else {
            throw SlideError.invalid("MRXS 切片标识字段无效。")
        }

        let dataFiles = ini["datafile"]
        guard let count = dataFiles["file_count"].flatMap(Int.init), (1...1024).contains(count) else { throw unsupported("数据文件计数超出支持范围。") }
        let urls = try (0..<count).map { try sibling(dataFiles["file_\($0)"]) }
        let sizes = try urls.map { file -> Int in
            guard let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0 else {
                throw SlideError.invalid("MRXS 数据块为空或不可读取。")
            }
            return size
        }
        let index = try boundedFile(sibling(hier["indexfile"]), limit: 32 << 20)
        let signature = Data(("01.02" + id).utf8)
        guard index.starts(with: signature) else { throw unsupported("索引签名与支持的版本或切片标识不匹配。") }
        let damaged = SlideError.invalid("MRXS 索引损坏，或数据块位置超出文件范围。")

        var map: [Mapping] = []
        var channels: [Channel] = []
        for channel in 0..<filters {
            let section = ini[hier["hier_2_val_\(channel)_section"] ?? ""]
            let storage = section["data_in_this_filter_level"] ?? ""
            guard storage.hasPrefix("FilterLevel_"),
                  let group = Int(storage.dropFirst("FilterLevel_".count)), (0..<filters).contains(group),
                  let slot = section["storing_channel_number"].flatMap(Int.init), (0...2).contains(slot),
                  section["zstack_step_count"] == "0" else { throw unsupported("通道组映射或 Z 层结构不同。") }
            // Candidate BGR slot order was cross-checked on the supplied IPP JPEG variant.
            map.append(Mapping(group: group, slot: 2 - slot))
            func color(_ prefix: String) -> SIMD3<Float>? {
                let components = ["r", "g", "b"].compactMap { axis in section[prefix + axis].flatMap(UInt8.init) }
                guard components.count == 3 else { return nil }
                return SIMD3(Float(components[0]), Float(components[1]), Float(components[2])) / 255
            }
            let palette = (section["modify"]?.uppercased() == "ON" ? color("modified_color_") : nil)
                ?? color("color_")
            let gamma = section["gamma"].flatMap(Float.init).flatMap { (0.15...4).contains($0) ? $0 : nil } ?? 1
            channels.append(Channel(name: section["filter_name"] ?? "通道 \(channel + 1)",
                                    source: "\(storage) · 槽 \(slot)", type: .uint8,
                                    display: ChannelDisplay(color: palette, gamma: gamma,
                                                            visible: section["active"]?.uppercased() != "OFF")))
        }
        guard Set(map).count == filters else { throw unsupported("多个通道引用了同一存储分量。") }

        let groups = Set(map.map(\.group)).sorted()
        var grids: [GridLevel] = []
        var imageLevels: [Level] = []
        let first = ini[hier["hier_0_val_0_section"] ?? ""]
        guard let baseW = first["digitizer_width"].flatMap(Int.init), (16...512).contains(baseW),
              let baseH = first["digitizer_height"].flatMap(Int.init), (16...512).contains(baseH) else { throw unsupported("底层 JPEG 图块尺寸超出支持范围。") }
        var step = 1
        try index.withUnsafeBytes { raw in
            func int(_ offset: Int) throws -> Int {
                guard offset >= 0, offset <= raw.count - 4 else { throw damaged }
                return Int(Int32(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: Int32.self)))
            }

            let root = try int(signature.count)
            let auxiliary = try int(signature.count + 4)
            guard root >= signature.count + 8, auxiliary <= raw.count,
                  root + 8 * depth * filters <= auxiliary else { throw damaged }
            let tableEnd = root + 8 * depth * filters

            for level in 0..<depth {
                try Task.checkCancellation()
                let section = ini[hier["hier_0_val_\(level)_section"] ?? ""]
                guard section["image_format"]?.uppercased() == "JPEG" else {
                    throw unsupported("第 \(level) 级图块使用其他编码。")
                }
                guard Int(section["digitizer_width"] ?? "") == baseW,
                      Int(section["digitizer_height"] ?? "") == baseH,
                      Double(section["overlap_x"] ?? "") == 0, Double(section["overlap_y"] ?? "") == 0,
                      section["image_concat_factor"] == (level == 0 ? "0" : "1") else { throw unsupported("第 \(level) 级图块的尺寸、重叠或拼接方式不同。") }
                if level > 0 { step *= 2 }
                let width = nx * baseW / step, height = ny * baseH / step
                guard width > 0, height > 0 else { throw unsupported("金字塔尺寸无效。") }

                var records: [Int: [Int: Block]] = [:]
                for group in groups {
                    let pointer = try int(root + 4 * (level + 2 * depth * group))
                    guard pointer >= tableEnd, try int(pointer) == 0 else { throw damaged }
                    var page = try int(pointer + 4)
                    var visited = Set<Int>()
                    var tiles: [Int: Block] = [:]
                    while page != 0 {
                        guard page >= tableEnd, visited.insert(page).inserted else { throw damaged }
                        let count = try int(page)
                        let next = try int(page + 4)
                        guard count > 0, count <= nx * ny - tiles.count,
                              page + 8 + 16 * count <= raw.count else { throw damaged }
                        for row in 0..<count {
                            let item = page + 8 + row * 16
                            let key = try int(item), start = try int(item + 4)
                            let size = try int(item + 8), file = try int(item + 12)
                            guard (0..<nx * ny).contains(key), tiles[key] == nil,
                                  key % nx % step == 0, key / nx % step == 0,
                                  sizes.indices.contains(file), start >= 0, (1...(4 << 20)).contains(size),
                                  start <= sizes[file] - size else { throw damaged }
                            tiles[key] = Block(file: file, offset: start, size: size)
                        }
                        page = next
                    }
                    guard !tiles.isEmpty else { throw damaged }
                    if let first = records[groups[0]],
                       first.count != tiles.count || !first.keys.allSatisfy({ tiles[$0] != nil }) {
                        throw SlideError.invalid("MRXS 通道组的 tile 覆盖范围不一致。")
                    }
                    records[group] = tiles
                }
                grids.append(GridLevel(step: step, width: baseW, height: baseH, groups: records))
                imageLevels.append(Level(width: width, height: height, dx: Double(step), dy: Double(step)))
            }
        }

        files = urls
        levels = grids
        mappings = map
        gridWidth = nx
        info = SlideInfo(title: url.lastPathComponent, mode: "MRXS 直接预览 · 候选通道",
                         levels: imageLevels, channels: channels,
                         mppX: first["micrometer_per_pixel_x"].flatMap(Double.init),
                         mppY: first["micrometer_per_pixel_y"].flatMap(Double.init))

        // Verify the declared codec for each group and level before showing the slide.
        for level in grids {
            for group in groups {
                try Task.checkCancellation()
                if let block = level.groups[group]?.values.first { _ = try decode(block, level) }
            }
        }
    }

    private func decode(_ block: Block, _ grid: GridLevel) throws -> Data {
        let handle = try FileHandle(forReadingFrom: files[block.file])
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(block.offset))
        guard let payload = try handle.read(upToCount: block.size), payload.count == block.size else {
            throw SlideError.invalid("MRXS tile 数据不完整。")
        }
        let size = grid.width * grid.height * 3
        var rgb = Data(count: size)
        let success = rgb.withUnsafeMutableBytes { dst in
            payload.withUnsafeBytes { src in
                mf_mrxs_jpeg_rgb(src.baseAddress, src.count, UInt32(grid.width), UInt32(grid.height),
                                 dst.baseAddress, size)
            }
        }
        guard success != 0 else {
            throw SlideError.invalid("MRXS tile 不是可读取的三分量 8-bit IPP JPEG，或 tile 数据已损坏。")
        }
        return rgb
    }

    func read(channel: Int, level: Int, rect: PixelRect) throws -> Data {
        try readPlanes(channels: [channel], level: level, rect: rect)[0]
    }

    func readPlanes(channels: [Int], level: Int, rect: PixelRect) throws -> [Data] {
        for channel in channels { try validateRead(info, channel: channel, level: level, rect: rect) }
        guard !channels.isEmpty else { return [] }
        let grid = levels[level]
        let byGroup = Dictionary(grouping: channels.enumerated(), by: { mappings[$0.element].group })
        var planes = channels.map { _ in Data(count: rect.width * rect.height) }
        for row in rect.y / grid.height...(rect.y + rect.height - 1) / grid.height {
            let top = row * grid.height
            let y0 = max(top, rect.y), y1 = min(top + grid.height, rect.y + rect.height)
            for col in rect.x / grid.width...(rect.x + rect.width - 1) / grid.width {
                let left = col * grid.width
                let x0 = max(left, rect.x), x1 = min(left + grid.width, rect.x + rect.width)
                let key = (row * gridWidth + col) * grid.step
                for (group, channels) in byGroup {
                    try Task.checkCancellation()
                    // A missing index entry in all groups is an unscanned area.
                    guard let block = grid.groups[group]?[key] else { continue }
                    let rgb = try decode(block, grid)
                    rgb.withUnsafeBytes { source in
                        let src = source.bindMemory(to: UInt8.self)
                        for (index, channel) in channels {
                            let slot = mappings[channel].slot
                            planes[index].withUnsafeMutableBytes { target in
                                let dst = target.bindMemory(to: UInt8.self)
                                for y in y0..<y1 {
                                    let from = ((y - top) * grid.width + x0 - left) * 3 + slot
                                    let to = (y - rect.y) * rect.width + x0 - rect.x
                                    for x in 0..<(x1 - x0) { dst[to + x] = src[from + x * 3] }
                                }
                            }
                        }
                    }
                }
            }
        }
        return planes
    }
}
