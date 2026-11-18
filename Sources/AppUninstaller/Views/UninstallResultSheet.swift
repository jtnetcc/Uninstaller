import SwiftUI

/// 卸载完成后的结果面板：展示自动复检结果与残留项
struct UninstallResultSheet: View {
    let payload: UninstallResultPayload
    @EnvironmentObject var model: AppViewModel
    @Environment(\.dismiss) private var dismiss

    private var report: VerificationReport? { payload.outcome.verification }
    private var outcome: UninstallOutcome { payload.outcome }

    private var isFullyCleared: Bool { report?.isFullyCleared ?? false }
    private var stillBlocked: Bool {
        (report?.appStillExists ?? true) && (outcome.blockedBySystemVolume || payload.app.isSystemVolumeApp)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    statsRow
                    if stillBlocked { systemVolumeBlock }
                    if !isFullyCleared { remainingBlock }
                    if !outcome.errors.isEmpty { errorBlock }
                }
                .padding(18)
            }
            Divider()
            footer
        }
        .frame(width: 620, height: 560)
    }

    // MARK: 头部

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: headerSymbol)
                .font(.system(size: 26))
                .foregroundStyle(headerColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(headerTitle)
                    .font(.system(size: 14, weight: .semibold))
                Text("\(payload.app.name) · 复检于 \(timeString)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private var headerTitle: String {
        if isFullyCleared { return "已彻底清理" }
        if stillBlocked { return "系统内置应用无法物理删除" }
        return "清理完成，仍有残留"
    }

    private var headerSymbol: String {
        if isFullyCleared { return "checkmark.seal.fill" }
        if stillBlocked { return "lock.shield.fill" }
        return "exclamationmark.triangle.fill"
    }

    private var headerColor: Color {
        if isFullyCleared { return .green }
        if stillBlocked { return .orange }
        return .yellow
    }

    private var timeString: String {
        guard let date = report?.checkedAt else { return "—" }
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: date)
    }

    // MARK: 统计

    private var statsRow: some View {
        HStack(spacing: 10) {
            statCard(value: "\(report?.clearedCount ?? 0)",
                     label: "已确认清除", color: .green, symbol: "checkmark.circle")
            statCard(value: "\(report?.remaining.count ?? 0)",
                     label: "仍残留", color: (report?.remaining.isEmpty ?? true) ? .secondary : .orange,
                     symbol: "exclamationmark.circle")
            statCard(value: Fmt.size(outcome.freedBytes),
                     label: "已释放空间", color: .blue, symbol: "internaldrive")
        }
    }

    private func statCard(value: String, label: String, color: Color, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 10)).foregroundStyle(color)
                Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Text(value)
                .font(.system(size: 16, weight: .semibold).monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
    }

    // MARK: 只读系统卷

    private var systemVolumeBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("为什么删不掉？", systemImage: "info.circle")
                .font(.system(size: 12, weight: .semibold))
            Text("该应用位于只读签名的系统卷（SSV）上，受 SIP 保护，即使以 root 身份也无法物理删除——这是 macOS 11 之后的设计，非权限问题。\n\n可以选择「隐藏」：从启动台与聚焦中移除入口（文件仍在，可随时恢复），或在结果面板下方重试管理员删除。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: 残留列表

    private var remainingBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("仍未清除的项目")
                    .font(.system(size: 12, weight: .semibold))
                if let report, !report.remaining.isEmpty {
                    Text("\(report.remaining.count) 项 · \(Fmt.size(report.remainingSize))")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            if let report, !report.remaining.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(report.remaining.enumerated()), id: \.element.id) { index, item in
                        if index > 0 { Divider().opacity(0.35) }
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.circle.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(.orange)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.path)
                                    .font(.system(size: 10, design: .monospaced))
                                    .lineLimit(2)
                                    .truncationMode(.middle)
                                Text(item.reason)
                                    .font(.system(size: 9.5))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 6)
                            Text(Fmt.size(item.sizeBytes))
                                .font(.system(size: 10).monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                    }
                }
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
            } else {
                Text("所有目标路径均已确认不存在。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: 错误

    private var errorBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("过程信息").font(.system(size: 11, weight: .semibold))
            ForEach(Array(outcome.errors.enumerated()), id: \.offset) { _, message in
                Text("· \(message)")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: 底部

    private var footer: some View {
        HStack(spacing: 8) {
            if !model.lastTrashMap.isEmpty {
                Button {
                    model.undoLastUninstall()
                    model.resultPayload = nil
                    dismiss()
                } label: {
                    Label("撤销", systemImage: "arrow.uturn.backward")
                }
            }

            if stillBlocked {
                Button {
                    Task {
                        await model.hideSystemApp()
                        dismiss()
                    }
                } label: {
                    Label("隐藏此应用", systemImage: "eye.slash")
                }
                .help("从启动台与聚焦中移除入口（可恢复）")
            }

            Spacer()

            Button {
                Task { await model.reverifyResult() }
            } label: {
                Label("重新检测", systemImage: "arrow.clockwise")
            }
            .disabled(model.isUninstalling)

            if !(report?.remaining.isEmpty ?? true) {
                Button {
                    Task { await model.retryPrivilegedRemoval() }
                } label: {
                    HStack(spacing: 5) {
                        if model.isUninstalling {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "lock.open")
                        }
                        Text("以管理员权限重试")
                    }
                }
                .disabled(model.isUninstalling)
            }

            Button("完成") {
                model.resultPayload = nil
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.bar)
    }
}
