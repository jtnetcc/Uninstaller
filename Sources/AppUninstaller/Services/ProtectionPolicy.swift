import Foundation

/// 卸载判定结果
struct ProtectionDecision {
    let scope: RemovalScope
    let reason: String?

    var isActionable: Bool { scope.isActionable }
}

/// 系统保护策略：决定一个 .app 能否被移除、以什么权限移除。
///
/// 四档判定（任一步命中即返回）：
/// 1. 关键组件名单        → forbidden（删除会导致系统不可用）
/// 2. 系统目录/只读卷     → systemVolume（SSV 只读，物理不可删）或 forbidden
/// 3. 非托管目录          → forbidden
/// 4. 托管目录 + 写权限   → userManaged / adminRequired
enum ProtectionPolicy {

    /// 用户可见但绝不允许移除的系统组件（即使被拷贝到 /Applications）
    static let protectedBundleIDs: Set<String> = [
        "com.apple.finder",
        "com.apple.dock",
        "com.apple.systempreferences",
        "com.apple.SystemSettings",
        "com.apple.loginwindow",
        "com.apple.WindowManager",
        "com.apple.controlcenter",
        "com.apple.notificationcenterui",
        "com.apple.spotlight",
        "com.apple.SecurityAgent",
        "com.apple.UserNotificationCenter",
        "com.apple.CoreServicesUIAgent",
        "com.apple.AccessibilityUIServer",
        "com.apple.loginwindow",
        "com.apple.LaunchServices",
        "com.apple.softwareupdate_notify_agent",
        "com.apple.MobileInstallation",
        "com.apple.WindowServer",
        "com.apple.talagent",
    ]

    /// 完全禁止触碰的路径前缀（系统运行必需）
    static let protectedPathPrefixes: [String] = [
        "/usr",
        "/bin",
        "/sbin",
        "/private",
        "/cores",
        "/System/Library",
        "/System/Volumes",
        "/Library/Apple",
        "/Library/CoreServices",
        "/Library/Extensions",
        "/Library/Frameworks",
        "/Library/LaunchDaemons",
        "/Library/LaunchAgents",
        "/Library/PrivilegedHelperTools",
        "/Volumes",
    ]

    /// 允许移除的根目录
    static var allowedRoots: [String] {
        ["/Applications", "/Users/Shared/Applications", homeApplications.path]
    }

    static var homeApplications: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true)
    }

    // MARK: 主判定

    static func evaluate(path: String, bundleID: String?, name: String) -> ProtectionDecision {
        let rawURL = URL(fileURLWithPath: path)
        let stdURL = rawURL.resolvingSymlinksInPath().standardizedFileURL
        let std = stdURL.path

        // 1) 符号链接：真实路径可能指向别处
        if std != rawURL.standardizedFileURL.path {
            return ProtectionDecision(scope: .forbidden,
                                      reason: "该位置是符号链接，指向 \(std)，出于安全考虑禁止操作")
        }

        // 2) 必须是 .app 包
        guard std.hasSuffix(".app") else {
            return ProtectionDecision(scope: .forbidden, reason: "不是标准的 .app 应用包")
        }

        // 3) 关键组件名单
        if let bid = bundleID, protectedBundleIDs.contains(bid) {
            return ProtectionDecision(scope: .forbidden,
                                      reason: "系统关键组件（\(bid)），移除后 macOS 将无法正常工作")
        }

        // 4) 完全禁止的路径
        for prefix in protectedPathPrefixes where std == prefix || std.hasPrefix(prefix + "/") {
            return ProtectionDecision(scope: .forbidden,
                                      reason: "位于系统受保护目录 \(prefix)")
        }

        // 5) 只读签名的系统卷：/System/Applications 下的预装应用
        if std.hasPrefix("/System/") {
            if std.hasPrefix("/System/Applications/") {
                return ProtectionDecision(
                    scope: .systemVolume,
                    reason: "位于只读签名的系统卷（SSV），受 SIP 保护，root 也无法物理删除")
            }
            return ProtectionDecision(scope: .forbidden, reason: "位于系统目录 /System 内")
        }

        // 6) 必须位于托管根目录之下
        guard let root = allowedRoots.first(where: { std.hasPrefix($0 + "/") }) else {
            return ProtectionDecision(scope: .forbidden,
                                      reason: "不在可管理的应用目录内（仅支持 /Applications、~/Applications）")
        }
        let relative = String(std.dropFirst(root.count + 1))
        if relative.isEmpty || relative.hasPrefix(".") {
            return ProtectionDecision(scope: .forbidden, reason: "非法的应用路径")
        }

        // 7) 权限判定
        if requiresAdminPrivileges(std) {
            let hint = (bundleID?.lowercased().hasPrefix("com.apple.") ?? false)
                ? "Apple 官方应用，移除需要管理员授权，之后可从 App Store 重新下载"
                : "该应用归 root 所有，移除需要管理员授权（系统会要求输入登录密码）"
            return ProtectionDecision(scope: .adminRequired, reason: hint)
        }

        if bundleID?.lowercased().hasPrefix("com.apple.") ?? false {
            return ProtectionDecision(scope: .userManaged,
                                      reason: "Apple 官方应用，移除后可从 App Store 重新下载")
        }

        _ = name
        return ProtectionDecision(scope: .userManaged, reason: nil)
    }

    // MARK: 权限探测

    /// 判断移除该应用是否需要 root：
    /// 删除 .app 需要对包内各级目录有写权限，仅看父目录不够。
    private static func requiresAdminPrivileges(_ path: String) -> Bool {
        let parent = (path as NSString).deletingLastPathComponent
        // 父目录不可写 → 连目录项都删不掉
        if access(parent, W_OK) != 0 { return true }
        // 包内 Contents 不可写 → rm -rf 无法递归删除
        let contents = path + "/Contents"
        if access(contents, F_OK) == 0, access(contents, W_OK) != 0 { return true }
        return false
    }

    // MARK: 系统卷能力探测

    /// /System 是否可写（关闭 SIP 且挂载可写时才为 true）
    static func isSystemVolumeWritable() -> Bool {
        access("/System", W_OK) == 0
    }

    /// SIP 状态（调用 csrutil，耗时操作，结果可缓存）
    static func sipStatus() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/csrutil")
        process.arguments = ["status"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return text ?? "未知"
        } catch {
            return "未知"
        }
    }

    // MARK: 残留路径白名单

    /// 判断某个残留路径是否属于禁止操作的范围（默认禁止，白名单允许）
    static func isForbiddenResidualPath(_ path: String) -> Bool {
        let std = (path as NSString).standardizingPath
        let home = NSHomeDirectory()

        let exactForbidden: Set<String> = [
            "/", "/System", "/Library", "/Applications", "/Users",
            home, home + "/Library",
            home + "/Library/Preferences",
            home + "/Library/Caches",
            home + "/Library/Application Support",
            home + "/Library/Containers",
            home + "/Library/Group Containers",
            home + "/Library/Logs",
            home + "/Library/Saved Application State",
            home + "/Library/LaunchAgents",
        ]
        if exactForbidden.contains(std) { return true }

        let allowedPrefixes = [
            home + "/Library/",
            "/Library/Application Support/",
            "/Library/Caches/",
            "/Library/Preferences/",
            "/Library/Logs/",
            "/Library/LaunchAgents/",
            "/Library/LaunchDaemons/",
            "/Library/Receipts/",
            "/private/var/db/receipts/",
        ]
        if allowedPrefixes.contains(where: { std.hasPrefix($0) }) { return false }

        // 不在白名单内的一律禁止
        return true
    }
}
