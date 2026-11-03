import Foundation

private func check(_ predicate: @autoclosure () -> Bool, _ message: String) throws {
    if !predicate() { throw SlideError.invalid(message) }
}

private func expectError(_ action: () throws -> Void) throws {
    do { try action() } catch { return }
    throw SlideError.invalid("Expected error")
}

@main
struct ReaderRegression {
    @MainActor
    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        func url(_ name: String) -> URL { root.appendingPathComponent(name) }
        let sample = try TiffReader(urls: [url("six.ome.tiff")])
        try check(sample.info.channels.count == 6, "channel count")
        try check(sample.info.channels[5].name == "Test 5", "channel label")
        try check(sample.info.levels.count == 2 && sample.info.levels[1].width == 258, "SubIFD levels")
        try check(sample.info.mppX == 0.325 && sample.info.mppY == 0.5, "physical scale")

        let crop = PixelRect(x: 232, y: 62, width: 283, height: 271)
        let l1 = PixelRect(x: 61, y: 63, width: 143, height: 92)
        for c in 0..<6 {
            let image = try sample.read(channel: c, level: 0, rect: crop)
            let coarse = try sample.read(channel: c, level: 1, rect: l1)
            for (data, rect, factor) in [(image, crop, 1), (coarse, l1, 2)] {
                try data.withUnsafeBytes { bytes in
                    let u16 = bytes.bindMemory(to: UInt16.self)
                    try check(u16.count == rect.width * rect.height, "row stride")
                    for y in 0..<rect.height {
                        for x in 0..<rect.width {
                            let expected = UInt16((rect.x + x) * 17 * factor
                                + (rect.y + y) * 41 * factor + c * 1009)
                            try check(u16[y * rect.width + x] == expected, "uint16 pixel or tile boundary")
                        }
                    }
                }
            }
        }
        let reordered = try TiffReader(urls: [url("reordered.ome.tiff")])
        let origin = PixelRect(x: 0, y: 0, width: 1, height: 1)
        let reorderedChannel = try reordered.read(channel: 0, level: 0, rect: origin)
        try check(reorderedChannel.withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) } == 1009, "IFD order")
        let split = try TiffReader(urls: [url("split-01.tiff"), url("split-02.tiff")])
        try check(split.info.channels.map(\.type) == [.uint8, .uint8] &&
                  split.info.mppX == 1 && split.info.mppY == 0.5, "split TIFF metadata")
        let jpeg = try TiffReader(urls: [url("jpeg.tiff")])
        let jpegROI = try jpeg.read(channel: 0, level: 0, rect: crop)
        try check(jpegROI.count == 283 * 271, "JPEG TIFF")

        let viewer = ViewerModel()
        let demoDocument = viewer.documentID
        guard var oldControl = viewer.channelStyle(5, in: demoDocument) else {
            throw SlideError.invalid("Missing demo brightness control")
        }
        oldControl.brightness = 0.25
        viewer.setChannelStyle(oldControl, at: 5, in: demoDocument)
        try check(viewer.channelStyle(5, in: demoDocument)?.brightnessGain == 0.25,
                  "current slide brightness control")
        viewer.open([url("jpeg.tiff")])
        for _ in 0..<100 {
            if viewer.documentID != demoDocument || viewer.error != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try check(viewer.error == nil && viewer.documentID != demoDocument &&
                  viewer.settings.count == 1, "switch from six channels to one")
        try check(viewer.channelStyle(5, in: demoDocument) == nil &&
                  viewer.channelStyle(0, in: demoDocument) == nil &&
                  viewer.channelStyle(5, in: viewer.documentID) == nil,
                  "retired and out-of-range controls cannot read the new slide")
        viewer.setChannelStyle(oldControl, at: 5, in: demoDocument)
        viewer.setChannelStyle(oldControl, at: 0, in: demoDocument)
        try check(viewer.settings[0].brightnessGain == 1, "retired controls cannot edit the new slide")
        viewer.showDemo()

        try expectError { _ = try TiffReader(urls: [url("rgb.tiff")]) }
        try expectError { _ = try TiffReader(urls: [url("synthetic.mrxs")]) }
        let mrxs = try MRXSReader(url: url("synthetic.mrxs"))
        let seam = PixelRect(x: 15, y: 15, width: 2, height: 2)
        let planes = try mrxs.readPlanes(channels: [0, 3, 4], level: 0, rect: seam)
        try check(mrxs.info.channels.count == 6 && mrxs.info.base.width == 32, "MRXS metadata")
        try check(planes == [Data([79, 80, 81, 82]), Data([0, 1, 2, 3]), Data([121, 122, 123, 124])],
                  "MRXS component order and four-tile seam")
        let mrxsROI = Region(kind: .rectangle, vertices: [
            PointL0(CGPoint(x: 15, y: 15)), PointL0(CGPoint(x: 17, y: 17)),
        ])
        try expectError { try ROIExporter.export(reader: mrxs, region: mrxsROI, format: .raw,
            settings: DisplayChannel.defaults(mrxs.info), solo: nil, destination: url("reject-mrxs-raw")) }
        try check(!FileManager.default.fileExists(atPath: url("reject-mrxs-raw").path), "MRXS export guard")
        try expectError { _ = try TiffReader(urls: [url("split-01.tiff"), url("misaligned.tiff")]) }
        try expectError { _ = try sample.read(channel: 6, level: 0, rect: crop) }
        try expectError { _ = try sample.read(channel: 0, level: 0,
            rect: PixelRect(x: 514, y: 0, width: 2, height: 1)) }

        let synth = SyntheticReader()
        let synthetic = try synth.read(channel: 3, level: 0, rect: crop)
        let first = synthetic.withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) }
        try check(first == SyntheticReader.value(channel: 3, x: crop.x, y: crop.y), "synthetic truth")
        var vp = Viewport(size: CGSize(width: 750, height: 630))
        vp.fit(synth.info.base)
        let anchor = CGPoint(x: 330, y: 230)
        let old = vp.slidePoint(anchor)
        vp.magnify(1.5, at: anchor, level: synth.info.base)
        try check(abs(vp.slidePoint(anchor).x - old.x) < 0.001 &&
                  abs(vp.slidePoint(anchor).y - old.y) < 0.001, "cursor anchored zoom")
        try check(!visibleTiles(info: synth.info, viewport: vp).isEmpty, "visible tile selection")
        try check(vp.slidePoint(vp.viewPoint(CGPoint(x: 100, y: 112))).x == 100, "coordinates")

        let roi = Region(kind: .polygon, vertices: [
            PointL0(CGPoint(x: 232, y: 62)), PointL0(CGPoint(x: 515, y: 100)),
            PointL0(CGPoint(x: 512, y: 333)),
        ])
        try check(roi.bounds(in: sample.info.base) == crop, "polygon bounding box")
        var styles = DisplayChannel.defaults(sample.info)
        try ROIExporter.export(reader: sample, region: roi, format: .raw, settings: styles,
                               solo: nil, destination: url("raw-default"))
        styles[0].color = [1, 0, 0]
        styles[0].low = 100
        styles[0].high = 20_000
        styles[0].gamma = 1.8
        styles[1].visible = false
        styles[0].brightness = 0.5
        try ROIExporter.export(reader: sample, region: roi, format: .raw, settings: styles,
                               solo: 0, destination: url("raw-modified"))
        try ROIExporter.export(reader: sample, region: roi, format: .renderedTiff, settings: styles,
                               solo: 0, destination: url("rendered"))
        try ROIExporter.export(reader: sample, region: roi, format: .renderedPNG, settings: styles,
                               solo: 0, destination: url("rendered-png"))
        let calibration = Calibration(x: 0.5, y: 2, source: .manual)!
        let line = Region(kind: .line, vertices: [
            PointL0(CGPoint(x: 0, y: 0)), PointL0(CGPoint(x: 6, y: 2)),
        ])
        try check(line.isValid(in: sample.info.base) &&
                  line.measurement(calibration: calibration).value == 5 &&
                  line.bounds(in: sample.info.base) == nil, "anisotropic line measurement")
        let rectangle = Region(kind: .rectangle, vertices: [
            PointL0(CGPoint(x: 0, y: 0)), PointL0(CGPoint(x: 6, y: 2)),
        ])
        try check(rectangle.measurement(calibration: calibration).value == 12, "calibrated area")
        let crossed = Region(kind: .polygon, vertices: [(0, 0), (8, 8), (0, 8), (8, 0)].map {
            PointL0(CGPoint(x: $0.0, y: $0.1))
        })
        try check(!crossed.isValid(in: sample.info.base), "reject self-intersecting ROI")
        let mark = ScaleMark(zoom: 0.5, target: 104, calibration: calibration)
        try check(mark?.label == "100 µm" && mark?.width == 100, "scale bar tracks zoom")
        var tint = styles[0]
        tint.color = [1, 0.25, 0.5]
        let dim = tint.mapped(20_000)
        try check(dim == SIMD3<Float>(0.5, 0.125, 0.25), "brightness dims without changing hue")
        tint.brightness = 2
        try check(tint.mapped(20_000) == tint.color, "bright highlights retain hue")
        tint.brightness = 0
        try check(tint.mapped(20_000) == .zero, "zero brightness")
        var savedStyles = styles
        savedStyles[0].brightness = nil
        savedStyles[0].palette = .heat
        try check(savedStyles[0].mapped(20_000) == SIMD3<Float>(1, 1, 1), "heat endpoint")
        savedStyles[0].palette = .grayscale
        savedStyles[0].brightness = 0.75
        let gray = savedStyles[0].mapped(1000)
        try check(gray.x == gray.y && gray.y == gray.z, "grayscale")
        let annotations = [Annotation(id: UUID(), name: "Tissue edge", region: roi),
                           Annotation(id: UUID(), name: "Distance", region: line)]
        let session = SlideSession(settings: savedStyles, annotations: annotations,
                                   calibration: calibration, showScale: true)
        let sessionURL = url("session.json")
        try session.save(to: sessionURL)
        let loaded = try SlideSession.load(from: sessionURL)
        try check(loaded?.settings == savedStyles && loaded?.calibration == calibration &&
                  loaded?.annotations.map(\.name) == ["Tissue edge", "Distance"], "slide session round trip")
        try ROIExporter.export(reader: sample, region: roi, format: .renderedTiff, settings: styles,
                               solo: 0, destination: url("scale-tiff"), annotationName: "Tissue edge",
                               calibration: calibration, includeScale: true)
        try ROIExporter.export(reader: sample, region: roi, format: .renderedPNG, settings: styles,
                               solo: 0, destination: url("scale-png"), annotationName: "Tissue edge",
                               calibration: calibration, includeScale: true)
        try ROIExporter.export(reader: sample, region: roi, format: .renderedJPEG, settings: styles,
                               solo: 0, destination: url("scale-jpeg"), annotationName: "Tissue edge",
                               calibration: calibration, includeScale: true)
        try ROIExporter.export(reader: split, region: roi, format: .raw,
                               settings: DisplayChannel.defaults(split.info),
                               solo: nil, destination: url("raw-8"))
        let mixed = try TiffReader(urls: [url("split-01.tiff"), url("mixed.tiff")])
        try expectError { try ROIExporter.export(reader: mixed, region: roi, format: .raw,
            settings: DisplayChannel.defaults(mixed.info), solo: nil, destination: url("reject-mixed")) }
        try expectError { try ROIExporter.export(reader: sample, region: roi, format: .raw, settings: styles,
            solo: nil, destination: url("raw-default")) }
        if CommandLine.arguments.count > 2 {
            let real = try MRXSReader(url: URL(fileURLWithPath: CommandLine.arguments[2]))
            let (overview, approximate) = try readOverview(real)
            try check(real.info.channels.count == 5 && real.info.levels.count == 10, "sample metadata")
            try check(!approximate && overview.channels.allSatisfy { $0.contains { $0 > 0 } },
                      "sample pyramid preview")
            var colors = DisplayChannel.defaults(real.info)
            try check(colors[0].color == SIMD3<Float>(0, 0, 1) &&
                      colors[3].color == SIMD3<Float>(1, 0, 0) &&
                      colors[4].color == SIMD3<Float>(1, 1, 1), "saved MRXS pseudocolors")
            let overviewPixels = overview.width * overview.height
            let optionalPlanes = overview.channels.map(Optional.some)
            let before = composeRGB(planes: optionalPlanes, settings: colors, count: overviewPixels, solo: nil)
            for c in colors.indices { colors[c].autoContrast8Bit(overview.channels[c]) }
            let after = composeRGB(planes: optionalPlanes, settings: colors, count: overviewPixels, solo: nil)
            func colored(_ pixels: Data) -> Int {
                var count = 0
                for i in stride(from: 0, to: pixels.count, by: 3) {
                    let r = pixels[i], g = pixels[i + 1], b = pixels[i + 2]
                    if max(r, g, b) - min(r, g, b) >= 32 { count += 1 }
                }
                return count
            }
            let fullRange = colored(before), stretched = colored(after)
            try check(colors.allSatisfy { $0.low < $0.high && $0.high < 255 } &&
                      stretched > fullRange, "MRXS contrast window")
            print("MRXS overview color spread ≥32: \(fullRange) → \(stretched) of \(overviewPixels) pixels.")
            print("MRXS preview windows: \(colors.map { "\(Int($0.low))–\(Int($0.high))" }.joined(separator: ", ")).")
            let plan = try JSONSerialization.jsonObject(with: Data(contentsOf: url("mrxs-plan.json"))) as! [[Int]]
            var observed = Data()
            for r in plan {
                let rect = PixelRect(x: r[1], y: r[2], width: r[3], height: r[4])
                let planes = try real.readPlanes(channels: Array(real.info.channels.indices), level: r[0], rect: rect)
                for plane in planes { observed.append(plane) }
            }
            try observed.write(to: url("mrxs-observed.bin"))
            print("Sample MRXS loaded with five channels and ten pyramid levels.")
        }
        print("Reader, viewport, format gate and export checks passed.")
    }
}
