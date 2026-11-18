import SwiftUI

struct AppListView: View {
    @EnvironmentObject var model: AppViewModel

    var body: some View {
        VStack(spacing: 0) {
            listHeader
            Divider()
            content
            Divider()
            statusBar
        }
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "搜索名称、Bundle ID 或路径")
    }

    // MARK: 表头

    private var listHeader: some View {
        HStack(spacing: 12) {
            Text("应用").frame(maxWidth: .infinity, alignment: .leading)
            Text("版本").frame(width: 96, alignment: .trailing)
            Text("占用").frame(width: 84, alignment: .trailing)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.leading, 46)
        .padding(.vertical, 7)
    }

    // MARK: 列表

    @ViewBuilder
    private var content: some View {
        if model.isScanning && model.apps.isEmpty {
            scanningPlaceholder
        } else if model.filteredApps.isEmpty {
            emptyPlaceholder
        } else {
            List(selection: $model.selection) {
                ForEach(model.filteredApps) { app in
                    AppRow(app: app)
                        .tag(app.id)
                        .contextMenu { contextMenu(for: app) }
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
        }
    }

    private var scanningPlaceholder: some View {
        VStack(spacing: 14) {
            ProgressView(value: model.progressBox.value)
                .frame(width: 220)
            Text("正在扫描已安装的应用…")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("\(Int(model.progressBox.value * 100))%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyPlaceholder: some View {
        VStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text("没有匹配的应用")
                .font(.headline)
            Text(model.searchText.isEmpty ? "试试切换左侧分类" : "换个关键词试试")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !model.searchText.isEmpty {
                Button("清空搜索") { model.searchText = "" }
                    .buttonStyle(.link)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: 右键菜单

    @ViewBuilder
    private func contextMenu(for app: InstalledApp) -> some View {
        Button("在 Finder 中显示") {
            NSWorkspace.shared.activateFileViewerSelecting([app.url])
        }
        Button("打开应用") {
            NSWorkspace.shared.open(app.url)
        }
        Button("复制 Bundle ID") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(app.bundleID ?? app.path, forType: .string)
        }
        Divider()
        Button("卸载…") { model.prepareUninstall(for: app) }
            .disabled(app.removalScope == .forbidden)
        if app.removalScope == .forbidden {
            Text("受系统保护，无法卸载")
        }
    }

    // MARK: 状态栏

    private var statusBar: some View {
        HStack(spacing: 12) {
            Text("\(model.filteredApps.count) 个应用")
                .font(.caption)
                .foregroundStyle(.secondary)

            if model.isScanning {
                ProgressView().controlSize(.mini)
                Text("扫描中 \(Int(model.progressBox.value * 100))%")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text("共 \(Fmt.size(model.filteredApps.reduce(0) { $0 + $1.sizeBytes }))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(.bar)
    }
}

// MARK: - 行

struct AppRow: View {
    let app: InstalledApp

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: IconProvider.shared.icon(for: app.path, size: 32))
                .resizable()
                .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(app.name)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    if app.removalScope != .userManaged {
                        Image(systemName: app.removalScope.symbol)
                            .font(.system(size: 9))
                            .foregroundStyle(app.removalScope == .forbidden ? Color.secondary : Color.orange)
                    }
                    sourceBadge
                }
                Text(app.bundleID ?? (app.path as NSString).abbreviatingWithTildeInPath)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            Text(app.shortVersion ?? "—")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 96, alignment: .trailing)
                .lineLimit(1)

            Text(app.formattedSize)
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(app.sizeBytes > 1_000_000_000 ? .primary : .secondary)
                .frame(width: 84, alignment: .trailing)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }

    private var sourceBadge: some View {
        Text(app.source.label)
            .font(.system(size: 9, weight: .medium))
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(color.opacity(0.14), in: Capsule())
            .foregroundStyle(color)
    }

    private var color: Color {
        switch app.source {
        case .userInstalled: return .blue
        case .appStore:      return .purple
        case .systemBuiltin: return .gray
        case .other:         return .orange
        }
    }
}
