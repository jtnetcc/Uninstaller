import AppKit
import Foundation

/// 应用扫描器：枚举系统中的 .app 包，读取元数据并统计磁盘占用。
struct AppScanner {

    // MARK: 扫描根目录

    static var scanRoots: [URL] {
        var roots: [URL] = [URL(fileURLWithPath: "/Applications", isDirectory: true)]
        let home = FileManager.default.homeDirectoryForCurrentUser
        roots.append(home.appendingPathComponent("Applications", isDirectory: true))
        // macOS 11+ 系统应用独立于只读系统卷
        roots.append(URL(fileURLWithPath: "/System/Applications", isDirectory: true))
        return roots.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    // MARK: 主入口

    /// 全量扫描（耗时操作，请在后台调用）
    /// - Parameter progress: 0...1 的进度回调（在后台线程调用）
    static func scan(progress: ((Double) -> Void)? = nil) -> [InstalledApp] {
        progress?(0.02)
        let bundles = discoverBundles()
        guard !bundles.isEmpty else {
            progress?(1.0)
            return []
        }
        progress?(0.08)

        // 并发统计体积
        var sizes = [Int64](repeating: 0, count: bundles.count)
        let lock = NSLock()
        var completed = 0
        let total = bundles.count

        DispatchQueue.concurrentPerform(iterations: total) { i in
            let s = directorySize(bundles[i])
            lock.lock()
            sizes[i] = s
            completed += 1
            let ratio = 0.08 + 0.87 * (Double(completed) / Double(total))
            lock.unlock()
            if completed % 3 == 0 || completed == total {
                progress?(min(ratio, 0.95))
            }
        }

        // 组装模型
        var apps: [InstalledApp] = []
        apps.reserveCapacity(bundles.count)
        for (i, url) in bundles.enumerated() {
            if let app = makeApp(url: url, size: sizes[i]) {
                apps.append(app)
            }
        }
        progress?(1.0)
        return apps.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: 枚举 .app 包

    static func discoverBundles() -> [URL] {
        var result: [URL] = []
        var seen = Set<String>()
        let fm = FileManager.default

        for root in scanRoots {
            guard let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [],
                errorHandler: { _, _ in true }
            ) else { continue }

            let rootDepth = root.pathComponents.count
            while let obj = enumerator.nextObject() {
                guard let url = obj as? URL else { continue }
                let depth = url.pathComponents.count - rootDepth
                // 限制递归深度，避免扫描到深层嵌套目录
                if depth > 3 {
                    enumerator.skipDescendants()
                    continue
                }
                if url.pathExtension.lowercased() == "app" {
                    let std = url.standardizedFileURL.path
                    if seen.insert(std).inserted {
                        result.append(url)
                    }
                    // 关键：不进入 .app 内部，避免把内嵌 helper 当成独立应用
                    enumerator.skipDescendants()
                }
            }
        }
        return result
    }

    // MARK: 体积统计

    /// 统计目录（应用包）实际占用空间，基于 allocated size
    static func directorySize(_ url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey]
        var total: Int64 = 0
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: [],
            errorHandler: { _, _ in true }
        ) else {
            return fallbackSize(url)
        }

        while let obj = enumerator.nextObject() {
            guard let fileURL = obj as? URL else { continue }
            guard let values = try? fileURL.resourceValues(forKeys: keys) else { continue }
            if values.isRegularFile == true {
                total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
            }
        }
        return total > 0 ? total : fallbackSize(url)
    }

    private static func fallbackSize(_ url: URL) -> Int64 {
        let v = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
        return Int64(v?.totalFileAllocatedSize ?? v?.fileSize ?? 0)
    }

    /// 计算任意路径（文件或目录）的体积
    static func sizeOfPath(_ url: URL) -> Int64 {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
        if isDir.boolValue {
            return directorySize(url)
        }
        let v = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
        return Int64(v?.totalFileAllocatedSize ?? v?.fileSize ?? 0)
    }

    // MARK: 单个应用元数据

    static func makeApp(url: URL, size: Int64) -> InstalledApp? {
        let info = readInfoPlist(url)
        let fm = FileManager.default

        var name = info?["CFBundleDisplayName"] as? String
            ?? info?["CFBundleName"] as? String
            ?? url.deletingPathExtension().lastPathComponent
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { name = url.deletingPathExtension().lastPathComponent }

        let bundleID = info?["CFBundleIdentifier"] as? String
        let shortVersion = info?["CFBundleShortVersionString"] as? String
        let buildVersion = info?["CFBundleVersion"] as? String
        let executable = info?["CFBundleExecutable"] as? String
        let minSystem = info?["LSMinimumSystemVersion"] as? String

        let values = try? url.resourceValues(forKeys: [
            .contentModificationDateKey, .creationDateKey, .isSymbolicLinkKey
        ])

        // 来源判定
        let masReceipt = url.appendingPathComponent("Contents/_MASReceipt/receipt")
        let isMAS = fm.fileExists(atPath: masReceipt.path)
        let source: AppSource
        if url.path.hasPrefix("/System/") {
            source = .systemBuiltin
        } else if isMAS {
            source = .appStore
        } else if url.path.hasPrefix("/Applications/") || url.path.hasPrefix(homeApplicationsPath) {
            source = .userInstalled
        } else {
            source = .other
        }

        let decision = ProtectionPolicy.evaluate(path: url.path, bundleID: bundleID, name: name)

        return InstalledApp(
            path: url.standardizedFileURL.path,
            name: name,
            bundleID: bundleID,
            shortVersion: shortVersion,
            buildVersion: buildVersion,
            executableName: executable,
            sizeBytes: size,
            modifiedDate: values?.contentModificationDate,
            createdDate: values?.creationDate,
            source: source,
            architectures: architectures(of: url),
            minimumSystemVersion: minSystem,
            isAppStoreSigned: isMAS,
            removalScope: decision.scope,
            protectionReason: decision.reason
        )
    }

    private static var homeApplicationsPath: String {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path
    }

    static func readInfoPlist(_ appURL: URL) -> [String: Any]? {
        let infoURL = appURL.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: infoURL) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any]
    }

    /// 读取可执行文件架构（arm64 / x86_64 / Universal）
    static func architectures(of appURL: URL) -> [String] {
        guard let bundle = Bundle(url: appURL),
              let archs = bundle.executableArchitectures else { return [] }
        var names: [String] = []
        for number in archs {
            switch number.int32Value {
            case 0x0100_000C: names.append("arm64")
            case 0x0100_0007: names.append("x86_64")
            case 7:           names.append("i386")
            case 12:          names.append("arm")
            default:          break
            }
        }
        if names.contains("arm64") && names.contains("x86_64") {
            return ["Universal"]
        }
        return names.isEmpty ? ["未知"] : names
    }

    // MARK: 缓存

    static var cacheURL: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("com.jt.AppUninstaller", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("inventory-v2.json")
    }

    static func loadCache() -> [InstalledApp] {
        guard let data = try? Data(contentsOf: cacheURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([InstalledApp].self, from: data)) ?? []
    }

    static func saveCache(_ apps: [InstalledApp]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(apps) else { return }
        try? data.write(to: cacheURL, options: .atomic)
    }
}

// MARK: - 图标缓存

@MainActor
final class IconProvider {
    static let shared = IconProvider()
    private var cache: [String: NSImage] = [:]

    func icon(for path: String, size: CGFloat = 32) -> NSImage {
        let key = "\(path)#\(Int(size))"
        if let img = cache[key] { return img }
        let img = NSWorkspace.shared.icon(forFile: path)
        img.size = NSSize(width: size, height: size)
        cache[key] = img
        return img
    }
}
