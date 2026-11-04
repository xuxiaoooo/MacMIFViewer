import CryptoKit
import Darwin
import Foundation

struct ReleaseUpdate {
    static let repository = "https://github.com/xuxiaoooo/MacMIFViewer"
    static let releasesPage = URL(string: repository + "/releases/latest")!
    private static let api = URL(string: "https://api.github.com/repos/xuxiaoooo/MacMIFViewer/releases/latest")!
    private static let maxArchiveSize = 32 << 20

    enum Failure: LocalizedError {
        case response, assets, signature, bundle, location, busy

        var errorDescription: String? {
            switch self {
            case .response: return "无法读取 GitHub 发布信息，请稍后重试。"
            case .assets: return "该版本缺少可自动安装的 arm64 安装包或发布签名。"
            case .signature: return "安装包发布签名验证失败，已停止更新。"
            case .bundle: return "安装包内的应用版本、身份或代码签名验证失败。"
            case .location: return "无法替换此位置的应用。请将应用移到「应用程序」并重新打开，或从 GitHub 下载新版。"
            case .busy: return "请先完成当前的切片操作或 ROI 导出，再安装更新。"
            }
        }
    }

    struct Version: Comparable {
        let parts: [Int]

        init?(_ value: String) {
            let fields = value.split(separator: ".", omittingEmptySubsequences: false)
            guard fields.count == 3 else { return nil }
            parts = fields.compactMap { Int($0) }
            guard parts.count == 3, parts.map(String.init).joined(separator: ".") == value,
                  parts.allSatisfy({ $0 >= 0 }) else { return nil }
        }

        static func < (lhs: Version, rhs: Version) -> Bool {
            lhs.parts.lexicographicallyPrecedes(rhs.parts)
        }
    }

    struct Release: Decodable {
        struct Asset: Decodable {
            let name: String
            let size: Int
            let state: String
        }

        let tag_name: String
        let draft: Bool
        let prerelease: Bool
        let assets: [Asset]

        func update(after current: String) throws -> ReleaseUpdate? {
            guard !draft, !prerelease else { return nil }
            let version = String(tag_name.dropFirst())
            guard tag_name.hasPrefix("v"), let next = Version(version), let installed = Version(current) else {
                throw Failure.response
            }
            guard next > installed else { return nil }
            let zip = "Mac-MIF-Viewer-\(version)-arm64.zip"
            guard let archive = assets.first(where: { $0.name == zip && $0.state == "uploaded" }),
                  (1...maxArchiveSize).contains(archive.size),
                  assets.contains(where: { $0.name == zip + ".sig" && $0.state == "uploaded" && $0.size == 64 }) else {
                throw Failure.assets
            }
            let base = URL(string: repository + "/releases/download/")!.appendingPathComponent(tag_name)
            return ReleaseUpdate(version: version, archive: base.appendingPathComponent(zip), size: archive.size)
        }
    }

    let version: String
    let archive: URL
    let size: Int

    static func latest(after current: String) async throws -> ReleaseUpdate? {
        var request = URLRequest(url: api, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 1 << 20 else {
            throw Failure.response
        }
        return try JSONDecoder().decode(Release.self, from: data).update(after: current)
    }

    private func download(_ url: URL, size: Int) async throws -> URL {
        let (file, response) = try await URLSession.shared.download(for: URLRequest(url: url, timeoutInterval: 30))
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              try file.resourceValues(forKeys: [.fileSizeKey]).fileSize == size else {
            try? FileManager.default.removeItem(at: file)
            throw Failure.assets
        }
        return file
    }

    static func verify(_ archive: URL, signature: Data, key: String) throws {
        guard let bytes = Data(base64Encoded: key),
              let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: bytes),
              publicKey.isValidSignature(signature, for: try Data(contentsOf: archive, options: .mappedIfSafe)) else {
            throw Failure.signature
        }
    }

    func stage(beside installed: URL, bundleID: String, key: String) async throws -> StagedUpdate {
        let files = FileManager.default
        guard !installed.pathComponents.contains("AppTranslocation"),
              files.isWritableFile(atPath: installed.deletingLastPathComponent().path) else {
            throw Failure.location
        }
        let signatureFile = try await download(archive.appendingPathExtension("sig"), size: 64)
        defer { try? files.removeItem(at: signatureFile) }
        let zip = try await download(archive, size: size)
        defer { try? files.removeItem(at: zip) }
        try Self.verify(zip, signature: Data(contentsOf: signatureFile), key: key)

        let directory: URL
        do {
            directory = try files.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                      appropriateFor: installed, create: true)
        } catch { throw Failure.location }
        let app = directory.appendingPathComponent("Mac MIF Viewer.app", isDirectory: true)
        do {
            try Self.run("/usr/bin/ditto", ["-x", "-k", zip.path, directory.path])
            let info = try Self.info(at: app)
            guard info["CFBundleIdentifier"] as? String == bundleID,
                  info["CFBundleShortVersionString"] as? String == version,
                  info["MIFUpdatePublicKey"] as? String == key,
                  Bundle(url: app)?.executableArchitectures?.contains(NSNumber(value: NSBundleExecutableArchitectureARM64)) == true else {
                throw Failure.bundle
            }
            try Self.run("/usr/bin/codesign", ["--verify", "--strict", app.path])
            return StagedUpdate(app: app, directory: directory)
        } catch {
            try? files.removeItem(at: directory)
            throw error
        }
    }

    private static func run(_ path: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw Failure.bundle }
    }

    fileprivate static func info(at app: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        guard let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw Failure.bundle
        }
        return info
    }
}

struct StagedUpdate {
    let app: URL
    let directory: URL

    func discard() { try? FileManager.default.removeItem(at: directory) }

    func install(at installed: URL, currentVersion: String) throws -> Bool {
        guard try ReleaseUpdate.info(at: installed)["CFBundleShortVersionString"] as? String == currentVersion else {
            throw ReleaseUpdate.Failure.location
        }
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = ["-c", """
            for i in $(/usr/bin/seq 1 120); do
                /bin/kill -0 "$1" 2>/dev/null || exec /usr/bin/open -n "$2"
                /bin/sleep 0.25
            done
            """, "mif-relaunch", String(ProcessInfo.processInfo.processIdentifier), installed.path]

        // Exchange the two bundles on the same volume without leaving the app path empty.
        guard renamex_np(app.path, installed.path, UInt32(RENAME_SWAP)) == 0 else {
            throw ReleaseUpdate.Failure.location
        }
        do {
            try relaunch.run()
            return true
        } catch {
            return false
        }
    }
}
