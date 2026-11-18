import AppKit
import Foundation

/// 单个路径的处理结果
enum PrivilegedPathResult: String {
    case removed = "OK"       // 已删除
    case alreadyGone = "GONE" // 执行前已不存在
    case failed = "FAIL"      // 删除失败
}

struct PrivilegedResult {
    /// 是否拿到授权并执行了命令
    var executed = false
    /// 用户点了"取消"
    var cancelled = false
    var results: [String: PrivilegedPathResult] = [:]
    var message: String?
    var errorNumber: Int?
    var rawOutput: String = ""

    var removedPaths: [String] { results.filter { $0.value == .removed }.map(\.key) }
    var failedPaths: [String] { results.filter { $0.value == .failed }.map(\.key) }
}

/// 以管理员（root）身份执行删除。
///
/// 通过 AppleScript 的 `do shell script … with administrator privileges` 触发
/// 系统标准授权窗口（SecurityAgent），用户输入本机登录密码后由 root 执行。
/// 多次操作会合并为**一次**授权，避免反复弹窗。
enum PrivilegedExecutor {

    /// 批量删除（一次授权）
    static func removePaths(_ paths: [String], log: LogStore) async -> PrivilegedResult {
        let valid = paths.filter { $0.hasPrefix("/") && !$0.contains("\n") && !$0.contains("\r") }
        guard !valid.isEmpty else { return PrivilegedResult() }

        for path in valid {
            // 应用本体走 evaluate，残留走白名单；两者都不允许越界
            if ProtectionPolicy.isForbiddenResidualPath(path) {
                let isManagedApp = ProtectionPolicy.allowedRoots.contains { path.hasPrefix($0 + "/") }
                    || path.hasPrefix("/System/Applications/")
                if !isManagedApp {
                    log.append(.error, action: "拒绝提权删除", target: path, detail: "路径不在允许范围内")
                    return PrivilegedResult(executed: false, cancelled: false,
                                            results: [:], message: "路径不在允许删除的范围内", rawOutput: "")
                }
            }
        }

        let script = buildScript(for: valid)
        log.append(.warning, action: "请求管理员授权", target: "\(valid.count) 个路径",
                   detail: "系统将弹出验证窗口，需要输入本机登录密码")

        // 首次调用在进程刚启动时可能被系统降级为普通权限执行（表现为 Permission denied），
        // 此时重试一次即可正常拿到 root 授权。
        var last = PrivilegedResult()
        for attempt in 1...2 {
            last = await execute(script: script, log: log)
            if last.executed || last.cancelled { return last }

            let deniedBySystem = (last.message ?? "").lowercased().contains("permission denied")
                || last.errorNumber == 13
            guard attempt == 1, deniedBySystem else { return last }

            log.append(.warning, action: "授权未生效，重试", target: "第 2 次尝试",
                       detail: "首次请求被系统降级为普通权限，正在重新请求授权")
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        return last
    }

    private static func execute(script: String, log: LogStore) async -> PrivilegedResult {
        let escaped = escapeForAppleScript(script)
        let source = "do shell script \"\(escaped)\" with administrator privileges"
        guard let appleScript = NSAppleScript(source: source) else {
            return PrivilegedResult(executed: false, cancelled: false, results: [:],
                                    message: "无法构造授权脚本", rawOutput: "")
        }

        // 让 UI 有机会把"等待授权"状态渲染出来，再进入同步阻塞调用
        try? await Task.sleep(nanoseconds: 120_000_000)

        let outcome: (output: String?, errorNumber: Int?, errorMessage: String?) = await MainActor.run {
            var errorInfo: NSDictionary?
            let result = appleScript.executeAndReturnError(&errorInfo)
            let number = errorInfo?[NSAppleScript.errorNumber] as? Int
            let message = errorInfo?[NSAppleScript.errorMessage] as? String
            return (result.stringValue, number, message)
        }

        if let number = outcome.errorNumber {
            if number == -128 {
                log.append(.warning, action: "授权已取消", target: "用户取消", detail: nil)
                return PrivilegedResult(executed: false, cancelled: true, results: [:],
                                        message: "已取消授权", errorNumber: number, rawOutput: "")
            }
            let msg = outcome.errorMessage ?? "授权失败（错误码 \(number)）"
            log.append(.error, action: "授权失败", target: "管理员权限", detail: msg)
            return PrivilegedResult(executed: false, cancelled: false, results: [:],
                                    message: msg, errorNumber: number, rawOutput: "")
        }

        var result = PrivilegedResult()
        result.executed = true
        result.rawOutput = outcome.output ?? ""
        for line in result.rawOutput.split(separator: "\n") {
            let parts = line.split(separator: "|", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let status = PrivilegedPathResult(rawValue: String(parts[0]))
            let path = String(parts[1])
            if let status { result.results[path] = status }
        }
        return result
    }

    // MARK: 脚本构造

    private static func buildScript(for paths: [String]) -> String {
        let quoted = paths.map(shellQuote).joined(separator: " ")
        return "for p in \(quoted); do "
            + "if [ ! -e \"$p\" ]; then echo \"GONE|$p\"; "
            + "elif /bin/rm -rf \"$p\" 2>/dev/null; then echo \"OK|$p\"; "
            + "else echo \"FAIL|$p\"; fi; done"
    }

    /// POSIX 单引号转义
    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// AppleScript 双引号字符串转义（先处理反斜杠）
    private static func escapeForAppleScript(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

// MARK: - 系统应用隐藏（只读卷下的替代方案）

/// 对 /System/Applications 中的预装应用，物理删除不可能；
/// 通过注销 LaunchServices 记录使其从启动台 / 聚焦中消失（可逆）。
enum SystemAppHider {

    private static let lsregister =
        "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

    static func hide(path: String) -> (ok: Bool, message: String) {
        run(arguments: ["-u", path], describe: "已从启动台与聚焦中移除")
    }

    static func restore(path: String) -> (ok: Bool, message: String) {
        run(arguments: ["-f", "-R", "-trusted", path], describe: "已重新注册到启动台")
    }

    /// 恢复全部系统应用注册（设置里的兜底入口）
    static func restoreAllSystemApps() -> (ok: Bool, message: String) {
        run(arguments: ["-f", "-R", "-trusted", "/System/Applications"], describe: "已重新注册全部系统应用")
    }

    private static func run(arguments: [String], describe: String) -> (Bool, String) {
        guard FileManager.default.isExecutableFile(atPath: lsregister) else {
            return (false, "当前系统未找到 lsregister 工具")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: lsregister)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                return (true, describe)
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let text = String(data: data, encoding: .utf8) ?? ""
            return (false, text.isEmpty ? "操作失败（退出码 \(process.terminationStatus)）" : text)
        } catch {
            return (false, error.localizedDescription)
        }
    }
}
