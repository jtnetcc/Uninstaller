import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: AppViewModel
    @State private var showUndoToast = false

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 214, max: 280)
        } content: {
            AppListView()
                .navigationSplitViewColumnWidth(min: 460, ideal: 560)
        } detail: {
            DetailView()
                .navigationSplitViewColumnWidth(min: 380, ideal: 430)
        }
        .toolbar { toolbarContent }
        .sheet(isPresented: $model.showLogs) {
            LogView()
                .environmentObject(model)
        }
        .sheet(item: $model.pendingRequest) { request in
            UninstallSheet(request: request)
                .environmentObject(model)
        }
        .sheet(item: $model.resultPayload) { payload in
            UninstallResultSheet(payload: payload)
                .environmentObject(model)
        }
        .alert("提示", isPresented: Binding(
            get: { model.alertMessage != nil },
            set: { if !$0 { model.alertMessage = nil } }
        )) {
            Button("好") { model.alertMessage = nil }
        } message: {
            Text(model.alertMessage ?? "")
        }
        .overlay(alignment: .bottom) { undoToast }
    }

    // MARK: 工具条

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button {
                model.refresh()
            } label: {
                Label("刷新", systemImage: "arrow.clockwise")
            }
            .help("重新扫描已安装的应用 (⌘R)")
            .disabled(model.isScanning)
        }

        ToolbarItem(placement: .primaryAction) {
            Picker("排序", selection: $model.sortOption) {
                ForEach(AppSortOption.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 160)
        }

        ToolbarItem(placement: .primaryAction) {
            Toggle(isOn: $model.showProtectedApps) {
                Label("显示系统组件", systemImage: "lock.shield")
            }
            .toggleStyle(.button)
            .help("显示 / 隐藏受系统保护的应用")
        }

        ToolbarItem(placement: .primaryAction) {
            Button {
                model.undoLastUninstall()
            } label: {
                Label("撤销", systemImage: "arrow.uturn.backward")
            }
            .help("把上次卸载的应用从废纸篓恢复 (⇧⌘Z)")
            .disabled(model.lastTrashMap.isEmpty)
        }

        ToolbarItem(placement: .primaryAction) {
            Button {
                model.showLogs = true
            } label: {
                Label("日志", systemImage: "doc.text.magnifyingglass")
            }
            .help("查看操作日志 (⇧⌘L)")
        }
    }

    // MARK: 撤销提示

    @ViewBuilder
    private var undoToast: some View {
        if !model.lastTrashMap.isEmpty {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("卸载完成，\(model.lastTrashMap.count) 项已移入废纸篓")
                    .font(.callout)
                Button("撤销") { model.undoLastUninstall() }
                    .buttonStyle(.link)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.quaternary))
            .shadow(radius: 8, y: 3)
            .padding(.bottom, 18)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}
