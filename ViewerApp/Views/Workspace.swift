import SwiftUI

private let accent = Color(red: 0.32, green: 0.87, blue: 0.74)
private let panel = Color(red: 0.083, green: 0.102, blue: 0.143)
private let edge = Color.white.opacity(0.10)

private let channelPalette: [(name: String, rgb: SIMD3<Float>)] = [
    ("红", [1, 0, 0]), ("绿", [0, 1, 0]), ("蓝", [0, 0, 1]),
    ("品红", [1, 0, 1]), ("青", [0, 1, 1]), ("黄", [1, 1, 0]), ("白", [1, 1, 1]),
]

struct Workspace: View {
    @ObservedObject var model: ViewerModel

    var body: some View {
        VStack(spacing: 0) {
            topbar
            Divider()
            HStack(spacing: 0) {
                canvas
                Divider()
                inspector.frame(width: 284)
            }
            Divider()
            statusBar
        }
        .background(panel)
        .preferredColorScheme(.dark)
        .tint(accent)
        .frame(minWidth: 920, minHeight: 650)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            model.flushSession()
        }
        .alert("Mac MIF Viewer", isPresented: Binding(
            get: { model.error != nil },
            set: { if !$0 { model.error = nil } }
        )) {
            Button("好") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }

    private var topbar: some View {
        HStack(spacing: 14) {
            HStack(spacing: 9) {
                Image(systemName: "square.stack.3d.up.fill").foregroundStyle(accent).font(.title3)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Mac MIF Viewer").font(.system(size: 14, weight: .semibold))
                    Text("本地荧光切片工作台").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            Button("打开切片…", systemImage: "folder") { model.openPanel() }
                .keyboardShortcut("o")
            Button("演示") { model.showDemo() }
            Spacer(minLength: 0)
            HStack(spacing: 4) {
                Button { model.zoom(0.8) } label: { Image(systemName: "minus.magnifyingglass") }
                    .help("缩小")
                Button("适合窗口") { model.fit() }
                Button { model.zoom(1.25) } label: { Image(systemName: "plus.magnifyingglass") }
                    .help("放大")
            }
            Picker("ROI 工具", selection: Binding(get: { model.tool }, set: model.setTool)) {
                ForEach(ViewerModel.Tool.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 208)
            Menu {
                Toggle("显示标尺", isOn: $model.showScale)
                Button("校准像素尺寸…") { model.calibrate() }
                if model.manualCalibration != nil {
                    Button("恢复文件标尺") { model.restoreCalibration() }
                }
            } label: { Label("标尺", systemImage: "ruler") }
                .help("显示或校准标尺")
            Menu {
                ForEach(ExportFormat.allCases) { format in
                    Button(format.rawValue + (model.showScale && format != .raw ? " ＋ 标尺" : "")) {
                        model.save(format)
                    }
                        .disabled(format == .raw && model.reader?.supportsRawExport == false)
                }
            } label: { Label("导出 ROI", systemImage: "square.and.arrow.up") }
                .disabled(model.region == nil || model.exportProgress != nil)
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 12)
    }

    private var canvas: some View {
        ZStack(alignment: .topLeading) {
            Color(red: 0.024, green: 0.031, blue: 0.049)
            SlideCanvas(model: model).id(model.documentID)
            roiOverlay.allowsHitTesting(false)
            VStack(alignment: .leading, spacing: 7) {
                if let info = model.reader?.info {
                    Text(info.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text("\(info.mode)  /  \(info.channels.count) 通道  /  \(info.base.width) × \(info.base.height) px")
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                    if model.reader?.supportsRawExport == false {
                        Text("槽位和坐标待厂商核对 · 未扫描区域显示为黑色")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
                if let error = model.renderError {
                    Text(error).foregroundStyle(.orange).font(.caption).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(11)
            .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 8))
            .padding(14)
            .allowsHitTesting(false)
        }
        .overlay(alignment: .bottomLeading) { scaleBar.padding(14).allowsHitTesting(false) }
        .overlay(alignment: .bottomTrailing) {
            if model.tool == .polygon && !model.draft.isEmpty {
                HStack {
                    Text("\(model.draft.count) 个顶点").font(.caption)
                    Button("完成多边形") { model.finishPolygon() }.disabled(model.draft.count < 3)
                }
                .padding(9).background(.black.opacity(0.80), in: RoundedRectangle(cornerRadius: 8)).padding(14)
            }
        }
        .accessibilityIdentifier("slideCanvas")
    }

    private var roiOverlay: some View {
        let viewport = model.viewport
        return Canvas { context, _ in
            func draw(_ region: Region, selected: Bool, isDraft: Bool) {
                let points = region.vertices.map { viewport.viewPoint($0.point) }
                guard let first = points.first else { return }
                var path = Path()
                if region.kind == .rectangle, points.count == 2 {
                    let other = points[1]
                    path.addRect(CGRect(x: min(first.x, other.x), y: min(first.y, other.y),
                                        width: abs(first.x - other.x), height: abs(first.y - other.y)))
                } else {
                    path.move(to: first)
                    for point in points.dropFirst() { path.addLine(to: point) }
                    if region.kind == .polygon && !isDraft { path.closeSubpath() }
                }
                let color = region.kind == .line ? Color.yellow : accent
                if selected && region.kind != .line && (region.kind == .rectangle || !isDraft) {
                    context.fill(path, with: .color(color.opacity(0.12)))
                }
                context.stroke(path, with: .color(color.opacity(selected ? 1 : 0.60)),
                               style: StrokeStyle(lineWidth: selected ? 1.8 : 1, dash: isDraft ? [5, 3] : []))
                if selected {
                    for point in points {
                        context.fill(Path(ellipseIn: CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)),
                                     with: .color(color))
                    }
                }
            }
            for annotation in model.annotations where annotation.id != model.selectedAnnotationID {
                draw(annotation.region, selected: false, isDraft: false)
            }
            if let current = model.editingRegion ?? model.selectedAnnotation?.region {
                draw(current, selected: true, isDraft: false)
            }
            if !model.draft.isEmpty {
                let kind: Region.Kind = model.tool == .rectangle ? .rectangle : model.tool == .line ? .line : .polygon
                draw(Region(kind: kind, vertices: model.draft), selected: true, isDraft: true)
            }
        }
    }

    @ViewBuilder private var scaleBar: some View {
        if model.showScale, let mark = ScaleMark(zoom: model.viewport.zoom, target: 104, calibration: model.calibration) {
            VStack(alignment: .leading, spacing: 4) {
                Text(mark.label).font(.system(size: 11, weight: .medium, design: .monospaced))
                Rectangle().fill(.white).frame(width: mark.width, height: 2)
                if model.calibration?.source == .provisionalMetadata {
                    Text("文件标尺 · 待核验").font(.system(size: 9)).foregroundStyle(.orange)
                }
            }
            .padding(8).background(.black.opacity(0.76), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private var inspector: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                sectionTitle("全片导航", icon: "viewfinder")
                overviewMap
            }.padding(13)
            Divider()
            Picker("侧栏", selection: $model.inspector) {
                ForEach(ViewerModel.Inspector.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden().pickerStyle(.segmented).padding(10)
            if model.inspector == .annotations {
                annotationPanel
            } else {
                channelPanel
            }
        }
        .background(panel)
    }

    private var channelPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                sectionTitle("荧光通道", icon: "circle.hexagongrid.fill")
                Spacer()
                Button("Merge") { model.solo = nil }
                    .tint(model.solo == nil ? accent : .secondary)
            }
            .padding(.horizontal, 13).padding(.vertical, 8)
            ScrollView {
                VStack(spacing: 5) {
                    ForEach(model.settings.indices, id: \.self) { row($0) }
                }.padding(.horizontal, 10)
            }
            Divider()
            if model.settings.indices.contains(model.selection) {
                adjustments(model.selection).padding(13)
            }
        }
    }

    private var annotationPanel: some View {
        VStack(alignment: .leading, spacing: 9) {
            sectionTitle("ROI 与测量", icon: "square.dashed")
            Text("矩形与测距可拖画，多边形点选后按 Return。选中条目后可拖动顶点。")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if model.annotations.isEmpty {
                Spacer()
                Text("还没有 ROI 或测量").font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(model.annotations) { item in
                            Button {
                                model.selectAnnotation(item.id)
                            } label: {
                                HStack {
                                    Image(systemName: item.region.kind == .line ? "ruler" : "square.dashed")
                                    Text(item.name.isEmpty ? "未命名" : item.name).lineLimit(1)
                                    Spacer(minLength: 4)
                                    Text(item.region.measurement(calibration: model.calibration).label)
                                        .monospacedDigit().foregroundStyle(.secondary)
                                }
                                .padding(7).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain).font(.caption)
                            .background(item.id == model.selectedAnnotationID ? accent.opacity(0.14) : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 5))
                        }
                    }
                }
            }
            if let selected = model.selectedAnnotation {
                Divider()
                TextField("名称", text: Binding(
                    get: { model.selectedAnnotation?.id == selected.id ? model.selectedAnnotation?.name ?? "" : "" },
                    set: { model.renameAnnotation(selected.id, to: $0) }
                )).accessibilityLabel("ROI 名称")
                HStack {
                    Button("定位") { model.locateAnnotation() }
                    Spacer()
                    Button("删除", role: .destructive) { model.deleteAnnotation() }
                }
            }
        }
        .padding(.horizontal, 13).padding(.bottom, 13)
    }

    private func sectionTitle(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon).font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white.opacity(0.88))
    }

    private var overviewMap: some View {
        GeometryReader { proxy in
            if let info = model.reader?.info, let cg = model.thumbnail {
                let aspect = Double(info.base.width) / Double(info.base.height)
                let width = min(proxy.size.width, proxy.size.height * aspect)
                let height = width / aspect
                let x = (proxy.size.width - width) / 2
                let y = (proxy.size.height - height) / 2
                let visible = model.viewport.visible
                ZStack(alignment: .topLeading) {
                    Image(decorative: cg, scale: 1).resizable().interpolation(.none)
                        .frame(width: width, height: height).offset(x: x, y: y)
                    let rect = CGRect(x: visible.minX / Double(info.base.width) * width,
                                      y: visible.minY / Double(info.base.height) * height,
                                      width: visible.width / Double(info.base.width) * width,
                                      height: visible.height / Double(info.base.height) * height)
                        .intersection(CGRect(x: 0, y: 0, width: width, height: height))
                    if !rect.isNull {
                        Rectangle().stroke(accent, lineWidth: 1)
                            .frame(width: rect.width, height: rect.height)
                            .offset(x: x + rect.minX, y: y + rect.minY)
                    }
                    if model.approximateOverview {
                        Text("稀疏概览").font(.system(size: 9)).padding(4)
                            .background(.black.opacity(0.7)).padding(4)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                    model.navigate(x: min(1, max(0, (v.location.x - x) / width)),
                                   y: min(1, max(0, (v.location.y - y) / height)))
                })
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(height: 120)
        .background(.black.opacity(0.52), in: RoundedRectangle(cornerRadius: 6))
        .clipped()
    }

    private func row(_ index: Int) -> some View {
        let channel = model.reader!.info.channels[index]
        let style = model.settings[index]
        return HStack(spacing: 8) {
            Button {
                model.settings[index].visible.toggle()
            } label: {
                Image(systemName: style.visible ? "eye.fill" : "eye.slash")
                    .foregroundStyle(style.visible ? accent : .secondary)
            }
            .buttonStyle(.plain)
            .help("切换通道可见性")
            Button {
                model.selection = index
            } label: {
                HStack(spacing: 7) {
                    Circle().fill(swatch(style.color)).frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(channel.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        Text(channel.source + "  ·  " + channel.type.rawValue)
                            .font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button(model.solo == index ? "单显中" : "单显") {
                model.solo = model.solo == index ? nil : index
                model.selection = index
            }
            .font(.system(size: 9))
            .help("只显示当前通道")
        }
        .padding(7)
        .background(model.selection == index ? accent.opacity(0.10) : Color.white.opacity(0.026),
                    in: RoundedRectangle(cornerRadius: 7))
    }

    private func swatch(_ rgb: SIMD3<Float>) -> Color {
        Color(.sRGB, red: Double(rgb.x), green: Double(rgb.y), blue: Double(rgb.z), opacity: 1)
    }

    private func adjustments(_ i: Int) -> some View {
        let style = model.settings[i]
        let color = Binding(get: { swatch(model.settings[i].color) }, set: { color in
            if let rgb = NSColor(color).usingColorSpace(.sRGB) {
                let components = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent].map {
                    Float(min(1, max(0, $0)))
                }
                model.settings[i].color = SIMD3(components[0], components[1], components[2])
            }
        })
        let low = Binding(get: { model.settings[i].low }, set: { value in
            model.settings[i].low = min(value, model.settings[i].high - 1)
        })
        let high = Binding(get: { model.settings[i].high }, set: { value in
            model.settings[i].high = max(value, model.settings[i].low + 1)
        })
        return VStack(alignment: .leading, spacing: 7) {
            HStack {
                sectionTitle("显示参数", icon: "slider.horizontal.3")
                Spacer()
                if model.reader?.supportsRawExport == false {
                    Button("自动对比度") { model.autoContrast() }.font(.caption)
                        .disabled(model.overview == nil)
                }
                Button("重置") { model.resetChannel(i) }.font(.caption)
            }
            Picker("映射", selection: $model.settings[i].palette) {
                ForEach(DisplayChannel.Palette.allCases, id: \.self) { Text($0.label).tag($0) }
            }.labelsHidden().pickerStyle(.segmented)
            if style.palette == .tint {
            HStack {
                Text(model.reader?.info.channels[i].name ?? "当前通道")
                    .font(.caption.weight(.semibold)).lineLimit(1)
                Spacer()
                ColorPicker("自定义伪彩", selection: color, supportsOpacity: false)
                    .labelsHidden()
                    .help("打开系统色板")
            }
            HStack(spacing: 8) {
                ForEach(channelPalette.indices, id: \.self) { index in
                    let preset = channelPalette[index]
                    Button {
                        model.settings[i].color = preset.rgb
                    } label: {
                        Circle().fill(swatch(preset.rgb))
                            .frame(width: 14, height: 14)
                            .padding(4)
                            .overlay {
                                Circle().strokeBorder(style.color == preset.rgb ? .white : edge, lineWidth: 1)
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("预设" + preset.name)
                    .help(preset.name + "色")
                }
            }
            rgbSlider("红色", component: 0, channel: i, tint: .red)
            rgbSlider("绿色", component: 1, channel: i, tint: .green)
            rgbSlider("蓝色", component: 2, channel: i, tint: .blue)
            }
            Divider()
            slider("黑点", value: low, range: 0...style.ceiling, display: String(Int(style.low)))
            slider("白点", value: high, range: 0...style.ceiling, display: String(Int(style.high)))
            slider("Gamma", value: $model.settings[i].gamma, range: 0.15...4,
                   display: String(format: "%.2f", style.gamma))
        }
    }

    private func rgbSlider(_ label: String, component: Int, channel: Int, tint: Color) -> some View {
        let value = Binding(
            get: { model.settings[channel].color[component] * 255 },
            set: { model.settings[channel].color[component] = min(255, max(0, $0.rounded())) / 255 }
        )
        return slider(label, value: value, range: 0...255,
                      display: String(Int(value.wrappedValue.rounded())), tint: tint)
    }

    private func slider(_ label: String, value: Binding<Float>, range: ClosedRange<Float>,
                        display: String, tint: Color = accent) -> some View {
        HStack(spacing: 5) {
            Text(label).frame(width: 43, alignment: .leading)
            Slider(value: value, in: range) { Text(label) }
                .labelsHidden().controlSize(.mini).tint(tint)
                .accessibilityLabel(label)
                .accessibilityValue(display)
            Text(display).monospacedDigit().frame(width: 43, alignment: .trailing)
                .accessibilityHidden(true)
        }.font(.system(size: 10)).foregroundStyle(.secondary)
    }

    private var statusBar: some View {
        HStack(spacing: 14) {
            if let p = model.cursor {
                Text("X \(Int(p.x))  Y \(Int(p.y)) px")
                if let scale = model.calibration {
                    Text(String(format: "X %.1f  Y %.1f µm", p.x * scale.x, p.y * scale.y))
                }
            } else { Text("L0 坐标") }
            Text(String(format: "%.1f%%", model.viewport.zoom * 100))
            Text(model.calibration?.source.label ?? "像素标尺")
                .foregroundStyle(model.calibration?.source == .provisionalMetadata ? .orange : .secondary)
            if let base = model.reader?.info.base, let roi = model.region?.bounds(in: base) {
                Text("ROI \(roi.width) × \(roi.height) px").foregroundStyle(accent)
            }
            if let annotation = model.selectedAnnotation {
                Text(annotation.region.measurement(calibration: model.calibration).label).foregroundStyle(accent)
            }
            Spacer()
            if let progress = model.exportProgress {
                ProgressView(value: progress).frame(width: 90)
                Button("取消导出") { model.cancelExport() }
            } else if !model.status.isEmpty {
                Text(model.status)
            } else if model.approximateOverview, let info = model.reader?.info,
                      visibleTiles(info: info, viewport: model.viewport).isEmpty {
                Text("稀疏概览 · 放大查看实际像素")
            }
        }
        .font(.system(size: 10, design: .monospaced))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12).frame(height: 27)
    }
}
