import AppKit
import Darwin
import Foundation

/// 属于某个已卸载 / 待卸载应用的进程快照
struct ProcessSnapshot: Identifiable, Hashable {
    var id: Int32 { pid }

    let pid: pid_t
    let name: String
    let path: String
    let parentPID: pid_t
    /// 父进程已退出（被 launchd 收养），属于典型的"卸载后残留"
    let isOrphan: Bool
    /// 命中该应用的依据
    let matchedBy: MatchReason

    var displayName: String { name.isEmpty ? (path as NSString).lastPathComponent : name }
    var displayPath: String {
        path.isEmpty ? "(路径不可读，可能属于其他用户)" : (path as NSString).abbreviatingWithTildeInPath
    }
}

enum MatchReason: String {
    case bundlePath      // 可执行文件位于 .app 包内（主进程 + 包内 helper）
    case executableName  // 进程名等于 CFBundleExecutable

    var label: String {
        switch self {
        case .bundlePath:     return "包内进程"
        case .executableName: return "同名进程"
        }
    }
}

/// 进程回收：找出属于某应用的全部进程（含 helper 子进程），并可靠终止。
///
/// 为什么需要它：`NSRunningApplication.runningApplications(withBundleIdentifier:)`
/// 只返回 **主 App 进程**，Electron / Chromium / 更新器 / XPC 等 helper 的
/// bundleID 与主应用不同，永远匹配不到，卸载后会变成孤儿进程继续运行。
enum ProcessReaper {

    // MARK: 枚举

    /// 找出属于该应用的所有进程
    /// - 匹配依据：可执行路径以 `.app` 包路径开头（覆盖主进程与包内所有 helper）
    static func processes(for app: InstalledApp) -> [ProcessSnapshot] {
        let bundlePrefix = app.path.hasSuffix("/") ? app.path : app.path + "/"
        let executableName = app.executableName ?? ""
        var result: [ProcessSnapshot] = []

        for pid in allPIDs() {
            if pid <= 1 || pid == getpid() { continue }

            let path = executablePath(of: pid)
            let name = processName(of: pid, fallback: path)

            var reason: MatchReason?
            if !path.isEmpty, path.hasPrefix(bundlePrefix) {
                reason = .bundlePath
            } else if !executableName.isEmpty, name == executableName {
                reason = .executableName
            }
            guard let reason else { continue }

            let ppid = parentPID(of: pid)
            result.append(ProcessSnapshot(
                pid: pid,
                name: name,
                path: path,
                parentPID: ppid,
                isOrphan: ppid == 1,
                matchedBy: reason
            ))
        }
        return result.sorted { $0.pid < $1.pid }
    }

    /// 该进程是否仍存活
    static func isAlive(_ pid: pid_t) -> Bool {
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM   // 存在但无权操作
    }

    // MARK: 终止

    /// 先 SIGTERM，宽限后 SIGKILL，并逐个校验
    static func terminate(_ list: [ProcessSnapshot],
                          log: LogStore) async -> (terminated: [ProcessSnapshot], survived: [ProcessSnapshot]) {
        guard !list.isEmpty else { return ([], []) }

        log.append(.info, action: "终止残留进程", target: "\(list.count) 个进程",
                   detail: list.map { "\($0.displayName)(\($0.pid))" }.joined(separator: ", "))

        for proc in list where isAlive(proc.pid) {
            kill(proc.pid, SIGTERM)
        }

        // 最多等 3 秒（15 × 200ms）
        for _ in 0..<15 {
            try? await Task.sleep(nanoseconds: 200_000_000)
            if list.allSatisfy({ !isAlive($0.pid) }) {
                log.append(.success, action: "进程已全部退出", target: "\(list.count) 个进程")
                return (list, [])
            }
        }

        // 仍未退出的，升级为 SIGKILL
        let stubborn = list.filter { isAlive($0.pid) }
        for proc in stubborn {
            kill(proc.pid, SIGKILL)
        }
        try? await Task.sleep(nanoseconds: 400_000_000)

        var terminated: [ProcessSnapshot] = []
        var survived: [ProcessSnapshot] = []
        for proc in list {
            if isAlive(proc.pid) {
                survived.append(proc)
                log.append(.error, action: "进程拒绝退出",
                           target: "\(proc.displayName)(\(proc.pid))",
                           detail: "SIGKILL 后仍存活，可能受系统保护或属于其他用户")
            } else {
                terminated.append(proc)
                if stubborn.contains(where: { $0.pid == proc.pid }) {
                    log.append(.warning, action: "强制结束进程",
                               target: "\(proc.displayName)(\(proc.pid))", detail: "SIGTERM 超时后 SIGKILL")
                }
            }
        }
        return (terminated, survived)
    }

    // MARK: launchd 启动项

    /// 停止该应用注册的 launchd 任务，**必须在杀进程之前执行**，
    /// 否则 KeepAlive=true 的任务会被 launchd 立刻重新拉起。
    @discardableResult
    static func unloadLaunchdItems(for app: InstalledApp, log: LogStore) -> [String] {
        let labels = launchdLabels(for: app)
        guard !labels.isEmpty else { return [] }

        var unloaded: [String] = []
        for label in labels {
            let ok = runLaunchctl(["bootout", "gui/\(getuid())/\(label)"])
            if ok {
                unloaded.append(label)
                log.append(.info, action: "已停止启动项", target: label, detail: "launchctl bootout")
            } else {
                log.append(.warning, action: "启动项停止失败", target: label,
                           detail: "可能位于系统域（/Library/LaunchDaemons），需要管理员权限")
            }
        }
        return unloaded
    }

    /// 从常见位置解析出属于该应用的 launchd label
    static func launchdLabels(for app: InstalledApp) -> [String] {
        let fm = FileManager.default
        let home = NSHomeDirectory()
        var candidates: [String] = []

        if let bid = app.bundleID {
            candidates += [
                "\(home)/Library/LaunchAgents/\(bid).plist",
                "/Library/LaunchAgents/\(bid).plist",
                "/Library/LaunchDaemons/\(bid).plist",
            ]
        }
        // 兜底：与可执行名同名
        if let exe = app.executableName {
            candidates.append("\(home)/Library/LaunchAgents/\(exe).plist")
        }

        var labels: [String] = []
        for path in candidates where fm.fileExists(atPath: path) {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
                  let label = plist["Label"] as? String else { continue }
            labels.append(label)
        }
        return labels
    }

    private static func runLaunchctl(_ args: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = args
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    // MARK: libproc 封装

    private static func allPIDs() -> [pid_t] {
        let byteCount = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard byteCount > 0 else { return [] }
        let capacity = Int(byteCount) / MemoryLayout<pid_t>.size + 64
        var pids = [pid_t](repeating: 0, count: capacity)
        let written = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids,
                                    Int32(capacity * MemoryLayout<pid_t>.size))
        guard written > 0 else { return [] }
        let count = Int(written) / MemoryLayout<pid_t>.size
        return Array(pids.prefix(count)).filter { $0 > 0 }
    }

    private static func executablePath(of pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return "" }
        return String(cString: buffer)
    }

    private static func processName(of pid: pid_t, fallback path: String) -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        let length = proc_name(pid, &buffer, 256)
        if length > 0 {
            let name = String(cString: buffer)
            if !name.isEmpty { return name }
        }
        return path.isEmpty ? "" : (path as NSString).lastPathComponent
    }

    private static func parentPID(of pid: pid_t) -> pid_t {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let result = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
        return result > 0 ? pid_t(info.pbi_ppid) : 0
    }
}
