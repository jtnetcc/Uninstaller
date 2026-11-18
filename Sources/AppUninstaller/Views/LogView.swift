import SwiftUI

struct LogView: View {
    @EnvironmentObject var model: AppViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var filter: LogFilter = .all

    enum LogFilter: String, CaseIterable, Identifiable {
        case all, success, failure, destructive
        var id: String { rawValue }
        var label: String {
            switch self {
            case .all:         return "全部"
            case .success:     return "成功"
            case .failure:     return "警告 / 失败"
            case .destructive: return "删除记录"
            }
        }
    }

    private var entries: [LogEntry] {
        switch filter {
        case .all:
            return model.logStore.entries
        case .success:
            return model.logStore.entries.filter { $0.level == .success }
        case .failure:
            return model.logStore.entries.filter { $0.level == .warning || $0.level == .error }
        case .destructive:
            return model.logStore.entries.filter { $0.level == .destructive }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if entries.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 30))
                        .foregroundStyle(.tertiary)
                    Text("暂无日志记录")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(entries) { entry in
                            LogRow(entry: entry)
                            Divider().opacity(0.3)
                        }
                    }
                }
            }
            Divider()
            footer
        }
        .frame(width: 760, height: 560)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("操作日志")
                .font(.system(size: 14, weight: .semibold))
            Picker("", selection: $filter) {
                ForEach(LogFilter.allCases) { f in
                    Text(f.label).tag(f)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 300)

            Spacer()

            Button {
                LogStore.revealLogFolder()
            } label: {
                Label("日志文件", systemImage: "folder")
            }
            Button {
                model.logStore.clear()
            } label: {
                Label("清空", systemImage: "trash")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var footer: some View {
        HStack {
            Text("共 \(model.logStore.entries.count) 条记录 · 持久化于 ~/Library/Logs/AppUninstaller/")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Spacer()
            Button("关闭") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }
}

struct LogRow: View {
    let entry: LogEntry

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: entry.level.symbol)
                .font(.system(size: 10))
                .foregroundStyle(color)
                .frame(width: 14)
                .padding(.top, 2)

            Text(entry.timeString)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 56, alignment: .leading)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.action)
                        .font(.system(size: 11.5, weight: .medium))
                    Text(entry.target)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if let detail = entry.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
    }

    private var color: Color {
        switch entry.level {
        case .info:        return .secondary
        case .success:     return .green
        case .warning:     return .orange
        case .error:       return .red
        case .destructive: return .accentColor
        }
    }
}
