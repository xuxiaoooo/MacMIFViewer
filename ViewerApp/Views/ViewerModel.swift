import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class ViewerModel: ObservableObject {
    enum Tool: String, CaseIterable {
        case pan = "平移", rectangle = "矩形", polygon = "多边形", line = "测距"
    }
    enum Inspector: String, CaseIterable { case channels = "通道", annotations = "ROI 与测量" }

    @Published private(set) var reader: (any SlideReader)?
    @Published private(set) var documentID = UUID()
    @Published var settings: [DisplayChannel] = [] { didSet { renderThumbnail(); queueSessionSave() } }
    @Published var solo: Int? { didSet { renderThumbnail() } }
    @Published var selection = 0
    @Published private(set) var thumbnail: CGImage?
    @Published var viewport = Viewport()
    @Published var cursor: CGPoint?
    @Published private(set) var overview: TilePixels?
    @Published private(set) var approximateOverview = false
    @Published var tool = Tool.pan
    @Published var inspector = Inspector.channels
    @Published private(set) var annotations: [Annotation] = [] { didSet { queueSessionSave() } }
    @Published private(set) var selectedAnnotationID: UUID?
    @Published private(set) var editingRegion: Region?
    @Published var showScale = true { didSet { queueSessionSave() } }
    @Published private(set) var manualCalibration: Calibration? { didSet { queueSessionSave() } }
    private var editingVertex: Int?

    var selectedAnnotation: Annotation? { annotations.first { $0.id == selectedAnnotationID } }
    var region: Region? { selectedAnnotation.flatMap { $0.region.kind == .line ? nil : $0.region } }

    var calibration: Calibration? {
        if let manualCalibration { return manualCalibration }
        guard let reader else { return nil }
        return Calibration(x: reader.info.mppX, y: reader.info.mppY,
                           source: reader.supportsRawExport ? .metadata : .provisionalMetadata)
    }
    @Published var draft: [PointL0] = []
    @Published var error: String?
    @Published var renderError: String?
    @Published var status = ""
    @Published var exportProgress: Double?

    private var opening = false
    private var openTask: Task<Void, Never>?
    private var overviewTask: Task<Void, Never>?
    private var exportTask: Task<Void, Never>?
    private var loadID = UUID()
    private var overviewThumbnail: TilePixels?
    private var displayDefaults: [DisplayChannel] = []
    private var sessionURL: URL?
    private var pendingSave: Task<Void, Never>?
    private var restoredSettings = false

    init() { showDemo() }

    func showDemo() {
        openTask?.cancel()
        loadID = UUID()
        opening = false
        install(SyntheticReader())
    }

    func openPanel() {
        let panel = NSOpenPanel()
        panel.title = "打开切片"
        panel.message = "选择一个 MRXS 或 OME-TIFF，或选择同一区域和焦平面的 1–8 个灰度 TIFF。"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.tiff] + ["mrxs", "tf2", "tf8", "btf"].compactMap {
            UTType(filenameExtension: $0)
        }
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            self?.open(panel.urls)
        }
    }

    func open(_ input: [URL]) {
        guard !input.isEmpty else { return }
        let urls = input.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        if urls.count > 1 {
            let alert = NSAlert()
            alert.messageText = "确认分通道图像已对齐"
            alert.informativeText = "通道按下列文件名顺序载入。请确认各 TIFF 使用同一原点、像素网格和焦平面。\n\n"
                + urls.map(\.lastPathComponent).joined(separator: "\n")
            alert.addButton(withTitle: "打开")
            alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        openTask?.cancel()
        let token = UUID()
        loadID = token
        opening = true
        status = "正在读取切片元数据"
        openTask = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let reader: any SlideReader
                if urls.count == 1, urls[0].pathExtension.lowercased() == "mrxs" {
                    reader = try MRXSReader(url: urls[0])
                } else {
                    reader = try TiffReader(urls: urls)
                }
                try Task.checkCancellation()
                let session = SlideSession.location(for: urls)
                await self?.openFinished(reader, session: session, token: token)
            } catch is CancellationError {
                return
            } catch {
                await self?.openFailed(error.localizedDescription, token: token)
            }
        }
    }

    private func openFinished(_ value: any SlideReader, session: URL?, token: UUID) {
        guard token == loadID else { return }
        opening = false
        install(value, session: session)
    }

    private func openFailed(_ message: String, token: UUID) {
        guard token == loadID else { return }
        opening = false
        status = ""
        error = message
    }

    private func install(_ value: any SlideReader, session: URL? = nil) {
        flushSession()
        sessionURL = nil
        overviewTask?.cancel()
        cancelROI()
        inspector = .channels
        annotations = []
        manualCalibration = nil
        showScale = true
        restoredSettings = false
        tool = .pan
        cursor = nil
        renderError = nil
        overview = nil
        overviewThumbnail = nil
        thumbnail = nil
        selection = 0
        approximateOverview = false
        var initial = Viewport(size: viewport.size)
        if initial.size != .zero { initial.fit(value.info.base) }
        viewport = initial
        solo = nil
        displayDefaults = DisplayChannel.defaults(value.info)
        settings = displayDefaults
        reader = value
        documentID = UUID()
        status = "正在生成全片概览"
        if let session {
            do {
                if let saved = try SlideSession.load(from: session) {
                    annotations = Array(saved.annotations.prefix(256)).filter { $0.region.isValid(in: value.info.base) }
                    if saved.calibration?.valid == true { manualCalibration = saved.calibration }
                    showScale = saved.showScale
                    if saved.settings.count == displayDefaults.count,
                       zip(saved.settings, displayDefaults).allSatisfy({ style, baseline in
                           style.ceiling == baseline.ceiling && style.low >= 0 && style.high <= style.ceiling
                               && style.high - style.low >= 1 && (0.15...4).contains(style.gamma)
                               && (0...1).contains(style.color.x) && (0...1).contains(style.color.y)
                               && (0...1).contains(style.color.z)
                       }) {
                        settings = saved.settings
                        restoredSettings = true
                    }
                }
                sessionURL = session
            } catch {
                self.error = "无法读取这张切片的本机显示设置和 ROI。"
            }
        }
        let token = documentID
        overviewTask = Task.detached(priority: .utility) { [weak self] in
            do {
                let (image, approximate) = try readOverview(value)
                try Task.checkCancellation()
                await self?.previewFinished(image, approximate: approximate, token: token)
            } catch is CancellationError {
                return
            } catch {
                await self?.previewFailed(error.localizedDescription, token: token)
            }
        }
    }

    private func previewFinished(_ image: TilePixels, approximate: Bool, token: UUID) {
        guard token == documentID else { return }
        guard let reader else { return }
        if !reader.supportsRawExport {
            let original = displayDefaults
            var updated = settings
            for i in displayDefaults.indices {
                displayDefaults[i].autoContrast8Bit(image.channels[i])
                if !restoredSettings && settings[i].low == original[i].low && settings[i].high == original[i].high {
                    updated[i].low = displayDefaults[i].low
                    updated[i].high = displayDefaults[i].high
                }
            }
            settings = updated
        }
        overview = image
        overviewThumbnail = thumbnailPixels(image, channels: reader.info.channels)
        renderThumbnail()
        approximateOverview = approximate
        if !opening { status = "" }
    }

    private func queueSessionSave() {
        guard sessionURL != nil else { return }
        pendingSave?.cancel()
        pendingSave = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            self?.flushSession()
        }
    }

    func flushSession() {
        guard let url = sessionURL, pendingSave != nil else { return }
        pendingSave?.cancel()
        pendingSave = nil
        do {
            try SlideSession(settings: settings, annotations: annotations, calibration: manualCalibration,
                             showScale: showScale).save(to: url)
        } catch {
            status = "本机显示设置或 ROI 保存失败"
        }
    }

    private func renderThumbnail() {
        guard let preview = overviewThumbnail, settings.count == preview.channels.count else { return }
        let data = composeRGB(planes: preview.channels.map(Optional.some), settings: settings,
                              count: preview.width * preview.height, solo: solo)
        thumbnail = rgbImage(data, width: preview.width, height: preview.height)
    }

    private func previewFailed(_ message: String, token: UUID) {
        guard token == documentID else { return }
        if !opening { status = "" }
        reportRenderError(message)
    }

    func reportRenderError(_ message: String) {
        guard renderError != message else { return }
        let token = documentID
        DispatchQueue.main.async { [weak self] in
            guard self?.documentID == token, self?.renderError != message else { return }
            self?.renderError = message
        }
    }

    func resize(_ size: CGSize) {
        guard let level = reader?.info.base, size != viewport.size else { return }
        var state = viewport
        let wasEmpty = state.size == .zero
        let oldCenter = state.slidePoint(CGPoint(x: state.size.width / 2, y: state.size.height / 2))
        state.size = size
        if wasEmpty { state.fit(level) }
        else { state.center(oldCenter); state.constrain(level) }
        viewport = state
    }

    func fit() {
        guard let level = reader?.info.base else { return }
        viewport.fit(level)
    }

    func zoom(_ factor: Double, at point: CGPoint? = nil) {
        guard let level = reader?.info.base else { return }
        let anchor = point ?? CGPoint(x: viewport.size.width / 2, y: viewport.size.height / 2)
        viewport.magnify(factor, at: anchor, level: level)
        if let point { cursorAt(point) }
    }

    func navigate(x: Double, y: Double) {
        guard let level = reader?.info.base else { return }
        viewport.center(CGPoint(x: x * Double(level.width), y: y * Double(level.height)))
        viewport.constrain(level)
    }

    func cursorAt(_ viewPoint: CGPoint) {
        guard let level = reader?.info.base else { return }
        let p = viewport.slidePoint(viewPoint)
        cursor = p.x >= 0 && p.y >= 0 && p.x < Double(level.width) && p.y < Double(level.height) ? p : nil
    }

    private func l0(_ point: CGPoint) -> PointL0 {
        guard let level = reader?.info.base else { return PointL0(.zero) }
        let p = viewport.slidePoint(point)
        return PointL0(CGPoint(x: max(0, min(Double(level.width), p.x)),
                               y: max(0, min(Double(level.height), p.y))))
    }

    func pointerDown(_ point: CGPoint, clicks: Int) {
        switch tool {
        case .pan:
            if let region = selectedAnnotation?.region,
               let index = region.vertices.firstIndex(where: {
                   let p = viewport.viewPoint($0.point)
                   return hypot(p.x - point.x, p.y - point.y) <= 9
               }) {
                editingVertex = index
                editingRegion = region
            }
        case .rectangle, .line:
            selectedAnnotationID = nil
            draft = [l0(point), l0(point)]
        case .polygon:
            if clicks > 1 { finishPolygon(); return }
            selectedAnnotationID = nil
            if draft.count < 512 { draft.append(l0(point)) }
        }
    }

    func pointerDrag(from: CGPoint, to: CGPoint) {
        cursorAt(to)
        switch tool {
        case .pan:
            if let editingVertex, let region = editingRegion {
                var vertices = region.vertices
                vertices[editingVertex] = l0(to)
                editingRegion = Region(kind: region.kind, vertices: vertices)
                return
            }
            guard let level = reader?.info.base else { return }
            var state = viewport
            state.origin.x += to.x - from.x
            state.origin.y += to.y - from.y
            state.constrain(level)
            viewport = state
        case .rectangle, .line:
            if draft.count == 2 { draft[1] = l0(to) }
        case .polygon: break
        }
    }

    func pointerUp(_ point: CGPoint) {
        guard let base = reader?.info.base else { return }
        if let edited = editingRegion {
            if edited.isValid(in: base),
               let index = annotations.firstIndex(where: { $0.id == selectedAnnotationID }) {
                annotations[index].region = edited
            } else {
                status = "形状无效，已保留原选区"
            }
            editingRegion = nil
            editingVertex = nil
            return
        }
        guard tool == .rectangle || tool == .line, draft.count == 2 else { return }
        let shape = Region(kind: tool == .line ? .line : .rectangle, vertices: [draft[0], l0(point)])
        if shape.isValid(in: base) { addAnnotation(shape) }
        draft = []
    }

    func finishPolygon() {
        guard tool == .polygon, let base = reader?.info.base, draft.count >= 3 else { return }
        let shape = Region(kind: .polygon, vertices: draft)
        guard shape.isValid(in: base) else {
            status = "多边形顶点重复、面积为零或边线交叉，请按 Esc 后重画"
            return
        }
        addAnnotation(shape)
        draft = []
    }

    private func addAnnotation(_ region: Region) {
        guard annotations.count < 256 else {
            status = "本切片最多保存 256 个 ROI 或测量"
            return
        }
        let prefix = region.kind == .line ? "测距" : "ROI"
        let names = Set(annotations.map(\.name))
        let n = (1...257).first { !names.contains("\(prefix) \($0)") } ?? 257
        let annotation = Annotation(id: UUID(), name: "\(prefix) \(n)", region: region)
        annotations.append(annotation)
        selectAnnotation(annotation.id)
        status = ""
    }

    func selectAnnotation(_ id: UUID) {
        setTool(.pan)
        selectedAnnotationID = id
        inspector = .annotations
    }

    func renameAnnotation(_ id: UUID, to name: String) {
        guard let index = annotations.firstIndex(where: { $0.id == id }) else { return }
        annotations[index].name = String(name.prefix(80))
    }

    func locateAnnotation() {
        guard let selected = selectedAnnotation, let level = reader?.info.base else { return }
        let vertices = selected.region.vertices
        let x = (vertices.map(\.x).min()! + vertices.map(\.x).max()!) / 2
        let y = (vertices.map(\.y).min()! + vertices.map(\.y).max()!) / 2
        viewport.center(CGPoint(x: x, y: y))
        viewport.constrain(level)
    }

    func deleteAnnotation() {
        guard let id = selectedAnnotationID else { return }
        annotations.removeAll { $0.id == id }
        cancelROI()
    }

    func cancelROI() {
        selectedAnnotationID = nil
        draft = []
        editingVertex = nil
        editingRegion = nil
    }

    func setTool(_ newTool: Tool) {
        tool = newTool
        draft = []
        editingVertex = nil
        editingRegion = nil
        if newTool != .pan { inspector = .annotations }
    }

    func calibrate() {
        let alert = NSAlert()
        alert.messageText = "校准像素尺寸"
        alert.informativeText = "输入 level-0 像素尺寸（µm/px），用于标尺、距离和面积。请使用独立核验的数值。"
        let x = NSTextField(string: calibration.map { String($0.x) } ?? "")
        let y = NSTextField(string: calibration.map { String($0.y) } ?? "")
        let fields = NSStackView(views: [NSTextField(labelWithString: "X"), x, NSTextField(labelWithString: "Y"), y])
        fields.spacing = 8
        fields.frame = NSRect(x: 0, y: 0, width: 260, height: 26)
        x.widthAnchor.constraint(equalToConstant: 96).isActive = true
        y.widthAnchor.constraint(equalToConstant: 96).isActive = true
        alert.accessoryView = fields
        alert.addButton(withTitle: "应用")
        alert.addButton(withTitle: "取消")
        alert.window.initialFirstResponder = x
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let value = Calibration(x: Double(x.stringValue.trimmingCharacters(in: .whitespaces)),
                                      y: Double(y.stringValue.trimmingCharacters(in: .whitespaces)), source: .manual)
        else { error = "请输入有效的正数像素尺寸。"; return }
        manualCalibration = value
        showScale = true
    }

    func restoreCalibration() { manualCalibration = nil }

    func resetChannel(_ index: Int) {
        guard displayDefaults.indices.contains(index) else { return }
        var reset = displayDefaults[index]
        reset.visible = settings[index].visible
        settings[index] = reset
    }

    func autoContrast() {
        var updated = settings
        for index in displayDefaults.indices {
            updated[index].low = displayDefaults[index].low
            updated[index].high = displayDefaults[index].high
        }
        settings = updated
    }

    func save(_ format: ExportFormat) {
        guard exportProgress == nil, let reader, let annotation = selectedAnnotation,
              annotation.region.kind != .line else { return }
        let scale = calibration
        let annotate = showScale && format != .raw
        let panel = NSSavePanel()
        panel.title = "导出 ROI"
        panel.message = "将图像、ROI JSON 与 CSV 存入一个新目录。"
        panel.nameFieldStringValue = format == .raw ? "ROI-Raw" : "ROI-Rendered"
        panel.canCreateDirectories = true
        panel.begin { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            self.export(reader: reader, annotation: annotation, format: format, url: url,
                        calibration: scale, includeScale: annotate)
        }
    }

    private func export(reader: any SlideReader, annotation: Annotation, format: ExportFormat, url: URL,
                        calibration: Calibration?, includeScale: Bool) {
        guard exportProgress == nil, self.reader === reader else { return }
        let styles = settings
        let isolated = solo
        exportProgress = 0
        exportTask = Task.detached(priority: .utility) { [weak self] in
            do {
                try ROIExporter.export(reader: reader, region: annotation.region, format: format,
                                       settings: styles, solo: isolated, destination: url,
                                       annotationName: annotation.name, calibration: calibration,
                                       includeScale: includeScale) { [weak self] value in
                    Task { @MainActor in
                        if self?.exportProgress != nil { self?.exportProgress = value }
                    }
                }
                await self?.exportFinished("ROI 已导出")
            } catch is CancellationError {
                await self?.exportFinished("ROI 导出已取消")
            } catch {
                await self?.exportFinished(nil, error: error.localizedDescription)
            }
        }
    }

    func cancelExport() { exportTask?.cancel() }

    private func exportFinished(_ message: String?, error: String? = nil) {
        exportProgress = nil
        if let message { status = message }
        if let error { self.error = error }
    }
}
