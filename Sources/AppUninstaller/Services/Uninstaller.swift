import AppKit
import Foundation

// MARK: - 请求 / 结果

struct UninstallRequest: Identifiable {
    var id: String { app.path }

    var app: InstalledApp
    var residuals: [ResidualItem]
    /// 是否移入废纸篓（true 可撤销；false 直接删除，不可恢复）
    var useTrash: Bool = true
    /// 是否在卸载前退出正在运行的实例
    var terminateRunningApp: Bool = true
    /// 是否允许操作系统内置应用（/System/Applications，只读卷）
    var allowSystemApps: Bool = false
    /// 是否允许在权限不足时请求管理员授权
    var allowPrivilegedRemoval: Bool = true
    /// 跳过交互（自测用）
    var nonInteractive: Bool = false
}

struct UninstallOutcome {
    var appRemoved = false
    var residualRemoved = 0
    var residualFailed = 0
    var freedBytes: Int64 = 0
    /// 原路径 -> 废纸篓中的新路径（用于撤销；root 删除的路径不在此列）
    var trashMap: [String: String] = [:]
    var errors: [String] = []
    /// 清理完成后重新检测的结果
    var verification: VerificationReport?
    /// 因只读系统卷导致无法删除
    var blockedBySystemVolume = false
    /// 用户取消了管理员授权
    var authorizationCancelled = false
}

// MARK: - 卸载执行器

enum Uninstaller {

    // MARK: 主流程

    static func perform(_ request: UninstallRequest, log: LogStore) async -> UninstallOutcome {
        var outcome = UninstallOutcome()
        let app = request.app
        let decision = ProtectionPolicy.evaluate(path: app.path, bundleID: app.bundleID, name: app.name)

        log.append(.info, action: "开始卸载", target: app.name,
                   detail: "\(app.path) · \(app.formattedSize) · \(decision.scope.label)")

        // ---- 1. 策略校验 ----
        guard decision.isActionable else {
            let reason = decision.reason ?? "该应用受系统保护"
            log.append(.error, action: "保护拦截", target: app.name, detail: reason)
            outcome.errors.append(reason)
            return outcome
        }
        if let bid = app.bundleID, bid == Bundle.main.bundleIdentifier {
            let msg = "不能卸载本工具自身"
            log.append(.error, action: "保护拦截", target: app.name, detail: msg)
            outcome.errors.append(msg)
            return outcome
        }
        if decision.scope == .systemVolume && !request.allowSystemApps {
            let msg = "系统内置应用（只读卷）需要先在设置中开启「允许移除系统内置应用」"
            log.append(.error, action: "保护拦截", target: app.name, detail: msg)
            outcome.errors.append(msg)
            return outcome
        }

        // ---- 2. 退出运行中的实例 ----
        if request.terminateRunningApp {
            await terminateIfRunning(app: app, log: log)
        }

        // ---- 3. 移除应用本体 ----
        let appURL = URL(fileURLWithPath: app.path)
        var appNeedsRoot = (decision.scope == .adminRequired || decision.scope == .systemVolume)

        if !appNeedsRoot {
            let normal = await removeNormally(url: appURL, useTrash: request.useTrash)
            if normal.ok {
                outcome.appRemoved = true
                outcome.freedBytes += app.sizeBytes
                if let to = normal.trashedTo { outcome.trashMap[app.path] = to }
                log.append(.success, action: request.useTrash ? "已移入废纸篓" : "已删除应用",
                           target: app.name, detail: app.path)
            } else if normal.permissionDenied {
                appNeedsRoot = true
                log.append(.warning, action: "权限不足", target: app.name,
                           detail: "将请求管理员授权")
            } else {
                let msg = normal.error ?? "未知错误"
                outcome.errors.append("应用本体：\(msg)")
                log.append(.error, action: "应用移除失败", target: app.name, detail: msg)
                outcome.verification = verify(app: app, residuals: request.residuals, log: log)
                return outcome
            }
        }

        // ---- 4. 系统卷应用：先单独尝试删除本体，失败即中止（不清残留，避免半删状态） ----
        if appNeedsRoot && decision.scope == .systemVolume {
            guard request.allowPrivilegedRemoval else {
                outcome.errors.append("需要管理员授权才能尝试移除系统内置应用，但该选项被关闭")
                outcome.verification = verify(app: app, residuals: request.residuals, log: log)
                return outcome
            }
            let result = await PrivilegedExecutor.removePaths([app.path], log: log)
            if result.cancelled {
                outcome.authorizationCancelled = true
                outcome.errors.append("已取消管理员授权，未做任何修改")
                outcome.verification = verify(app: app, residuals: request.residuals, log: log)
                return outcome
            }
            if result.results[app.path] == .removed || result.results[app.path] == .alreadyGone {
                outcome.appRemoved = true
                outcome.freedBytes += app.sizeBytes
                log.append(.success, action: "已以管理员权限删除", target: app.name, detail: app.path)
            } else {
                outcome.blockedBySystemVolume = true
                let detail = ProtectionPolicy.isSystemVolumeWritable()
                    ? "提权删除失败：\(result.message ?? "未知原因")"
                    : "/System 为只读签名卷（SIP 已启用），即使 root 也无法删除。可在结果面板中选择「隐藏」"
                outcome.errors.append(detail)
                log.append(.error, action: "系统内置应用无法删除", target: app.name, detail: detail)
                outcome.verification = verify(app: app, residuals: request.residuals, log: log)
                return outcome
            }
        }

        // ---- 5. 清理残留：普通项就地处理，需 root 的合并为一次授权 ----
        var rootCandidates: [String] = []
        let targets = request.residuals.filter(\.isSelected)
        if targets.isEmpty {
            log.append(.info, action: "无需清理残留", target: app.name)
        }

        for item in targets {
            if item.requiresAdmin {
                rootCandidates.append(item.path)
                continue
            }
            let result = await removeNormally(url: item.url, useTrash: request.useTrash)
            if result.ok {
                outcome.residualRemoved += 1
                outcome.freedBytes += item.sizeBytes
                if let to = result.trashedTo { outcome.trashMap[item.path] = to }
                log.append(.destructive, action: "清理\(item.kind.label)",
                           target: item.displayPath,
                           detail: "\(item.formattedSize) · 风险 \(item.risk.label)")
            } else if result.permissionDenied {
                rootCandidates.append(item.path)
            } else {
                outcome.residualFailed += 1
                let msg = result.error ?? "未知错误"
                outcome.errors.append("\(item.displayPath)：\(msg)")
                log.append(.error, action: "残留清理失败", target: item.displayPath, detail: msg)
            }
        }

        // 应用本体尚未删除（提权失败或用户取消）时，残留一并尝试
        if appNeedsRoot && !outcome.appRemoved && !outcome.blockedBySystemVolume {
            rootCandidates.append(app.path)
        }

        if !rootCandidates.isEmpty {
            if request.allowPrivilegedRemoval {
                let result = await PrivilegedExecutor.removePaths(rootCandidates, log: log)
                if result.cancelled {
                    outcome.authorizationCancelled = true
                    outcome.errors.append("已取消管理员授权，需管理员权限的 \(rootCandidates.count) 项未处理")
                } else if result.executed {
                    for path in rootCandidates {
                        switch result.results[path] {
                        case .removed, .alreadyGone:
                            if path == app.path {
                                outcome.appRemoved = true
                                outcome.freedBytes += app.sizeBytes
                                log.append(.success, action: "已以管理员权限删除", target: app.name, detail: path)
                            } else if let item = targets.first(where: { $0.path == path }) {
                                outcome.residualRemoved += 1
                                outcome.freedBytes += item.sizeBytes
                                log.append(.destructive, action: "管理员权限清理\(item.kind.label)",
                                           target: item.displayPath, detail: item.formattedSize)
                            }
                        case .failed, .none:
                            if path == app.path {
                                outcome.errors.append("应用本体：管理员权限删除失败")
                                log.append(.error, action: "管理员权限删除失败", target: path, detail: nil)
                            } else {
                                outcome.residualFailed += 1
                                outcome.errors.append("\(path)：管理员权限删除失败")
                                log.append(.error, action: "管理员权限删除失败", target: path, detail: nil)
                            }
                        }
                    }
                }
            } else {
                outcome.residualFailed += rootCandidates.count
                outcome.errors.append("\(rootCandidates.count) 项需要管理员权限，但该选项被关闭")
                log.append(.warning, action: "跳过需授权项", target: "\(rootCandidates.count) 项", detail: nil)
            }
        }

        // ---- 6. 重新检测 ----
        let report = verify(app: app, residuals: request.residuals, log: log)
        outcome.verification = report

        log.append(report.isFullyCleared ? .success : .warning,
                   action: report.isFullyCleared ? "卸载完成（已验证）" : "卸载完成（存在残留）",
                   target: app.name,
                   detail: "释放 \(Fmt.size(outcome.freedBytes)) · 已清除 \(report.clearedCount) 项 · 残留 \(report.remaining.count) 项")
        return outcome
    }

    // MARK: 清理后重新检测

    /// 重新扫盘确认目标是否真的被清除（不复用执行结果）
    static func verify(app: InstalledApp, residuals: [ResidualItem], log: LogStore) -> VerificationReport {
        let fm = FileManager.default
        let appStillExists = fm.fileExists(atPath: app.path)

        var checked: [String] = [app.path]
        var cleared: [String] = []
        var remaining: [RemainderItem] = []

        if appStillExists {
            remaining.append(RemainderItem(
                path: app.path,
                sizeBytes: AppScanner.sizeOfPath(URL(fileURLWithPath: app.path)),
                reason: "应用本体仍存在"
            ))
        } else {
            cleared.append(app.path)
        }

        for item in residuals where item.isSelected {
            checked.append(item.path)
            if fm.fileExists(atPath: item.path) {
                let size = AppScanner.sizeOfPath(item.url)
                remaining.append(RemainderItem(
                    path: item.path,
                    sizeBytes: size,
                    reason: protectionReason(for: item.path)
                ))
            } else {
                cleared.append(item.path)
            }
        }

        let report = VerificationReport(
            appName: app.name,
            appPath: app.path,
            appStillExists: appStillExists,
            checkedPaths: checked,
            clearedPaths: cleared,
            remaining: remaining,
            freedBytes: 0,
            checkedAt: Date(),
            blockedBySystemVolume: appStillExists && app.path.hasPrefix("/System/")
        )

        log.append(.info, action: "重新检测完成", target: app.name,
                   detail: "检查 \(checked.count) 项 · 已清除 \(cleared.count) 项 · 残留 \(remaining.count) 项")
        return report
    }

    private static func protectionReason(for path: String) -> String {
        if path.hasPrefix("/System/") {
            return "只读系统卷，无法删除"
        }
        if protectionReasonIsAdmin(path) {
            return "需要管理员权限"
        }
        return "文件仍存在，可能被占用或需重启"
    }

    private static func protectionReasonIsAdmin(_ path: String) -> Bool {
        let parent = (path as NSString).deletingLastPathComponent
        return access(parent, W_OK) != 0
    }

    // MARK: 退出运行中的应用

    private static func terminateIfRunning(app: InstalledApp, log: LogStore) async {
        guard let bid = app.bundleID else { return }
        let running = await MainActor.run {
            NSRunningApplication.runningApplications(withBundleIdentifier: bid)
        }
        guard !running.isEmpty else { return }

        log.append(.info, action: "请求退出应用", target: app.name,
                   detail: "发现 \(running.count) 个运行中实例")

        for instance in running {
            _ = await MainActor.run { instance.terminate() }
        }

        for _ in 0..<30 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            let alive = await MainActor.run { running.contains { !$0.isTerminated } }
            if !alive { return }
        }

        for instance in running {
            let stillAlive = await MainActor.run { !instance.isTerminated }
            if stillAlive {
                _ = await MainActor.run { instance.forceTerminate() }
                log.append(.warning, action: "强制退出", target: app.name,
                           detail: instance.localizedName ?? bid)
            }
        }
        try? await Task.sleep(nanoseconds: 300_000_000)
    }

    // MARK: 普通权限删除

    private struct RemoveResult {
        var ok: Bool
        var trashedTo: String?
        var error: String?
        var permissionDenied: Bool = false
    }

    private static func removeNormally(url: URL, useTrash: Bool) async -> RemoveResult {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return RemoveResult(ok: true) // 已不存在视为成功
        }

        if useTrash {
            do {
                let map = try await recycle([url])
                if let newURL = map[url] {
                    return RemoveResult(ok: true, trashedTo: newURL.path)
                }
                let gone = !FileManager.default.fileExists(atPath: url.path)
                return RemoveResult(ok: gone, error: gone ? nil : "系统未返回废纸篓位置")
            } catch {
                return RemoveResult(ok: false, error: friendly(error), permissionDenied: isPermissionError(error))
            }
        } else {
            do {
                try FileManager.default.removeItem(at: url)
                return RemoveResult(ok: true)
            } catch {
                return RemoveResult(ok: false, error: friendly(error), permissionDenied: isPermissionError(error))
            }
        }
    }

    private static func isPermissionError(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain, ns.code == 513 { return true }
        if ns.domain == NSPOSIXErrorDomain, ns.code == 1 || ns.code == 13 { return true }
        if ns.code == 257 { return true }
        return false
    }

    private static func recycle(_ urls: [URL]) async throws -> [URL: URL] {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[URL: URL], Error>) in
            NSWorkspace.shared.recycle(urls) { map, error in
                if let error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume(returning: map)
                }
            }
        }
    }

    private static func friendly(_ error: Error) -> String {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain, ns.code == 513 {
            return "没有权限修改该应用（可在授权窗口中输入登录密码）"
        }
        if ns.domain == NSPOSIXErrorDomain, ns.code == 1 || ns.code == 13 {
            return "权限不足"
        }
        return ns.localizedDescription
    }

    // MARK: 撤销（从废纸篓恢复）

    @discardableResult
    static func undo(trashMap: [String: String], log: LogStore) async -> Int {
        var restored = 0
        for (original, trashed) in trashMap {
            let trashedURL = URL(fileURLWithPath: trashed)
            let originalURL = URL(fileURLWithPath: original)
            guard FileManager.default.fileExists(atPath: trashed),
                  !FileManager.default.fileExists(atPath: original) else { continue }
            let parent = originalURL.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            do {
                try FileManager.default.moveItem(at: trashedURL, to: originalURL)
                restored += 1
                log.append(.success, action: "已撤销", target: original, detail: "从废纸篓恢复")
            } catch {
                log.append(.error, action: "撤销失败", target: original, detail: error.localizedDescription)
            }
        }
        return restored
    }
}
