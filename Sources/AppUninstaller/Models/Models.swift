import Foundation

// MARK: - 应用来源

enum AppSource: String, Codable, CaseIterable, Identifiable {
    case userInstalled   // 用户从官网 / DMG 安装
    case appStore        // Mac App Store
    case systemBuiltin   // 系统内置（/System/Applications）
    case other           // 其他位置（如 /Users/Shared）

    var id: String { rawValue }

    var label: String {
        switch self {
        case .userInstalled: return "用户安装"
        case .appStore:      return "App Store"
        case .systemBuiltin: return "系统内置"
        case .other:         return "其他位置"
        }
    }

    var symbol: String {
        switch self {
        case .userInstalled: return "arrow.down.circle"
        case .appStore:      return "bag"
        case .systemBuiltin: return "gearshape.2"
        case .other:         return "folder"
        }
    }

    var tint: String {
        switch self {
        case .userInstalled: return "blue"
        case .appStore:      return "purple"
        case .systemBuiltin: return "gray"
        case .other:         return "orange"
        }
    }
}

// MARK: - 卸载可行性

/// 应用的移除方式，决定需要什么权限、能否物理删除
enum RemovalScope: String, Codable, CaseIterable {
    /// 当前用户即可删除
    case userManaged
    /// 需要管理员（root）授权：/Applications 下属主为 root 的应用、系统级残留
    case adminRequired
    /// 位于只读签名系统卷（SSV）：物理不可删除，只能尝试强制删除或隐藏
    case systemVolume
    /// 系统关键组件，任何情况下都禁止移除
    case forbidden

    var label: String {
        switch self {
        case .userManaged:   return "可直接卸载"
        case .adminRequired: return "需授权"
        case .systemVolume:  return "只读卷"
        case .forbidden:     return "受保护"
        }
    }

    var symbol: String {
        switch self {
        case .userManaged:   return "checkmark.shield"
        case .adminRequired: return "lock.open"
        case .systemVolume:  return "lock.shield"
        case .forbidden:     return "nosign"
        }
    }

    /// 是否允许发起移除操作
    var isActionable: Bool {
        self != .forbidden
    }
}

// MARK: - 已安装应用

struct InstalledApp: Identifiable, Hashable, Codable {
    /// 稳定标识：应用包绝对路径
    var id: String { path }

    let path: String
    let name: String
    let bundleID: String?
    let shortVersion: String?
    let buildVersion: String?
    let executableName: String?
    let sizeBytes: Int64
    let modifiedDate: Date?
    let createdDate: Date?
    let source: AppSource
    let architectures: [String]
    let minimumSystemVersion: String?
    let isAppStoreSigned: Bool

    /// 可移除性判定（扫描时计算）
    var removalScope: RemovalScope
    /// 判定说明（受保护原因、需要授权的原因等）
    let protectionReason: String?

    var isProtected: Bool { removalScope == .forbidden }
    var requiresAdmin: Bool { removalScope == .adminRequired }
    var isSystemVolumeApp: Bool { removalScope == .systemVolume }

    /// Apple 官方应用（位于 /Applications 且可卸载，如 Xcode、iWork）
    var isAppleApp: Bool {
        (bundleID?.lowercased().hasPrefix("com.apple.") ?? false) && removalScope != .forbidden
    }

    var url: URL { URL(fileURLWithPath: path) }

    var displayVersion: String {
        let short = shortVersion?.trimmingCharacters(in: .whitespaces)
        let build = buildVersion?.trimmingCharacters(in: .whitespaces)
        if let short, !short.isEmpty, short != "0" {
            if let build, !build.isEmpty, build != short { return "\(short) (\(build))" }
            return short
        }
        if let build, !build.isEmpty { return build }
        return "—"
    }

    var formattedSize: String { Self.sizeFormatter.string(fromByteCount: sizeBytes) }
    var formattedModified: String {
        guard let modifiedDate else { return "—" }
        return Self.dateFormatter.string(from: modifiedDate)
    }

    static let sizeFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useKB, .useMB, .useGB]
        f.isAdaptive = true
        return f
    }()

    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    /// 搜索匹配（名称 / bundleID / 路径）
    func matches(_ keyword: String) -> Bool {
        let k = keyword.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !k.isEmpty else { return true }
        return name.lowercased().contains(k)
            || (bundleID?.lowercased().contains(k) ?? false)
            || path.lowercased().contains(k)
    }
}

// MARK: - 残留数据

enum ResidualKind: String, Codable, CaseIterable {
    case applicationSupport
    case caches
    case preferences
    case preferencesByHost
    case logs
    case savedState
    case container
    case groupContainer
    case httpStorages
    case webKit
    case cookies
    case applicationScripts
    case launchAgent
    case launchDaemon
    case receipts
    case systemLevel

    var label: String {
        switch self {
        case .applicationSupport:  return "应用支持数据"
        case .caches:              return "缓存"
        case .preferences:         return "偏好设置"
        case .preferencesByHost:   return "主机级偏好设置"
        case .logs:                return "日志"
        case .savedState:          return "窗口状态"
        case .container:           return "沙盒容器"
        case .groupContainer:      return "群组容器"
        case .httpStorages:        return "网络存储"
        case .webKit:              return "WebKit 数据"
        case .cookies:             return "Cookie"
        case .applicationScripts:  return "应用脚本"
        case .launchAgent:         return "登录项 / 代理"
        case .launchDaemon:        return "系统守护进程"
        case .receipts:            return "安装收据"
        case .systemLevel:         return "系统级数据"
        }
    }

    var symbol: String {
        switch self {
        case .applicationSupport:  return "shippingbox"
        case .caches:              return "archivebox"
        case .preferences:         return "slider.horizontal.3"
        case .preferencesByHost:   return "slider.horizontal.2.square"
        case .logs:                return "doc.text.magnifyingglass"
        case .savedState:          return "macwindow.on.rectangle"
        case .container:           return "cube.box"
        case .groupContainer:      return "cube.box.fill"
        case .httpStorages:        return "network"
        case .webKit:              return "globe"
        case .cookies:             return "circle.grid.2x2"
        case .applicationScripts:  return "applescript"
        case .launchAgent:         return "power"
        case .launchDaemon:        return "gearshape.2.fill"
        case .receipts:            return "doc.plaintext"
        case .systemLevel:         return "externaldrive"
        }
    }
}

enum RiskLevel: String, Codable, Comparable {
    case safe      // 明确属于该应用，删除无副作用
    case caution   // 可能被共享，属于该应用但删前需留意
    case risky     // 高价值/共享数据，默认不勾选

    var label: String {
        switch self {
        case .safe:    return "安全"
        case .caution: return "留意"
        case .risky:   return "谨慎"
        }
    }

    private var order: Int {
        switch self {
        case .safe: return 0
        case .caution: return 1
        case .risky: return 2
        }
    }

    static func < (lhs: RiskLevel, rhs: RiskLevel) -> Bool { lhs.order < rhs.order }
}

struct ResidualItem: Identifiable, Hashable, Codable {
    var id: String { path }

    let path: String
    let kind: ResidualKind
    let risk: RiskLevel
    let sizeBytes: Int64
    let requiresAdmin: Bool

    /// UI 选择状态，不参与持久化
    var isSelected: Bool = true

    var url: URL { URL(fileURLWithPath: path) }
    var formattedSize: String { InstalledApp.sizeFormatter.string(fromByteCount: sizeBytes) }
    var displayPath: String { (path as NSString).abbreviatingWithTildeInPath }

    private enum CodingKeys: String, CodingKey {
        case path, kind, risk, sizeBytes, requiresAdmin
    }
}

// MARK: - 操作日志

enum LogLevel: String, Codable {
    case info, success, warning, error, destructive

    var label: String {
        switch self {
        case .info:        return "信息"
        case .success:     return "成功"
        case .warning:     return "警告"
        case .error:       return "失败"
        case .destructive: return "删除"
        }
    }

    var symbol: String {
        switch self {
        case .info:        return "info.circle"
        case .success:     return "checkmark.circle.fill"
        case .warning:     return "exclamationmark.triangle.fill"
        case .error:       return "xmark.octagon.fill"
        case .destructive: return "trash.fill"
        }
    }

    var colorName: String {
        switch self {
        case .info:        return "secondary"
        case .success:     return "green"
        case .warning:     return "orange"
        case .error:       return "red"
        case .destructive: return "accent"
        }
    }
}

struct LogEntry: Identifiable, Hashable, Codable {
    var id = UUID()
    let date: Date
    let level: LogLevel
    let action: String
    let target: String
    let detail: String?

    var timeString: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: date)
    }
}

// MARK: - 清理验证报告

struct RemainderItem: Identifiable, Hashable {
    var id: String { path }
    let path: String
    let sizeBytes: Int64
    let reason: String
}

/// 清理完成后重新检测的结果
struct VerificationReport: Identifiable {
    var id = UUID()
    let appName: String
    let appPath: String
    let appStillExists: Bool
    let checkedPaths: [String]
    let clearedPaths: [String]
    let remaining: [RemainderItem]
    let freedBytes: Int64
    let checkedAt: Date
    /// 是否因只读系统卷导致无法删除
    let blockedBySystemVolume: Bool

    var isFullyCleared: Bool { !appStillExists && remaining.isEmpty }
    var remainingSize: Int64 { remaining.reduce(0) { $0 + $1.sizeBytes } }
    var clearedCount: Int { clearedPaths.count }
}

// MARK: - 工具

enum Fmt {
    static func size(_ bytes: Int64) -> String {
        InstalledApp.sizeFormatter.string(fromByteCount: bytes)
    }
}
