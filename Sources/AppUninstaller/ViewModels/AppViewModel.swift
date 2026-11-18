import AppKit
import SwiftUI

// MARK: - 排序 / 筛选

enum AppSortOption: String, CaseIterable, Identifiable {
    case nameAsc, nameDesc, sizeDesc, sizeAsc, dateDesc

    var id: String { rawValue }

    var label: String {
        switch self {
        case .nameAsc:  return "名称 A→Z"
        case .nameDesc: return "名称 Z→A"
        case .sizeDesc: return "占用从大到小"
        case .sizeAsc:  return "占用从小到大"
        case .dateDesc: return "最近修改优先"
        }
    }
}

enum SidebarScope: Hashable, Identifiable {
    case all
    case removable
    case large
    case protectedApps
    case source(AppSource)

    var id: String {
        switch self {
        case .all:            return "all"
        case .removable:      return "removable"
        case .large:          return "large"
        case .protectedApps:  return "protected"
        case .source(let s):  return "src-\(s.rawValue)"
        }
    }

    var title: String {
        switch self {
        case .all:               return "全部应用"
        case .removable:         return "可卸载"
        case .large:             return "占用 > 1 GB"
        case .protectedApps:     return "受系统保护"
        case .source(let s):     return s.label
        }
    }

    var symbol: String {
        switch self {
        case .all:               return "square.grid.2x2"
        case .removable:         return "trash"
        case .large:             return "internaldrive"
        case .protectedApps:     return "lock.shield"
        case .source(let s):     return s.symbol
        }
    }
}

    /// 卸载结果面板载荷
struct UninstallResultPayload: Identifiable {
    var id = UUID()
    let app: InstalledApp
    let outcome: UninstallOutcome
}

/// 线程安全的进度盒子（仅在主线程写入）
final class ProgressBox: ObservableObject, @unchecked Sendable {
    @Published var value: Double = 0
}

/// UserDefaults 读写助手
enum Prefs {
    /// 注册默认值，避免 `bool(forKey:)` 在键缺失时返回 false 造成语义偏差
    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            "useTrash": true,
            "terminateBeforeUninstall": true,
            "allowSystemApps": true,
            "allowPrivilegedRemoval": true,
            "showProtectedApps": true
        ])
    }

    static func bool(_ key: String, default def: Bool) -> Bool {
        registerDefaults()
        return UserDefaults.standard.bool(forKey: key)
    }

    static func set(_ value: Bool, _ key: String) {
        UserDefaults.standard.set(value, forKey: key)
    }
}

// MARK: - 视图模型

@MainActor
final class AppViewModel: ObservableObject {

    // 数据
    @Published private(set) var apps: [InstalledApp] = []
    @Published private(set) var isScanning = false
    @Published private(set) var lastScanDate: Date?
    @Published private(set) var residuals: [ResidualItem] = []
    @Published private(set) var isScanningResiduals = false
    @Published private(set) var isUninstalling = false
    @Published private(set) var uninstallPhase: String = ""

    // 交互状态
    @Published var searchText: String = ""
    @Published var sortOption: AppSortOption = .sizeDesc
    @Published var scope: SidebarScope = .all
    @Published var selection: String?
    @Published var showLogs = false
    @Published var showSettings = false
    @Published var pendingRequest: UninstallRequest?
    @Published var alertMessage: String?
    @Published var resultPayload: UninstallResultPayload?
    @Published private(set) var lastTrashMap: [String: String] = [:]

    // MARK: 用户偏好（UserDefaults 持久化；用 @Published 以便直接绑定）

    @Published var useTrash: Bool = Prefs.bool("useTrash", default: true) {
        didSet { Prefs.set(useTrash, "useTrash") }
    }
    @Published var terminateBeforeUninstall: Bool = Prefs.bool("terminateBeforeUninstall", default: true) {
        didSet { Prefs.set(terminateBeforeUninstall, "terminateBeforeUninstall") }
    }
    /// 允许移除系统内置应用（/System/Applications，只读卷）
    @Published var allowSystemApps: Bool = Prefs.bool("allowSystemApps", default: true) {
        didSet { Prefs.set(allowSystemApps, "allowSystemApps") }
    }
    /// 权限不足时请求管理员授权（完成清理的必要能力，默认开启）
    @Published var allowPrivilegedRemoval: Bool = Prefs.bool("allowPrivilegedRemoval", default: true) {
        didSet { Prefs.set(allowPrivilegedRemoval, "allowPrivilegedRemoval") }
    }
    @Published var showProtectedApps: Bool = Prefs.bool("showProtectedApps", default: true) {
        didSet { Prefs.set(showProtectedApps, "showProtectedApps") }
    }

    let logStore = LogStore()
    let progressBox = ProgressBox()

    var selectedApp: InstalledApp? {
        guard let selection else { return nil }
        return apps.first { $0.id == selection }
    }

    // MARK: 扫描

    func refresh() {
        guard !isScanning else { return }
        isScanning = true
        progressBox.value = 0
        let box = progressBox

        Task {
            let scanned = await Task.detached(priority: .userInitiated) { () -> [InstalledApp] in
                AppScanner.scan { p in
                    DispatchQueue.main.async { box.value = p }
                }
            }.value

            self.apps = scanned
            self.isScanning = false
            self.progressBox.value = 1
            self.lastScanDate = Date()
            AppScanner.saveCache(scanned)
            self.logStore.append(.info, action: "扫描完成", target: "系统应用",
                                 detail: "共 \(scanned.count) 个应用，合计 \(Fmt.size(scanned.reduce(0) { $0 + $1.sizeBytes }))")

            // 选中项已不存在时，自动定位到当前排序下的第一项，避免"详情与列表不同步"
            let stillExists = self.selection.map { sel in scanned.contains { $0.id == sel } } ?? false
            if !stillExists {
                self.selection = self.filteredApps.first?.id
            }
        }
    }

    /// 启动时先展示缓存，再静默刷新
    func bootstrap() {
        let cached = AppScanner.loadCache()
        if !cached.isEmpty {
            apps = cached
            selection = cached.sorted { $0.sizeBytes > $1.sizeBytes }.first?.id
        }
        refresh()
    }

    // MARK: 残留扫描

    func scanResiduals(for app: InstalledApp) {
        isScanningResiduals = true
        residuals = []
        Task {
            let items = await Task.detached(priority: .userInitiated) { () -> [ResidualItem] in
                ResidualScanner.scan(app: app)
            }.value
            self.residuals = items
            self.isScanningResiduals = false
        }
    }

    func setResidualSelected(_ id: String, _ value: Bool) {
        guard let index = residuals.firstIndex(where: { $0.id == id }) else { return }
        residuals[index].isSelected = value
    }

    func setAllResidualsSelected(_ value: Bool) {
        for index in residuals.indices {
            residuals[index].isSelected = value
        }
    }

    // MARK: 卸载

    func prepareUninstall(for app: InstalledApp) {
        guard app.removalScope.isActionable else {
            alertMessage = app.protectionReason ?? "该应用受系统保护，无法卸载。"
            return
        }
        if app.isSystemVolumeApp && !allowSystemApps {
            alertMessage = "系统内置应用位于只读系统卷，需要先在「设置 › 卸载行为」中开启「允许移除系统内置应用」。"
            return
        }
        scanResiduals(for: app)
        pendingRequest = UninstallRequest(
            app: app,
            residuals: [],
            useTrash: useTrash,
            terminateRunningApp: terminateBeforeUninstall,
            allowSystemApps: allowSystemApps,
            allowPrivilegedRemoval: allowPrivilegedRemoval
        )
    }

    /// 在确认框中点击"确认卸载"
    func confirmUninstall() async -> UninstallOutcome? {
        guard var request = pendingRequest else { return nil }
        request.residuals = residuals
        request.useTrash = useTrash
        request.terminateRunningApp = terminateBeforeUninstall
        request.allowSystemApps = allowSystemApps
        request.allowPrivilegedRemoval = allowPrivilegedRemoval

        isUninstalling = true
        let outcome = await Uninstaller.perform(request, log: logStore)
        isUninstalling = false

        if outcome.appRemoved {
            apps.removeAll { $0.id == request.app.path }
            if selection == request.app.path { selection = nil }
            lastTrashMap = outcome.trashMap
        }
        pendingRequest = nil
        residuals = []

        // 弹出清理结果面板（含自动复核结果）
        resultPayload = UninstallResultPayload(app: request.app, outcome: outcome)
        return outcome
    }

    /// 对残留项重试（以管理员权限）
    func retryPrivilegedRemoval() async {
        guard let payload = resultPayload,
              let report = payload.outcome.verification,
              !report.remaining.isEmpty else { return }

        let paths = report.remaining.map(\.path)
        isUninstalling = true
        let result = await PrivilegedExecutor.removePaths(paths, log: logStore)
        isUninstalling = false

        if result.cancelled {
            alertMessage = "已取消管理员授权。"
            return
        }

        // 重试后再次检测
        let items = report.remaining.map {
            ResidualItem(path: $0.path, kind: .systemLevel, risk: .caution,
                         sizeBytes: $0.sizeBytes, requiresAdmin: true, isSelected: true)
        }
        let newReport = Uninstaller.verify(app: payload.app, residuals: items, log: logStore)

        var outcome = payload.outcome
        outcome.verification = newReport
        resultPayload = UninstallResultPayload(app: payload.app, outcome: outcome)

        if newReport.isFullyCleared {
            apps.removeAll { $0.id == payload.app.path }
        }
    }

    /// 重新检测（不执行删除）
    func reverifyResult() async {
        guard let payload = resultPayload else { return }
        let items = (payload.outcome.verification?.remaining ?? []).map {
            ResidualItem(path: $0.path, kind: .systemLevel, risk: .caution,
                         sizeBytes: $0.sizeBytes, requiresAdmin: false, isSelected: true)
        }
        let report = Uninstaller.verify(app: payload.app, residuals: items, log: logStore)
        var outcome = payload.outcome
        outcome.verification = report
        resultPayload = UninstallResultPayload(app: payload.app, outcome: outcome)
    }

    /// 只读卷上的系统应用：选择隐藏作为替代
    func hideSystemApp() async {
        guard let payload = resultPayload else { return }
        let app = payload.app
        let result = SystemAppHider.hide(path: app.path)
        if result.ok {
            logStore.append(.warning, action: "已隐藏系统应用", target: app.name,
                            detail: "已从启动台与聚焦移除（可在设置中恢复）")
            alertMessage = "已隐藏「\(app.name)」。\n可从「设置 › 卸载行为 › 恢复全部系统应用」还原。"
        } else {
            logStore.append(.error, action: "隐藏失败", target: app.name, detail: result.message)
            alertMessage = "隐藏失败：\(result.message)"
        }
        resultPayload = nil
    }

    func undoLastUninstall() {
        guard !lastTrashMap.isEmpty else { return }
        let map = lastTrashMap
        Task {
            let count = await Uninstaller.undo(trashMap: map, log: logStore)
            self.lastTrashMap = [:]
            self.logStore.append(.info, action: "撤销操作", target: "\(count) 项已恢复")
            self.refresh()
        }
    }

    // MARK: 派生数据

    var filteredApps: [InstalledApp] {
        var list = apps

        switch scope {
        case .all:
            break
        case .removable:
            list = list.filter { $0.removalScope.isActionable }
        case .large:
            list = list.filter { $0.sizeBytes >= 1_000_000_000 }
        case .protectedApps:
            list = list.filter { !$0.removalScope.isActionable || $0.isSystemVolumeApp }
        case .source(let source):
            list = list.filter { $0.source == source }
        }

        if !showProtectedApps && scope != .protectedApps {
            list = list.filter { $0.removalScope != .forbidden }
        }

        let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !keyword.isEmpty {
            list = list.filter { $0.matches(keyword) }
        }

        switch sortOption {
        case .nameAsc:  list.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .nameDesc: list.sort { $0.name.localizedStandardCompare($1.name) == .orderedDescending }
        case .sizeDesc: list.sort { $0.sizeBytes > $1.sizeBytes }
        case .sizeAsc:  list.sort { $0.sizeBytes < $1.sizeBytes }
        case .dateDesc: list.sort { ($0.modifiedDate ?? .distantPast) > ($1.modifiedDate ?? .distantPast) }
        }
        return list
    }

    func count(for scope: SidebarScope) -> Int {
        switch scope {
        case .all:           return apps.count
        case .removable:     return apps.filter { $0.removalScope.isActionable }.count
        case .large:         return apps.filter { $0.sizeBytes >= 1_000_000_000 }.count
        case .protectedApps: return apps.filter { !$0.removalScope.isActionable || $0.isSystemVolumeApp }.count
        case .source(let s): return apps.filter { $0.source == s }.count
        }
    }

    var totalSize: Int64 { apps.reduce(0) { $0 + $1.sizeBytes } }
    var totalSizeFormatted: String { Fmt.size(totalSize) }
    var removableSize: Int64 { apps.filter { $0.removalScope.isActionable }.reduce(0) { $0 + $1.sizeBytes } }

    /// 应用当前是否有运行中的实例
    func isRunning(_ app: InstalledApp) -> Bool {
        guard let bid = app.bundleID else { return false }
        return !NSRunningApplication.runningApplications(withBundleIdentifier: bid).isEmpty
    }
}
