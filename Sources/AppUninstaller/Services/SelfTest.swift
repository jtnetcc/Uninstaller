import AppKit
import Foundation

/// 无头自测：`App Uninstaller.app/Contents/MacOS/AppUninstaller --selftest`
///
/// 只在 ~/Applications 下创建一次性假应用与假残留数据，验证
/// 扫描 → 策略判定 → 残留匹配 → 卸载 → 复检 → 撤销 全链路，不触碰真实应用。
enum SelfTest {

    nonisolated(unsafe) private static var failures = 0
    nonisolated(unsafe) private static var total = 0

    private static let testBundleID = "com.jt.auselftest.demo"
    private static let testAppName = "AU SelfTest"

    static func run() async {
        print("=== App Uninstaller 自测 ===")
        print("系统: \(ProcessInfo.processInfo.operatingSystemVersionString)")

        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let appsDir = home.appendingPathComponent("Applications", isDirectory: true)
        let testApp = appsDir.appendingPathComponent("\(testAppName).app", isDirectory: true)

        try? fm.removeItem(at: testApp)

        // ---------- 1. 四档判定 ----------
        check(ProtectionPolicy.evaluate(path: "/System/Applications/Music.app",
                                        bundleID: "com.apple.Music", name: "Music").scope == .systemVolume,
              "系统卷预装应用应判为 systemVolume")
        check(ProtectionPolicy.evaluate(path: "/Applications/Finder.app",
                                        bundleID: "com.apple.finder", name: "Finder").scope == .forbidden,
              "关键组件 Finder 必须 forbidden")
        check(ProtectionPolicy.evaluate(path: "/usr/local/bin/tool.app",
                                        bundleID: "com.vendor.tool", name: "tool").scope == .forbidden,
              "非托管目录必须 forbidden")
        check(ProtectionPolicy.evaluate(path: appsDir.appendingPathComponent("Foo.app").path,
                                        bundleID: "com.vendor.foo", name: "Foo").scope == .userManaged,
              "~/Applications 下第三方应用应 userManaged")
        // 回归：路径/父目录尚不存在时（CI 环境常见）不得误判为需要管理员权限
        check(ProtectionPolicy.evaluate(
                path: home.appendingPathComponent("Applications/__au_no_such_dir__/Ghost.app").path,
                bundleID: "com.vendor.ghost", name: "Ghost").scope == .userManaged,
              "祖先目录不存在时不应误判为需要管理员授权")
        check(ProtectionPolicy.isForbiddenResidualPath(home.appendingPathComponent("Library").path),
              "~/Library 根目录必须禁止")
        check(!ProtectionPolicy.isForbiddenResidualPath(
                home.appendingPathComponent("Library/Caches/\(testBundleID)").path),
              "缓存子路径应允许")

        // 系统卷实际状态（用于结果面板提示）
        let systemWritable = ProtectionPolicy.isSystemVolumeWritable()
        print("  · /System 可写: \(systemWritable) · SIP: \(ProtectionPolicy.sipStatus())")
        check(FileManager.default.isExecutableFile(atPath:
                "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"),
              "lsregister 工具存在（隐藏功能可用）")

        // ---------- 2. 构造假应用 ----------
        do {
            try buildFakeApp(at: testApp)
        } catch {
            check(false, "构造假应用失败: \(error.localizedDescription)")
            finish()
            return
        }

        let size = AppScanner.directorySize(testApp)
        check(size > 1_000_000, "体积统计应 > 1MB（实际 \(Fmt.size(size))）")

        guard let scanned = AppScanner.makeApp(url: testApp, size: size) else {
            check(false, "元数据解析失败")
            finish()
            return
        }
        check(scanned.name == testAppName, "名称解析正确（\(scanned.name)）")
        check(scanned.bundleID == testBundleID, "Bundle ID 解析正确")
        check(scanned.shortVersion == "9.9.9", "版本解析正确（\(scanned.shortVersion ?? "nil")）")
        check(scanned.removalScope == .userManaged, "自建测试应用应 userManaged（实际 \(scanned.removalScope.rawValue)）")

        // ---------- 3. 残留扫描 ----------
        let residualPaths = makeFakeResiduals(home: home)
        let residuals = ResidualScanner.scan(app: scanned)
        let matched = residuals.filter { residualPaths.contains($0.path) }
        check(matched.count == residualPaths.count, "残留匹配 \(matched.count)/\(residualPaths.count)")
        check(residuals.contains { $0.kind == .caches }, "应识别缓存目录")
        check(residuals.contains { $0.kind == .applicationSupport }, "应识别 Application Support")
        check(residuals.contains { $0.path.contains("auselftest/demo") }, "应识别厂商目录结构")
        check(residuals.allSatisfy { !ProtectionPolicy.isForbiddenResidualPath($0.path) },
              "残留项不得包含受保护路径")

        // ---------- 4. 卸载 ----------
        let log = LogStore()
        let request = UninstallRequest(
            app: scanned,
            residuals: residuals,
            useTrash: true,
            terminateRunningApp: false,
            allowSystemApps: true,
            allowPrivilegedRemoval: false
        )
        let outcome = await Uninstaller.perform(request, log: log)
        check(outcome.appRemoved, "应用本体应被移除")
        check(!fm.fileExists(atPath: testApp.path), "应用路径应消失")
        check(!fm.fileExists(atPath: residualPaths[0]), "缓存残留应被清理")
        check(!fm.fileExists(atPath: residualPaths[1]), "Application Support 残留应被清理")
        check(outcome.trashMap.count >= 2, "应产生可撤销映射（\(outcome.trashMap.count) 项）")

        // ---------- 5. 自动复检 ----------
        guard let report = outcome.verification else {
            check(false, "卸载后应自动生成验证报告")
            finish()
            return
        }
        check(report.isFullyCleared, "复检应判定为彻底清除")
        check(report.remaining.isEmpty, "复检残留项应为 0（实际 \(report.remaining.count)）")
        check(report.clearedCount == report.checkedPaths.count,
              "所有检查项均应已清除（\(report.clearedCount)/\(report.checkedPaths.count)）")
        check(!report.appStillExists, "复检应确认应用已不存在")

        // ---------- 6. 撤销后复检应报告残留 ----------
        let restored = await Uninstaller.undo(trashMap: outcome.trashMap, log: log)
        check(restored >= 2, "撤销应恢复 \(restored) 项")
        check(fm.fileExists(atPath: testApp.path), "撤销后应用应回到原位置")
        let afterUndo = Uninstaller.verify(app: scanned, residuals: residuals, log: log)
        check(!afterUndo.isFullyCleared, "撤销后复检应检测到内容仍然存在")
        check(afterUndo.appStillExists, "撤销后复检应报告应用仍存在")

        // ---------- 7. 系统卷应用复检（只读检查，不删除） ----------
        if let music = AppScanner.makeApp(url: URL(fileURLWithPath: "/System/Applications/Music.app"), size: 0) {
            let sysReport = Uninstaller.verify(app: music, residuals: [], log: log)
            check(sysReport.appStillExists, "系统卷应用复检应如实报告仍存在")
            check(sysReport.blockedBySystemVolume, "系统卷应用复检应标记 blockedBySystemVolume")
            check(music.removalScope == .systemVolume, "Music 判定应为 systemVolume")
        } else {
            check(true, "跳过：本机无 Music.app")
        }

        // ---------- 8. 管理员授权链路（仅 --privileged 时执行，会弹系统验证窗口） ----------
        if CommandLine.arguments.contains("--privileged") {
            print("--- 管理员授权链路测试（如弹出验证窗口，请输入登录密码）---")
            let log2 = LogStore()

            // 预热：进程刚启动时首次 AppleScript 授权请求可能被系统降级，先消耗一次
            _ = runAsRoot("/usr/bin/true")
            try? await Task.sleep(nanoseconds: 400_000_000)
            let identity = runAsRoot("/usr/bin/id -u")
            check(identity.output.trimmingCharacters(in: .whitespacesAndNewlines) == "0",
                  "提权身份探测应为 root（实际 \(identity.output)）")

            let testDir = "/Library/Application Support/AUPrivTest-\(UUID().uuidString.prefix(8))"
            // 单条命令即可，避免复合命令中重定向/串联在 AppleScript 上下文的兼容问题
            var created = runAsRoot("/bin/mkdir '\(testDir)' && echo CREATED")
            if !created.ok {
                print("  · 首次提权写入被拒（\(created.output)），重试一次")
                try? await Task.sleep(nanoseconds: 400_000_000)
                created = runAsRoot("/bin/mkdir '\(testDir)' && echo CREATED")
            }
            check(created.ok, "以 root 创建受保护测试目录（\(created.output)）")
            if created.ok {
                _ = runAsRoot("echo hello > '\(testDir)/f.txt'")
            }
            check(fm.fileExists(atPath: testDir), "测试目录已存在")
            check(access(testDir, W_OK) != 0, "普通用户确实无写权限（需要提权）")

            let result = await PrivilegedExecutor.removePaths([testDir], log: log2)
            check(result.executed, "提权执行成功")
            check(!result.cancelled, "未被用户取消")
            check(result.results[testDir] == .removed,
                  "提权删除返回 OK（实际 \(result.results[testDir]?.rawValue ?? "无结果")）")
            check(!fm.fileExists(atPath: testDir), "复检确认受保护目录已被彻底删除")
        } else {
            print("  · 跳过管理员授权测试（加 --privileged 可执行）")
        }

        // ---------- 9. 进程回收（仅 --proctest：会启动真实进程树） ----------
        if CommandLine.arguments.contains("--proctest") {
            await runProcessTest(home: home, log: log)
        } else {
            print("  · 跳过进程回收测试（加 --proctest 可执行，需要 cc）")
        }

        // ---------- 10. 清理 ----------
        try? fm.removeItem(at: testApp)
        for path in residualPaths { try? fm.removeItem(atPath: path) }
        try? fm.removeItem(at: home.appendingPathComponent("Library/Application Support/auselftest"))
        for (_, trashed) in outcome.trashMap { try? fm.removeItem(atPath: trashed) }
        check(!fm.fileExists(atPath: testApp.path), "测试数据清理完成")

        finish()
    }

    // MARK: 辅助

    // MARK: 进程回收测试

    /// 端到端验证：启动一个「主进程 + 包内 helper」的真实进程树，
    /// 走完整卸载流程，确认 helper 也被终止（旧实现只按 bundleID 杀主进程，helper 会残留）。
    private static func runProcessTest(home: URL, log: LogStore) async {
        print("--- 进程回收测试（启动真实进程树）---")
        let fm = FileManager.default
        let appsDir = home.appendingPathComponent("Applications", isDirectory: true)
        let app = appsDir.appendingPathComponent("AU ProcTest.app", isDirectory: true)
        try? fm.removeItem(at: app)

        do {
            try buildProcessTestApp(at: app)
        } catch {
            check(false, "构造进程测试应用失败: \(error.localizedDescription)")
            return
        }

        let opened = NSWorkspace.shared.open(app)
        check(opened, "应用已通过 LaunchServices 启动")
        try? await Task.sleep(nanoseconds: 2_500_000_000)

        guard let scanned = AppScanner.makeApp(url: app, size: AppScanner.directorySize(app)) else {
            check(false, "进程测试应用元数据解析失败")
            return
        }

        let before = ProcessReaper.processes(for: scanned)
        check(before.count >= 2, "应发现主进程与 helper 共 ≥2 个（实际 \(before.count) 个）")
        check(before.contains { $0.matchedBy == .bundlePath }, "匹配依据应为包内路径")
        if !before.isEmpty {
            print("  · 卸载前: " + before.map { "\($0.displayName)(\($0.pid))" }.joined(separator: ", "))
        }

        let request = UninstallRequest(
            app: scanned,
            residuals: [],
            useTrash: false,
            terminateRunningApp: true,
            allowSystemApps: false,
            allowPrivilegedRemoval: false
        )
        let outcome = await Uninstaller.perform(request, log: log)

        let after = ProcessReaper.processes(for: scanned)
        check(after.isEmpty, "卸载后不应残留任何进程（实际 \(after.count) 个）")
        check(outcome.verification?.remainingProcesses.isEmpty ?? false, "复检报告不应包含残留进程")
        check(!fm.fileExists(atPath: app.path), "应用包已删除")

        if !after.isEmpty {
            print("  · 残留: " + after.map { "\($0.displayName)(\($0.pid))" }.joined(separator: ", "))
            for proc in after { kill(proc.pid, SIGKILL) }
        }
        try? fm.removeItem(at: app)
    }

    private static func buildProcessTestApp(at url: URL) throws {
        let fm = FileManager.default
        let macos = url.appendingPathComponent("Contents/MacOS")
        let helpers = url.appendingPathComponent("Contents/Helpers")
        try fm.createDirectory(at: macos, withIntermediateDirectories: true)
        try fm.createDirectory(at: helpers, withIntermediateDirectories: true)

        let tmp = fm.temporaryDirectory.appendingPathComponent("au-proctest-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        let mainSrc = tmp.appendingPathComponent("main.c")
        let helperSrc = tmp.appendingPathComponent("helper.c")
        try mainCSource.write(to: mainSrc, atomically: true, encoding: .utf8)
        try helperCSource.write(to: helperSrc, atomically: true, encoding: .utf8)

        try compile(mainSrc, to: macos.appendingPathComponent("AUProcTest"))
        try compile(helperSrc, to: helpers.appendingPathComponent("AUProcHelper"))

        let info: [String: Any] = [
            "CFBundleIdentifier": "com.jt.proctest",
            "CFBundleName": "AU ProcTest",
            "CFBundleExecutable": "AUProcTest",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1",
            "LSMinimumSystemVersion": "13.0",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: url.appendingPathComponent("Contents/Info.plist"))

        // ad-hoc 签名，避免 Gatekeeper 拦截
        let sign = Process()
        sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        sign.arguments = ["--force", "--sign", "-", url.path]
        sign.standardError = Pipe()
        try? sign.run()
        sign.waitUntilExit()
    }

    private static func compile(_ source: URL, to destination: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/cc")
        process.arguments = ["-O2", "-o", destination.path, source.path]
        let pipe = Pipe()
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let err = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw NSError(domain: "SelfTest", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "cc 编译失败: \(err.prefix(300))"])
        }
    }

    private static let helperCSource = """
    #include <unistd.h>
    int main(void) { for (;;) pause(); return 0; }
    """

    private static let mainCSource = """
    #include <unistd.h>
    #include <stdio.h>
    #include <string.h>
    #include <libgen.h>

    int main(int argc, char **argv) {
        char path[4096];
        char *dir = strdup(argv[0]);
        snprintf(path, sizeof(path), "%s/../Helpers/AUProcHelper", dirname(dir));
        if (fork() == 0) {
            execl(path, "AUProcHelper", (char *)0);
            _exit(1);
        }
        for (;;) pause();
        return 0;
    }
    """

    /// 以 root 执行命令（用于构造需要提权才能删除的测试数据）
    private static func runAsRoot(_ command: String) -> (ok: Bool, output: String) {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = "do shell script \"\(escaped)\" with administrator privileges"
        guard let script = NSAppleScript(source: source) else {
            return (false, "无法构造脚本")
        }
        var errorInfo: NSDictionary?
        let result = script.executeAndReturnError(&errorInfo)
        if let number = errorInfo?[NSAppleScript.errorNumber] as? Int {
            return (false, "错误码 \(number) \(errorInfo?[NSAppleScript.errorMessage] as? String ?? "")")
        }
        return (true, result.stringValue ?? "")
    }

    private static func buildFakeApp(at url: URL) throws {
        let fm = FileManager.default
        let contents = url.appendingPathComponent("Contents")
        let macos = contents.appendingPathComponent("MacOS")
        let resources = contents.appendingPathComponent("Resources")
        try fm.createDirectory(at: macos, withIntermediateDirectories: true)
        try fm.createDirectory(at: resources, withIntermediateDirectories: true)

        let info: [String: Any] = [
            "CFBundleIdentifier": testBundleID,
            "CFBundleName": testAppName,
            "CFBundleDisplayName": testAppName,
            "CFBundleShortVersionString": "9.9.9",
            "CFBundleVersion": "42",
            "CFBundleExecutable": "AUSelfTest",
            "CFBundlePackageType": "APPL",
            "LSMinimumSystemVersion": "13.0"
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))

        let exe = macos.appendingPathComponent("AUSelfTest")
        fm.createFile(atPath: exe.path, contents: Data("#!/bin/sh\nexit 0\n".utf8),
                      attributes: [.posixPermissions: 0o755])
        try Data(repeating: 0x41, count: 3 * 1024 * 1024)
            .write(to: resources.appendingPathComponent("payload.bin"))
    }

    private static func makeFakeResiduals(home: URL) -> [String] {
        let fm = FileManager.default
        var paths: [String] = []

        let support = home.appendingPathComponent("Library/Application Support/\(testBundleID)")
        let caches = home.appendingPathComponent("Library/Caches/\(testBundleID)")
        try? fm.createDirectory(at: support, withIntermediateDirectories: true)
        try? fm.createDirectory(at: caches, withIntermediateDirectories: true)
        try? Data(repeating: 0x42, count: 200 * 1024).write(to: support.appendingPathComponent("state.db"))
        try? Data(repeating: 0x43, count: 400 * 1024).write(to: caches.appendingPathComponent("cache.bin"))

        let prefs = home.appendingPathComponent("Library/Preferences/\(testBundleID).plist")
        try? Data("<plist/>".utf8).write(to: prefs)

        let vendorDir = home.appendingPathComponent("Library/Application Support/auselftest/demo")
        try? fm.createDirectory(at: vendorDir, withIntermediateDirectories: true)
        try? Data(repeating: 0x44, count: 64 * 1024).write(to: vendorDir.appendingPathComponent("profile.db"))

        paths.append(caches.path)
        paths.append(support.path)
        paths.append(prefs.path)
        paths.append(vendorDir.path)
        return paths
    }

    private static func check(_ condition: Bool, _ message: String) {
        total += 1
        if condition {
            print("  ✓ \(message)")
        } else {
            failures += 1
            print("  ✗ \(message)")
        }
    }

    private static func finish() {
        print("---")
        if failures == 0 {
            print("全部通过 (\(total) 项)")
        } else {
            print("失败 \(failures) / \(total) 项")
        }
        fflush(stdout)
        exit(failures == 0 ? 0 : 1)
    }
}
