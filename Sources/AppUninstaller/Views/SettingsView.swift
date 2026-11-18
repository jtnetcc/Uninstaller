import AppKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var model: AppViewModel

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }

    private var osVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    var body: some View {
        Form {
            Section {
                Toggle("默认移入废纸篓", isOn: $model.useTrash)
                Text("开启后卸载的应用与残留文件进入废纸篓，可撤销；关闭则直接永久删除。需要管理员授权的内容始终直接删除，不会进入废纸篓。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("卸载前退出运行中的实例", isOn: $model.terminateBeforeUninstall)
                Toggle("权限不足时请求管理员授权", isOn: $model.allowPrivilegedRemoval)
                Text("开启后，需要 root 权限的操作会弹出系统验证窗口，输入本机登录密码即可授权。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("允许移除系统内置应用（只读卷）", isOn: $model.allowSystemApps)
                Text("系统内置应用位于只读签名卷（SSV），受 SIP 保护。即使授权 root 通常也无法物理删除，失败后可选择「隐藏」（从启动台与聚焦移除，可恢复）。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("在列表中显示受保护组件", isOn: $model.showProtectedApps)

                HStack {
                    Text("系统完整性保护（SIP）")
                    Spacer()
                    Text(ProtectionPolicy.sipStatus())
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Text("已隐藏的系统应用")
                    Spacer()
                    Button("恢复全部") {
                        let result = SystemAppHider.restoreAllSystemApps()
                        model.logStore.append(result.ok ? .success : .error,
                                              action: "恢复系统应用注册",
                                              target: "/System/Applications",
                                              detail: result.message)
                    }
                    .buttonStyle(.link)
                }
            } header: {
                Text("卸载行为")
            }

            Section {
                HStack {
                    Text("日志目录")
                    Spacer()
                    Text("~/Library/Logs/AppUninstaller/")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    Button("打开") { LogStore.revealLogFolder() }
                        .buttonStyle(.link)
                }
                HStack {
                    Text("扫描缓存")
                    Spacer()
                    Text("~/Library/Caches/com.jt.AppUninstaller/")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    Button("打开") {
                        NSWorkspace.shared.selectFile(nil,
                            inFileViewerRootedAtPath: AppScanner.cacheURL.deletingLastPathComponent().path)
                    }
                    .buttonStyle(.link)
                }
            } header: {
                Text("数据位置")
            }

            Section {
                HStack {
                    Text("版本")
                    Spacer()
                    Text(appVersion).foregroundStyle(.secondary)
                }
                HStack {
                    Text("运行环境")
                    Spacer()
                    Text(osVersion).foregroundStyle(.secondary)
                }
                HStack {
                    Text("最低系统要求")
                    Spacer()
                    Text("macOS 13.0 Ventura").foregroundStyle(.secondary)
                }
            } header: {
                Text("关于")
            }

            Section {
                Text("安全策略：仅允许操作 /Applications 与 ~/Applications 下的第三方应用；bundleID 以 com.apple. 开头的组件、系统只读卷（/System）内的应用、以及符号链接一律拒绝卸载。每次卸载前都会重新校验，避免状态变化导致误删。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("保护机制")
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 520)
    }
}
