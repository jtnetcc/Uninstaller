import SwiftUI

struct DetailView: View {
    @EnvironmentObject var model: AppViewModel
    @State private var isRunning = false

    var body: some View {
        Group {
            if let app = model.selectedApp {
                detail(for: app)
            } else {
                placeholder
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .task(id: model.selection) {
            if let app = model.selectedApp {
                isRunning = model.isRunning(app)
            } else {
                isRunning = false
            }
        }
    }

    // MARK: 空状态

    private var placeholder: some View {
        VStack(spacing: 10) {
            Image(systemName: "sidebar.right")
                .font(.system(size: 34))
                .foregroundStyle(.tertiary)
            Text("选择一个应用查看详情")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: 详情

    private func detail(for app: InstalledApp) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header(app)
                    if let reason = app.protectionReason {
                        if app.removalScope == .forbidden {
                            protectionBanner(reason)
                        } else if app.isSystemVolumeApp {
                            systemVolumeNotice(reason)
                        } else if app.requiresAdmin {
                            adminRequiredNotice(reason)
                        }
                    }
                    if app.isAppleApp {
                        appleAppNotice
                    }
                    infoCard(app)
                    residualSection(app)
                    Color.clear.frame(height: 4)
                }
                .padding(20)
            }

            Divider()
            actionBar(app)
        }
    }

    // MARK: 头部

    private func header(_ app: InstalledApp) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(nsImage: IconProvider.shared.icon(for: app.path, size: 72))
                .resizable()
                .frame(width: 64, height: 64)

            VStack(alignment: .leading, spacing: 4) {
                Text(app.name)
                    .font(.system(size: 19, weight: .semibold))
                    .lineLimit(2)
                Text(app.displayVersion)
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Text(app.source.label)
                        .font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.12), in: Capsule())
                    if app.removalScope != .userManaged {
                        Label(app.removalScope.label, systemImage: app.removalScope.symbol)
                            .font(.system(size: 10))
                            .foregroundStyle(app.removalScope == .forbidden ? Color.secondary : Color.orange)
                    }
                    if isRunning {
                        Label("运行中", systemImage: "play.circle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.green)
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: 保护提示

    private func protectionBanner(_ reason: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "lock.shield.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("此应用受系统保护")
                    .font(.system(size: 12, weight: .semibold))
                Text(reason)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: 只读系统卷提示

    private func systemVolumeNotice(_ reason: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "lock.shield.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("系统内置应用（只读卷）")
                    .font(.system(size: 12, weight: .semibold))
                Text(reason + "。仍可发起删除尝试：将以管理员权限执行，必要时可改为「隐藏」。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: 需要管理员授权

    private func adminRequiredNotice(_ reason: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "lock.open.fill")
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text("需要管理员授权")
                    .font(.system(size: 12, weight: .semibold))
                Text(reason)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: Apple 官方应用提示

    private var appleAppNotice: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "apple.logo")
                .foregroundStyle(.blue)
            Text("这是 Apple 官方应用。卸载后可从 App Store 重新下载；系统不会因此损坏。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: 信息卡

    private func infoCard(_ app: InstalledApp) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            infoRow("安装位置", value: app.path, mono: true, copyable: true) {
                NSWorkspace.shared.activateFileViewerSelecting([app.url])
            }
            divider
            infoRow("占用空间", value: app.formattedSize, mono: true)
            divider
            infoRow("Bundle ID", value: app.bundleID ?? "—", mono: true, copyable: true)
            divider
            infoRow("可执行文件", value: app.executableName ?? "—", mono: true)
            divider
            infoRow("架构", value: app.architectures.joined(separator: " + "), mono: false)
            divider
            infoRow("最低系统", value: app.minimumSystemVersion ?? "—", mono: true)
            divider
            infoRow("安装 / 更新", value: app.formattedModified, mono: true)
            divider
            infoRow("分发方式", value: app.isAppStoreSigned ? "Mac App Store" : "第三方 / 开发者签名", mono: false)
        }
        .padding(.horizontal, 12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.quaternary))
    }

    private var divider: some View { Divider().opacity(0.55) }

    private func infoRow(_ title: String,
                         value: String,
                         mono: Bool,
                         copyable: Bool = false,
                         reveal: (() -> Void)? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .leading)
            Text(value)
                .font(.system(size: mono ? 11 : 11.5, design: mono ? .monospaced : .default))
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            if copyable {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(value, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc").font(.system(size: 10))
                }
                .buttonStyle(.borderless)
                .help("复制")
            }
            if let reveal {
                Button(action: reveal) {
                    Image(systemName: "magnifyingglass").font(.system(size: 10))
                }
                .buttonStyle(.borderless)
                .help("在 Finder 中显示")
            }
        }
        .padding(.vertical, 7)
    }

    // MARK: 残留数据

    private func residualSection(_ app: InstalledApp) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("关联数据")
                    .font(.system(size: 12, weight: .semibold))
                if !model.residuals.isEmpty {
                    Text("\(model.residuals.count) 项 · \(Fmt.size(model.residuals.reduce(0) { $0 + $1.sizeBytes }))")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if model.isScanningResiduals {
                    ProgressView().controlSize(.small)
                } else {
                    Button(model.residuals.isEmpty ? "扫描残留" : "重新扫描") {
                        model.scanResiduals(for: app)
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
                }
            }

            if model.isScanningResiduals {
                Text("正在检索 Application Support、Caches、Preferences、Containers 等位置…")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else if model.residuals.isEmpty {
                Text("尚未扫描。点击右上角「扫描残留」查找配置文件、缓存与容器数据。")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(model.residuals.enumerated()), id: \.element.id) { index, item in
                        if index > 0 { Divider().opacity(0.4) }
                        ResidualRow(item: item,
                                    isOn: Binding(
                                        get: { item.isSelected },
                                        set: { model.setResidualSelected(item.id, $0) }
                                    ))
                    }
                }
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.quaternary))
            }
        }
    }

    // MARK: 底部操作

    private func actionBar(_ app: InstalledApp) -> some View {
        HStack(spacing: 10) {
            if app.removalScope == .forbidden {
                Image(systemName: "nosign").font(.system(size: 10)).foregroundStyle(.secondary)
                Text("受保护组件，不可移除")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else if app.isSystemVolumeApp {
                Image(systemName: "lock.shield").font(.system(size: 10)).foregroundStyle(.orange)
                Text("只读系统卷")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else if app.requiresAdmin {
                Image(systemName: "lock.open").font(.system(size: 10)).foregroundStyle(.blue)
                Text("需要管理员授权")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                NSWorkspace.shared.open(app.url)
            } label: {
                Label("打开", systemImage: "play.circle")
            }
            Button(role: .destructive) {
                model.prepareUninstall(for: app)
            } label: {
                Label(uninstallTitle(app), systemImage: app.isSystemVolumeApp ? "lock.open" : "trash")
                    .frame(minWidth: 80)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(app.removalScope == .forbidden)
            .keyboardShortcut(.delete, modifiers: .command)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func uninstallTitle(_ app: InstalledApp) -> String {
        if app.isSystemVolumeApp { return "移除…" }
        if app.requiresAdmin { return "授权卸载…" }
        return "卸载…"
    }
}

// MARK: - 残留行

struct ResidualRow: View {
    let item: ResidualItem
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 9) {
            Toggle("", isOn: $isOn)
                .toggleStyle(.checkbox)
                .labelsHidden()

            Image(systemName: item.kind.symbol)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .frame(width: 14)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(item.kind.label)
                        .font(.system(size: 11.5))
                    riskBadge
                    if item.requiresAdmin {
                        Image(systemName: "lock.open")
                            .font(.system(size: 8))
                            .foregroundStyle(.orange)
                            .help("需要管理员权限")
                    }
                }
                Text(item.displayPath)
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 6)

            Text(item.formattedSize)
                .font(.system(size: 10.5).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .opacity(isOn ? 1 : 0.5)
    }

    private var riskBadge: some View {
        Text(item.risk.label)
            .font(.system(size: 8.5, weight: .medium))
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }

    private var color: Color {
        switch item.risk {
        case .safe:    return .green
        case .caution: return .orange
        case .risky:   return .red
        }
    }
}
