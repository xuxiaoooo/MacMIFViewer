import AppKit
import MetalKit
import SwiftUI

struct SlideCanvas: NSViewRepresentable {
    @ObservedObject var model: ViewerModel

    func makeNSView(context: Context) -> SlideMetalView {
        SlideMetalView(model: model)
    }

    func updateNSView(_ view: SlideMetalView, context: Context) {
        view.refresh()
    }

    static func dismantleNSView(_ view: SlideMetalView, coordinator: ()) {
        view.shutdown()
    }
}

final class SlideMetalView: MTKView, MTKViewDelegate {
    private struct Uniform {
        let color: SIMD4<Float>
        let mapping: SIMD4<Float>
    }

    private struct GPUGroup {
        let textures: [MTLTexture]
        let footprint: CGRect
        let bytes: Int
        var touched: UInt64 = 0
    }

    private weak var model: ViewerModel?
    private let documentID: UUID
    private var pipeline: MTLRenderPipelineState?
    private var queue: MTLCommandQueue?
    private var dummy: MTLTexture?
    private var tracking: NSTrackingArea?
    private var dragPoint: CGPoint?
    private var cache: [TileKey: GPUGroup] = [:]
    private var stamp: UInt64 = 0
    private var currentKeys: [TileKey] = []
    private var overview: GPUGroup?
    private var overviewLoaded = false
    private var lastViewport: Viewport?
    private var lastSettings: [DisplayChannel] = []
    private var lastSolo: Int?
    private var task: Task<Void, Never>?
    private var pending = false
    private var problem: String?
    private var generation = UUID()
    private let budget = 96 * 1024 * 1024

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(model: ViewerModel) {
        self.model = model
        documentID = model.documentID
        let gpu = MTLCreateSystemDefaultDevice()
        super.init(frame: .zero, device: gpu)
        framebufferOnly = true
        colorPixelFormat = .bgra8Unorm
        colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        clearColor = MTLClearColor(red: 0.024, green: 0.031, blue: 0.049, alpha: 1)
        isPaused = true
        enableSetNeedsDisplay = true
        delegate = self
        do {
            guard let gpu, let queue = gpu.makeCommandQueue(),
                  let url = Bundle.main.url(forResource: "Composite", withExtension: "metal") else {
                throw SlideError.invalid("当前设备无法初始化 Metal 画布。")
            }
            let library = try gpu.makeLibrary(source: String(contentsOf: url, encoding: .utf8), options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "slide_vertex")
            descriptor.fragmentFunction = library.makeFunction(name: "slide_fragment")
            descriptor.colorAttachments[0].pixelFormat = colorPixelFormat
            pipeline = try gpu.makeRenderPipelineState(descriptor: descriptor)
            self.queue = queue
            dummy = makeTexture(Data([0]), width: 1, height: 1, type: .uint8)
            guard dummy != nil else { throw SlideError.invalid("无法创建 Metal 纹理。") }
        } catch {
            problem = "Metal 初始化失败。\(error.localizedDescription)"
        }
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is unsupported") }

    func shutdown() {
        task?.cancel()
        task = nil
        model = nil
        cache.removeAll()
    }

    override func layout() {
        super.layout()
        guard !pending else { return }
        pending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pending = false
            guard let model = self.model, model.documentID == self.documentID,
                  self.bounds.width > 0, self.bounds.height > 0 else { return }
            model.resize(self.bounds.size)
            self.refresh()
        }
    }

    func refresh() {
        guard let model, model.documentID == documentID, let reader = model.reader else { return }
        if let problem {
            model.reportRenderError(problem)
            return
        }
        var redraw = model.viewport != lastViewport || model.settings != lastSettings || model.solo != lastSolo
        lastViewport = model.viewport
        lastSettings = model.settings
        lastSolo = model.solo
        if !overviewLoaded, let pixels = model.overview {
            overview = makeGroup(pixels, channels: reader.info.channels)
            overviewLoaded = true
            redraw = true
        }
        let keys = visibleTiles(info: reader.info, viewport: model.viewport)
        if keys != currentKeys {
            currentKeys = keys
            requestTiles()
            redraw = true
        }
        if redraw { needsDisplay = true }
    }

    private func makeTexture(_ data: Data, width: Int, height: Int, type: PixelType) -> MTLTexture? {
        guard width > 0, height > 0, data.count == width * height * type.bytes else { return nil }
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: type == .uint16 ? .r16Unorm : .r8Unorm, width: width, height: height, mipmapped: false)
        desc.usage = .shaderRead
        desc.storageMode = .shared
        guard let texture = device?.makeTexture(descriptor: desc) else { return nil }
        data.withUnsafeBytes {
            texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                            withBytes: $0.baseAddress!, bytesPerRow: width * type.bytes)
        }
        return texture
    }

    private func makeGroup(_ tile: TilePixels, channels: [Channel]) -> GPUGroup? {
        guard tile.channels.count == channels.count else { return nil }
        let textures = zip(tile.channels, channels).compactMap {
            makeTexture($0, width: tile.width, height: tile.height, type: $1.type)
        }
        guard textures.count == channels.count else { return nil }
        return GPUGroup(textures: textures, footprint: tile.footprint,
                        bytes: tile.channels.reduce(0) { $0 + $1.count })
    }

    private func requestTiles() {
        guard let model, let reader = model.reader else { return }
        task?.cancel()
        generation = UUID()
        let token = generation
        for key in currentKeys where cache[key] != nil {
            stamp &+= 1
            cache[key]?.touched = stamp
        }
        let needed = currentKeys.filter { cache[$0] == nil }
        guard !needed.isEmpty else { return }
        task = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(22))
                for key in needed {
                    try Task.checkCancellation()
                    let pixels = try readTile(reader, key)
                    try Task.checkCancellation()
                    await self?.accept(pixels, key: key, generation: token)
                }
            } catch is CancellationError {
                return
            } catch {
                await self?.tileFailed(error.localizedDescription, generation: token)
            }
        }
    }

    private func tileFailed(_ message: String, generation token: UUID) {
        guard generation == token, let model, model.documentID == documentID else { return }
        model.reportRenderError(message)
    }

    private func accept(_ tile: TilePixels, key: TileKey, generation token: UUID) {
        guard generation == token, let model, model.documentID == documentID,
              let reader = model.reader else { return }
        guard var group = makeGroup(tile, channels: reader.info.channels) else {
            tileFailed("无法分配 Metal tile 纹理。", generation: token)
            return
        }
        stamp &+= 1
        group.touched = stamp
        cache[key] = group
        var size = cache.values.reduce(0) { $0 + $1.bytes }
        if size > budget {
            for old in cache.sorted(by: { $0.value.touched < $1.value.touched }) {
                cache.removeValue(forKey: old.key)
                size -= old.value.bytes
                if size <= budget { break }
            }
        }
        needsDisplay = true
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let model, model.documentID == documentID,
              let pipeline, let queue, let dummy, let drawable = currentDrawable,
              let pass = currentRenderPassDescriptor, let command = queue.makeCommandBuffer(),
              let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return }
        let vp = model.viewport
        guard vp.size.width > 0, vp.size.height > 0 else { encoder.endEncoding(); return }
        encoder.setRenderPipelineState(pipeline)
        var styles = model.settings.enumerated().map { index, style in
            let on = model.solo.map { $0 == index } ?? style.visible
            return Uniform(color: SIMD4(style.color, Float(style.palette.rawValue)),
                           mapping: SIMD4(style.low / style.ceiling, style.high / style.ceiling,
                                          1 / style.gamma, on ? style.brightnessGain : 0))
        }
        styles += Array(repeating: Uniform(color: .zero, mapping: SIMD4(0, 1, 1, 0)), count: 8 - styles.count)
        styles.withUnsafeBytes { encoder.setFragmentBytes($0.baseAddress!, length: $0.count, index: 0) }
        func drawGroup(_ group: GPUGroup) {
            let f = group.footprint
            let top = vp.viewPoint(f.origin)
            let bottom = vp.viewPoint(CGPoint(x: f.maxX, y: f.maxY))
            let a = SIMD2(Float(2 * top.x / vp.size.width - 1), Float(1 - 2 * top.y / vp.size.height))
            let b = SIMD2(Float(2 * bottom.x / vp.size.width - 1), Float(1 - 2 * bottom.y / vp.size.height))
            let vertices: [SIMD4<Float>] = [
                [a.x, a.y, 0, 0], [b.x, a.y, 1, 0], [a.x, b.y, 0, 1], [b.x, b.y, 1, 1],
            ]
            vertices.withUnsafeBytes { encoder.setVertexBytes($0.baseAddress!, length: $0.count, index: 0) }
            for i in 0..<8 {
                encoder.setFragmentTexture(i < group.textures.count ? group.textures[i] : dummy, index: i)
            }
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        if let overview { drawGroup(overview) }
        for key in currentKeys {
            if let group = cache[key] { drawGroup(group) }
        }
        encoder.endEncoding()
        command.present(drawable)
        command.commit()
    }

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        tracking = area
        super.updateTrackingAreas()
    }

    private func position(_ event: NSEvent) -> CGPoint { convert(event.locationInWindow, from: nil) }

    override func mouseMoved(with event: NSEvent) { model?.cursorAt(position(event)) }
    override func mouseExited(with event: NSEvent) { model?.cursor = nil }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = position(event)
        dragPoint = point
        model?.pointerDown(point, clicks: event.clickCount)
    }

    override func mouseDragged(with event: NSEvent) {
        let point = position(event)
        if let dragPoint { model?.pointerDrag(from: dragPoint, to: point) }
        dragPoint = point
    }

    override func mouseUp(with event: NSEvent) {
        model?.pointerUp(position(event))
        dragPoint = nil
    }

    override func scrollWheel(with event: NSEvent) {
        let multiplier = exp(max(-2, min(2, event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 0.016 : 0.12))))
        model?.zoom(multiplier, at: position(event))
    }

    override func magnify(with event: NSEvent) {
        model?.zoom(max(0.1, 1 + event.magnification), at: position(event))
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: model?.cancelROI()
        case 36: model?.finishPolygon()
        default: super.keyDown(with: event)
        }
    }
}
