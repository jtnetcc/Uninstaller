import Foundation

/// 残留数据扫描器：根据 bundleID 与应用名，在 macOS 全部常见"落点"中查找关联文件。
struct ResidualScanner {

    private static let fm = FileManager.default

    static var home: String { NSHomeDirectory() }

    /// 扫描某个应用的所有残留项
    static func scan(app: InstalledApp) -> [ResidualItem] {
        var candidates: [(path: String, kind: ResidualKind, risk: RiskLevel)] = []
        let bid = app.bundleID
        let name = app.name
        let home = self.home

        func add(_ path: String, _ kind: ResidualKind, _ risk: RiskLevel) {
            candidates.append((path, kind, risk))
        }

        // ---------- 用户级 Library ----------
        if let bid {
            add("\(home)/Library/Application Support/\(bid)", .applicationSupport, .caution)
            add("\(home)/Library/Caches/\(bid)", .caches, .safe)
            add("\(home)/Library/Preferences/\(bid).plist", .preferences, .safe)
            add("\(home)/Library/Logs/\(bid)", .logs, .safe)
            add("\(home)/Library/Saved Application State/\(bid).savedState", .savedState, .safe)
            add("\(home)/Library/Containers/\(bid)", .container, .caution)
            add("\(home)/Library/HTTPStorages/\(bid)", .httpStorages, .safe)
            add("\(home)/Library/HTTPStorages/\(bid).binarycookies", .httpStorages, .safe)
            add("\(home)/Library/WebKit/\(bid)", .webKit, .safe)
            add("\(home)/Library/Cookies/\(bid).binarycookies", .cookies, .safe)
            add("\(home)/Library/Application Scripts/\(bid)", .applicationScripts, .caution)
            add("\(home)/Library/LaunchAgents/\(bid).plist", .launchAgent, .caution)
            add("\(home)/Library/Receipts/\(bid).bom", .receipts, .safe)

            // ByHost 偏好：<bid>.<UUID>.plist
            for p in glob("\(home)/Library/Preferences/ByHost", prefixes: ["\(bid)."], suffixes: [".plist"]) {
                add(p, .preferencesByHost, .safe)
            }
            // 群组容器：TEAMID.<bid> 或 <bid>
            for p in glob("\(home)/Library/Group Containers", suffixes: [".\(bid)", "/\(bid)"]) {
                add(p, .groupContainer, .risky)
            }
            // 厂商目录结构：com.google.Chrome -> Application Support/Google/Chrome
            if let pair = vendorPair(from: bid) {
                for base in ["\(home)/Library/Application Support", "\(home)/Library/Caches"] {
                    guard let vendorDir = child(of: base, matching: pair.vendor),
                          let productDir = child(of: vendorDir, matching: pair.product) else { continue }
                    let kind: ResidualKind = base.hasSuffix("Caches") ? .caches : .applicationSupport
                    add(productDir, kind, .caution)
                }
            }
        }

        // 名称兜底（部分应用不使用 bundleID 命名目录）
        if !name.isEmpty {
            add("\(home)/Library/Application Support/\(name)", .applicationSupport, .caution)
            add("\(home)/Library/Caches/\(name)", .caches, .safe)
            add("\(home)/Library/Logs/\(name)", .logs, .safe)
            add("\(home)/Library/Preferences/\(name).plist", .preferences, .safe)
        }

        // ---------- 系统级 Library（需要管理员权限） ----------
        if let bid {
            add("/Library/Application Support/\(bid)", .systemLevel, .caution)
            add("/Library/Caches/\(bid)", .systemLevel, .safe)
            add("/Library/Preferences/\(bid).plist", .systemLevel, .safe)
            add("/Library/Logs/\(bid)", .systemLevel, .safe)
            add("/Library/LaunchAgents/\(bid).plist", .launchAgent, .caution)
            add("/Library/LaunchDaemons/\(bid).plist", .launchDaemon, .risky)
            for p in glob("/Library/LaunchDaemons", prefixes: ["\(bid)."], suffixes: [".plist"]) {
                add(p, .launchDaemon, .risky)
            }
            for p in glob("/private/var/db/receipts", prefixes: ["\(bid)."]) {
                add(p, .receipts, .safe)
            }
        }

        // ---------- 过滤：存在 + 去重 + 安全检查 ----------
        var seen = Set<String>()
        var items: [ResidualItem] = []
        for c in candidates {
            let std = (c.path as NSString).standardizingPath
            guard seen.insert(std).inserted else { continue }
            guard fm.fileExists(atPath: std) else { continue }
            // 绝不允许命中应用包自身或系统关键目录
            guard !std.hasPrefix(app.path) else { continue }
            guard !ProtectionPolicy.isForbiddenResidualPath(std) else { continue }

            let requiresAdmin = !std.hasPrefix(home)
            let size = AppScanner.sizeOfPath(URL(fileURLWithPath: std))
            var item = ResidualItem(
                path: std,
                kind: c.kind,
                risk: c.risk,
                sizeBytes: size,
                requiresAdmin: requiresAdmin
            )
            item.isSelected = c.risk != .risky
            items.append(item)
        }

        return items.sorted {
            if $0.risk != $1.risk { return $0.risk < $1.risk }
            return $0.sizeBytes > $1.sizeBytes
        }
    }

    // MARK: 目录通配

    /// 从 bundleID 推导厂商 / 产品名，例如 com.google.Chrome -> ("google", "Chrome")
    private static func vendorPair(from bundleID: String) -> (vendor: String, product: String)? {
        let parts = bundleID.split(separator: ".").map(String.init)
        guard parts.count >= 3 else { return nil }
        let product = parts[parts.count - 1]
        let vendor = parts[parts.count - 2]
        guard product.count >= 2, vendor.count >= 2 else { return nil }
        return (vendor, product)
    }

    /// 在目录中大小写不敏感地查找同名子项，返回真实路径
    private static func child(of directory: String, matching name: String) -> String? {
        guard let entries = try? fm.contentsOfDirectory(atPath: directory) else { return nil }
        guard let hit = entries.first(where: { $0.compare(name, options: .caseInsensitive) == .orderedSame })
        else { return nil }
        return "\(directory)/\(hit)"
    }

    private static func glob(_ directory: String, prefixes: [String] = [""], suffixes: [String] = []) -> [String] {
        guard let entries = try? fm.contentsOfDirectory(atPath: directory) else { return [] }
        var result: [String] = []
        for entry in entries {
            let matchedPrefix = prefixes.contains { entry.hasPrefix($0) }
            let matchedSuffix = suffixes.isEmpty || suffixes.contains { entry.hasSuffix($0) }
            if matchedPrefix && matchedSuffix {
                result.append("\(directory)/\(entry)")
            }
        }
        return result
    }

    /// 统计残留总大小
    static func totalSize(_ items: [ResidualItem]) -> Int64 {
        items.filter(\.isSelected).reduce(0) { $0 + $1.sizeBytes }
    }
}
