import AppKit
import SwiftUI

@MainActor
final class UpdateController: ObservableObject {
    @Published var automatic = UserDefaults.standard.object(forKey: "automaticUpdateChecks") as? Bool ?? true {
        didSet { UserDefaults.standard.set(automatic, forKey: "automaticUpdateChecks") }
    }
    @Published private(set) var working = false

    private let bundle = Bundle.main
    private var offeredVersion: String?

    func monitor(model: ViewerModel) async {
        do {
            try await Task.sleep(for: .seconds(6))
            while !Task.isCancelled {
                if automatic { await check(manual: false, model: model) }
                try await Task.sleep(for: .seconds(6 * 60 * 60))
            }
        } catch {}
    }

    func check(manual: Bool, model: ViewerModel) async {
        guard !working, let version = bundle.infoDictionary?["CFBundleShortVersionString"] as? String,
              let key = bundle.infoDictionary?["MIFUpdatePublicKey"] as? String,
              let id = bundle.bundleIdentifier else { return }
        working = true
        defer { working = false }
        var accepted = false
        do {
            guard let update = try await ReleaseUpdate.latest(after: version) else {
                if manual { show("已是最新版本", "当前版本为 \(version)。") }
                return
            }
            guard manual || (automatic && offeredVersion != update.version && canPresent) else { return }
            offeredVersion = update.version
            let alert = NSAlert()
            alert.messageText = "发现新版本 \(update.version)"
            alert.informativeText = "当前版本为 \(version)。下载并验证后，应用会重启以完成更新。"
            alert.addButton(withTitle: "下载并重启")
            alert.addButton(withTitle: "稍后")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            accepted = true
            guard model.canRestartForUpdate else { throw ReleaseUpdate.Failure.busy }
            let installed = bundle.bundleURL
            let staged = try await Task.detached(priority: .utility) {
                try await update.stage(beside: installed, bundleID: id, key: key)
            }.value
            defer { staged.discard() }
            guard canPresent, model.canRestartForUpdate else { throw ReleaseUpdate.Failure.busy }
            guard model.flushSession() else {
                show("暂缓安装更新", "切片设置或 ROI 保存失败。请处理后重新检查更新。")
                return
            }
            let willRelaunch = try staged.install(at: installed, currentVersion: version)
            if !willRelaunch {
                show("更新已安装", "请重新打开 Mac MIF Viewer。")
            }
            staged.discard()
            NSApp.terminate(nil)
        } catch {
            if (manual || accepted) && !Task.isCancelled && canPresent {
                show("更新未完成", error.localizedDescription, fallback: true)
            }
        }
    }

    private var canPresent: Bool {
        NSApp.modalWindow == nil && !NSApp.windows.contains { $0.attachedSheet != nil }
    }

    private func show(_ title: String, _ message: String, fallback: Bool = false) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        if fallback { alert.addButton(withTitle: "打开下载页面") }
        if alert.runModal() == .alertSecondButtonReturn {
            NSWorkspace.shared.open(ReleaseUpdate.releasesPage)
        }
    }
}
