import SwiftUI

struct UninstallSheet: View {
    let request: UninstallRequest
    @EnvironmentObject var model: AppViewModel
    @Environment(\.dismiss) private var dismiss

    private var app: InstalledApp { request.app }
    private var selectedResiduals: [ResidualItem] { model.residuals.filter(\.isSelected) }
    private var residualSize: Int64 { selectedResiduals.reduce(0) { $0 + $1.sizeBytes } }
    private var totalSize: Int64 { app.sizeBytes + residualSize }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    warningBanner
                    appCard
                    residualBlock
                    optionsBlock
                }
                .padding(18)
            }
            Divider()
            footer
        }
        .frame(width: 600, height: 620)
        .onAppear {
            if model.residuals.isEmpty && !model.isScanningResiduals {
                model.scanResiduals(for: app)
            }
        }
    }

    // MARK: 头部

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "trash.fill")
                .font(.system(size: 15))
                .foregroundStyle(.red)
            Text("卸载 \(app.name)")
                .font(.system(size: 14, weight: .semibold))
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
    }

    private var warningBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
                Text(primaryWarning)
                    .font(.system(size: 11.5))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            if needsAuthorization {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "lock.open.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.blue)
                    Text(authWarning)
                        .font(.system(size: 11.5))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(10)
        .background((needsAuthorization ? Color.blue : Color.orange).opacity(0.10),
                    in: RoundedRectangle(cornerRadius: 8))
    }

    /// 该应用是否需要管理员授权才能移除
    private var needsAuthorization: Bool {
        app.removalScope == .adminRequired || app.removalScope == .systemVolume
    }

    private var primaryActionTitle: String {
        if app.isSystemVolumeApp { return "授权并尝试删除" }
        if needsAuthorization { return "授权并删除" }
        return model.useTrash ? "移入废纸篓" : "永久删除"
    }

    private var primaryWarning: String {
        if app.isSystemVolumeApp {
            return "此应用位于只读签名的系统卷（SSV），受 SIP 保护。删除请求会以管理员权限执行，但系统通常会拒绝；失败后可选择「隐藏」。"
        }
        if needsAuthorization {
            return "移除该应用需要管理员权限，其内容不会进入废纸篓，删除后无法撤销。"
        }
        return model.useTrash
            ? "应用与所选数据将被移入废纸篓，可在本次会话内撤销，或从废纸篓手动恢复。"
            : "已关闭「移入废纸篓」：所选内容将被立即永久删除，无法恢复，也无法撤销。"
    }

    private var authWarning: String {
        "点击下方按钮后，系统会弹出验证窗口，需要输入本机登录密码完成授权；多次操作只会询问一次。"
    }

    // MARK: 应用卡片

    private var appCard: some View {
        HStack(spacing: 12) {
            Image(nsImage: IconProvider.shared.icon(for: app.path, size: 44))
                .resizable()
                .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name).font(.system(size: 13, weight: .medium))
                Text(app.path)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Text(app.formattedSize)
                .font(.system(size: 12, weight: .medium).monospacedDigit())
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
    }

    // MARK: 残留

    private var residualBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("同时清理关联数据")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                if model.isScanningResiduals {
                    ProgressView().controlSize(.small)
                    Text("扫描中…").font(.system(size: 10.5)).foregroundStyle(.secondary)
                } else if !model.residuals.isEmpty {
                    Button("全选") { model.setAllResidualsSelected(true) }
                        .buttonStyle(.link).font(.system(size: 10.5))
                    Button("全不选") { model.setAllResidualsSelected(false) }
                        .buttonStyle(.link).font(.system(size: 10.5))
                }
            }

            if !model.residuals.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(model.residuals.enumerated()), id: \.element.id) { index, item in
                        if index > 0 { Divider().opacity(0.35) }
                        ResidualRow(item: item, isOn: Binding(
                            get: { item.isSelected },
                            set: { model.setResidualSelected(item.id, $0) }
                        ))
                    }
                }
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))

                Text("标注「谨慎」的项目可能包含用户数据（如沙盒容器内的文档）；「安全」项删除后无副作用。")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !model.isScanningResiduals {
                Text("未发现残留数据。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: 选项

    private var optionsBlock: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("选项").font(.system(size: 12, weight: .semibold))

            if needsAuthorization {
                HStack(spacing: 5) {
                    Image(systemName: "info.circle").font(.system(size: 10))
                    Text("以管理员权限删除的内容不进入废纸篓，删除后无法撤销")
                        .font(.system(size: 11))
                }
                .foregroundStyle(.secondary)
            } else {
                Toggle("移入废纸篓（可恢复、可撤销）", isOn: $model.useTrash)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11.5))
            }

            Toggle("卸载前退出正在运行的应用实例", isOn: $model.terminateBeforeUninstall)
                .toggleStyle(.checkbox)
                .font(.system(size: 11.5))

            Toggle("权限不足时请求管理员授权（输入登录密码）", isOn: $model.allowPrivilegedRemoval)
                .toggleStyle(.checkbox)
                .font(.system(size: 11.5))

            if needsAuthorization && !model.allowPrivilegedRemoval {
                Text("关闭此项后将无法移除需要管理员权限的内容。")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .padding(.leading, 18)
            }
        }
    }

    // MARK: 底部

    private var footer: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text("预计释放 \(Fmt.size(totalSize))")
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                Text("应用 \(app.formattedSize) + 关联数据 \(Fmt.size(residualSize))")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("取消") {
                model.pendingRequest = nil
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            .disabled(model.isUninstalling)

            Button(role: .destructive) {
                Task { await model.confirmUninstall() }
            } label: {
                HStack(spacing: 6) {
                    if model.isUninstalling {
                        ProgressView().controlSize(.small)
                        Text("正在卸载…")
                    } else {
                        Image(systemName: needsAuthorization ? "lock.open" : (model.useTrash ? "trash" : "trash.slash"))
                        Text(primaryActionTitle)
                    }
                }
                .frame(minWidth: 86)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .keyboardShortcut(.defaultAction)
            .disabled(model.isUninstalling || model.isScanningResiduals)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.bar)
    }
}
