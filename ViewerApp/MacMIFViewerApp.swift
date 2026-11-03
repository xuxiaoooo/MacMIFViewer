import SwiftUI

@main
struct MacMIFViewerApp: App {
    @StateObject private var model = ViewerModel()

    var body: some Scene {
        Window("Mac MIF Viewer", id: "viewer") {
            Workspace(model: model)
                .onOpenURL { url in model.open([url]) }
        }
        .defaultSize(width: 1250, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("打开切片…") { model.openPanel() }.keyboardShortcut("o")
                Button("打开六通道演示") { model.showDemo() }
            }
            CommandMenu("查看") {
                Button("适合窗口") { model.fit() }.keyboardShortcut("0")
                Button("放大") { model.zoom(1.25) }.keyboardShortcut("+")
                Button("缩小") { model.zoom(0.8) }.keyboardShortcut("-")
            }
        }
    }
}
