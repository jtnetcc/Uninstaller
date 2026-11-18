import SwiftUI

struct SidebarView: View {
    @EnvironmentObject var model: AppViewModel

    private var scopeBinding: Binding<SidebarScope?> {
        Binding(
            get: { model.scope },
            set: { if let newValue = $0 { model.scope = newValue } }
        )
    }

    var body: some View {
        List(selection: scopeBinding) {
            Section("概览") {
                scopeRow(.all)
                scopeRow(.removable)
                scopeRow(.large)
                scopeRow(.protectedApps)
            }

            Section("来源") {
                ForEach(AppSource.allCases) { source in
                    scopeRow(.source(source))
                }
            }

            Section("存储") {
                storageCard
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            footer
        }
    }

    private func scopeRow(_ scope: SidebarScope) -> some View {
        Label {
            HStack(spacing: 6) {
                Text(scope.title)
                Spacer(minLength: 4)
                Text("\(model.count(for: scope))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: scope.symbol)
        }
        .tag(scope)
    }

    private var storageCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("应用总占用")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(model.totalSizeFormatted)
                    .font(.caption.weight(.semibold).monospacedDigit())
            }
            ProgressView(value: totalRatio)
                .tint(.accentColor)
            HStack {
                Text("可回收 \(Fmt.size(model.removableSize))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(.vertical, 4)
    }

    /// 应用占用相对整块启动盘的比例（粗略展示）
    private var totalRatio: Double {
        guard let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeTotalCapacityKey]),
              let capacity = values.volumeTotalCapacity, capacity > 0 else { return 0 }
        return min(1, Double(model.totalSize) / Double(capacity))
    }

    private var footer: some View {
        HStack(spacing: 6) {
            if model.isScanning {
                ProgressView().controlSize(.small)
                Text("正在扫描…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let date = model.lastScanDate {
                Image(systemName: "clock")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(relativeTime(date))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func relativeTime(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return "刚刚扫描" }
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }
}
