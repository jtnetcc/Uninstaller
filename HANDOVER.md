# App Uninstaller · 项目交接文档

> 本文档面向**第一次接手本项目的人**。按顺序读完即可独立完成：环境搭建 → 构建运行 → 改代码 → 排障。
> 不需要原开发者或任何历史对话作为补充。

| 项 | 值 |
|---|---|
| 项目名 | App Uninstaller（macOS 应用管理与卸载工具） |
| 代码位置 | `<工作区>/AppUninstaller` |
| 语言 / UI | Swift 6.4 / SwiftUI + AppKit |
| 构建系统 | Swift Package Manager（tools-version 5.9） |
| 第三方依赖 | **0 个**（仅系统框架） |
| 代码规模 | 18 个 Swift 文件，4008 行 |
| 部署目标 | macOS 13.0 Ventura |
| 当前产物 | `dist/App Uninstaller.app`（3.0 MB，arm64，ad-hoc 签名） |
| 文档版本 | v1.0 · 2026-11-18 |
| 验证环境 | macOS 27.2.1 / Xcode 27.2 / Swift 6.4.2 / arm64 |

---

## 0. 五分钟上手

```bash
cd AppUninstaller

# 1) 构建 + 打包（约 15 秒）
./build.sh

# 2) 无头自测（不碰真实应用，34 项断言）
./.build/release/AppUninstaller --selftest

# 3) 运行
open "dist/App Uninstaller.app"
```

全部通过（`全部通过 (34 项)`）即表示环境正常，可以开始改代码。

> 若 `./build.sh` 报 `sandbox-exec: sandbox_apply: Operation not permitted`，说明终端处于受限环境，脚本已内置 `--disable-sandbox`，一般不会再报；若仍有问题见 §7.1。

---

## 1. 项目概述与目标

### 1.1 解决什么问题

macOS 自带的「移到废纸篓」只删应用包本体，留下大量配置、缓存、容器数据；而系统设置里看不到每个应用的真实磁盘占用。本项目提供一个原生小工具：

1. **看清**：列出全部已安装应用 + 真实占用（allocated size）+ 版本 / 路径 / 架构 / 来源
2. **找得到**：搜索、排序、按来源与体积筛选
3. **删得净**：卸载应用并清理 16 类残留落点
4. **删得稳**：四档权限判定 + 执行前二次校验，避免误删系统组件；危险操作一律确认
5. **可追溯**：全程写操作日志，卸载后可撤销（移入废纸篓路径），清理后自动复检

### 1.2 功能边界（明确不做什么）

| 做 | 不做 |
|---|---|
| 管理 `/Applications`、`~/Applications`、`/Users/Shared/Applications` 下的 `.app` | 不提供「破解/绕过 SIP」，不修改系统卷 |
| 清理用户 `~/Library` 与 `/Library` 下的可清理子目录 | 不清理 `~/Library/Developer`、`~/Library/Mobile Documents` 等用户文档型数据 |
| 对无权限的操作请求管理员授权（系统密码窗） | 不保存、不代填任何密码；不驻留后台、不联网 |
| 对只读系统卷应用提供「隐藏」替代 | 不声称能删除 SSV 上的预装应用（物理不可能，见 §6.9） |

### 1.3 技术选型理由

| 决策 | 理由 |
|---|---|
| Swift + SwiftUI（而非 Electron / Kotlin） | 需要 `NSWorkspace.recycle`（废纸篓语义）、`NSRunningApplication`（退出实例）、LaunchServices、Authorization 等系统能力；包体 3 MB，启动瞬时 |
| SwiftPM 而非 Xcode 工程 | 无 `.xcodeproj` 二进制冲突，命令行可完整构建；`build.sh` 负责组装 `.app` |
| 不使用 App Sandbox | 需遍历 `/Applications` 与用户 `~/Library`；沙盒下无法完成核心功能 |
| AppleScript 提权而非特权 Helper | 无需 Developer ID 与 `SMJobBless` 签名链，ad-hoc 签名即可用；代价见 §7.4 |
| 自研扫描而非 `system_profiler` | `system_profiler SPApplicationsDataType` 耗时数秒到数十秒且拿不到精确占用；自行遍历 + 并发统计更快更准 |

### 1.4 当前状态

| 维度 | 状态 |
|---|---|
| 核心功能 | 完成并实测（本机 85 个应用 / 15.45 GB 扫描正常） |
| 自动化测试 | `--selftest` 34 项；加 `--privileged` 42 项（含真实 root 提权删除验证） |
| 签名 | ad-hoc（本机可用，跨机分发需自行签名/公证，见 §5.3） |
| 架构 | arm64 only（Universal 构建方法见 §4.4） |
| 版本控制 | **尚未初始化 git**，见 §8.6 |

---

## 2. 整体架构与目录结构

### 2.1 分层架构

```
┌─────────────────────────────────────────────────────────────┐
│  Views（SwiftUI）                                            │
│  ContentView ─ Sidebar / AppList / Detail                    │
│              └ UninstallSheet / UninstallResultSheet / Log   │
└───────────────────────────┬─────────────────────────────────┘
                            │ @EnvironmentObject
┌───────────────────────────▼─────────────────────────────────┐
│  AppViewModel（@MainActor ObservableObject）                 │
│  列表状态 · 筛选排序 · 选中项 · 残留清单 · 卸载编排 · 结果面板  │
└───────────────────────────┬─────────────────────────────────┘
                            │ 直接调用（async）
┌───────────────────────────▼─────────────────────────────────┐
│  Services（纯逻辑，无 UI 依赖）                                │
│  AppScanner     扫描 / 体积 / 元数据 / 缓存                   │
│  ProtectionPolicy  四档判定 / SIP 探测 / 残留白名单            │
│  ResidualScanner   16 类落点匹配                              │
│  Uninstaller       卸载编排 / 复检 / 撤销                      │
│  PrivilegedExecutor root 授权执行 / 系统应用隐藏               │
│  LogStore          内存环形 + JSONL 落盘                      │
│  SelfTest          无头自测                                   │
└───────────────────────────┬─────────────────────────────────┘
                            │
┌───────────────────────────▼─────────────────────────────────┐
│  Models（值类型，全部 Codable/Hashable）                       │
│  InstalledApp · RemovalScope · ResidualItem · RiskLevel       │
│  LogEntry · VerificationReport · UninstallRequest/Outcome     │
└─────────────────────────────────────────────────────────────┘
```

设计约定：**Services 不 import SwiftUI**，只依赖 Foundation / AppKit，因此可被自测直接调用；所有文件操作在后台 Task 中执行，UI 状态只在 `@MainActor` 上变更。

### 2.2 目录树

```
AppUninstaller/
├── Package.swift                  # SwiftPM 清单：可执行 target，macOS 13+
├── build.sh                       # 构建 + 组装 .app + ad-hoc 签名
├── README.md                      # 面向使用者/开发者的功能与策略说明
├── HANDOVER.md                    # 本文档（面向接手人）
├── Resources/
│   ├── Info.plist                 # bundle 元信息（ID / 版本 / 最低系统）
│   └── AppIcon.icns               # 由 Tools/make_icon.swift 生成
├── Tools/
│   └── make_icon.swift            # 图标生成脚本（CoreGraphics 绘制 1024² PNG）
├── docs/
│   ├── screenshot.png             # 主界面
│   ├── system-app.png             # 系统内置应用详情
│   └── result-panel.png           # 清理结果面板
├── scripts/
│   └── verify.sh                  # 一键验收：构建 → 自测 → 打包 → 产物校验
├── .gitignore
├── dist/                          # 构建产物（不入版本库）
└── Sources/AppUninstaller/
    ├── AppMain.swift              # @main / 菜单命令 / AppDelegate / --selftest 入口
    ├── Models/
    │   └── Models.swift           # 全部值类型 + RemovalScope + 格式化工具
    ├── Services/
    │   ├── AppScanner.swift       # 枚举 .app、解析 Info.plist、并发算体积、图标、缓存
    │   ├── ProtectionPolicy.swift # 四档判定、SIP/只读卷探测、残留路径白名单
    │   ├── ResidualScanner.swift  # 16 类落点 + 厂商目录匹配 + 风险分级
    │   ├── Uninstaller.swift      # 主流程（阶段 A/B/C）、verify、undo
    │   ├── PrivilegedExecutor.swift # AppleScript 提权批量删除 + SystemAppHider
    │   ├── LogStore.swift         # 线程安全日志（主线程更新 + 串行队列落盘）
    │   └── SelfTest.swift         # 无头自测（含 --privileged 提权测试）
    ├── ViewModels/
    │   └── AppViewModel.swift     # 唯一状态源：列表/筛选/选中/卸载/结果
    └── Views/
        ├── ContentView.swift      # NavigationSplitView 三栏 + 工具条 + sheet 挂载
        ├── SidebarView.swift      # 分类筛选 + 存储概览
        ├── AppListView.swift      # 列表行、右键菜单、状态栏、搜索
        ├── DetailView.swift       # 详情：概览卡、提示横幅、关联数据、操作栏
        ├── UninstallSheet.swift   # 卸载确认（残留勾选 + 选项 + 风险提示）
        ├── UninstallResultSheet.swift # 清理结果（统计卡 + 残留 + 重试/隐藏）
        ├── LogView.swift          # 日志查看（按级别筛选）
        └── SettingsView.swift     # 偏好设置 + SIP 状态 + 恢复系统应用
```

### 2.3 模块职责速查

| 文件 | 行数 | 关键类型/函数 | 改动风险 |
|---|---|---|---|
| `Models/Models.swift` | 348 | `InstalledApp`、`RemovalScope`、`ResidualItem`、`VerificationReport` | 中：新增字段需同步缓存版本 |
| `Services/AppScanner.swift` | 265 | `scan(progress:)`、`discoverBundles()`、`directorySize(_:)`、`makeApp(url:size:)` | 中：递归深度与 skip 逻辑影响性能 |
| `Services/ProtectionPolicy.swift` | 216 | `evaluate(path:bundleID:name:)`、`isForbiddenResidualPath(_:)` | **高：安全边界** |
| `Services/ResidualScanner.swift` | 147 | `scan(app:)`、`vendorPair(from:)`、`glob(_:)` | 高：误匹配会导致误删 |
| `Services/Uninstaller.swift` | 406 | `perform(_:log:)`、`verify(app:residuals:log:)`、`undo(trashMap:log:)` | **高：主流程** |
| `Services/PrivilegedExecutor.swift` | 184 | `removePaths(_:log:)`、`SystemAppHider.hide(_:)` | **高：root 执行 + 字符串拼接** |
| `Services/LogStore.swift` | 93 | `append(_:action:target:detail:)` | 低 |
| `Services/SelfTest.swift` | 272 | `run()` | 低（但新增功能应补断言） |
| `ViewModels/AppViewModel.swift` | 391 | `refresh()`、`prepareUninstall(for:)`、`confirmUninstall()`、`retryPrivilegedRemoval()` | 中 |
| `Views/*` | 1466 | — | 低 |

### 2.4 两条核心数据流

**扫描流**

```
bootstrap() 读缓存(instantly) → refresh()
  └ Task.detached: AppScanner.scan
      ├ discoverBundles()        遍历 3 个根目录，遇 .app 即 skipDescendants，深度≤3
      ├ concurrentPerform        每个 bundle 并发 directorySize（allocated size 累加）
      ├ makeApp(url:size:)       读 Contents/Info.plist，判来源，调 ProtectionPolicy.evaluate
      └ 返回后主线程: apps = [...]; saveCache(); 自动选中第一项
```

**卸载流**

```
prepareUninstall(for:) → 扫描残留 → pendingRequest → UninstallSheet 确认
  └ confirmUninstall() → Uninstaller.perform
      ├ 阶段1 二次校验（forbidden / 自身 / 系统卷开关）
      ├ 阶段2 退出运行实例（terminate → 3s 超时 → forceTerminate）
      ├ 阶段3 移除本体（普通权限；失败按权限错误升级）
      ├ 阶段4 系统卷特判（先删本体，失败即中止，避免"应用还在但配置没了"）
      ├ 阶段5 残留：普通项就地处理，需 root 的合并为一次授权批量执行
      ├ 阶段6 verify() 重新 stat 每个路径 → VerificationReport
      └ 返回 UninstallOutcome → 弹出 UninstallResultSheet
```

### 2.5 状态管理

`AppViewModel` 是唯一状态源，所有 UI 通过 `@EnvironmentObject` 读取。要点：

- `@Published var apps` 只由 `refresh()` 写入；卸载成功后用 `removeAll` 局部更新，避免整表重扫
- `selection: String?` 存 `InstalledApp.id`（即路径）；`refresh` 结束后若选中项已不存在会自动落到第一项
- 偏好项用 `@Published + didSet + Prefs.set`（不直接用 `@AppStorage`，以便 `$model.xxx` 可直接绑定）
- `allowPrivilegedRemoval` / `allowSystemApps` 持久化；**危险选项不做持久化**（历史上出现过被写脏的问题）

---

## 3. 环境配置与依赖安装

### 3.1 硬性要求

| 项 | 要求 | 检查命令 | 不满足的后果 |
|---|---|---|---|
| macOS | ≥ 13.0（构建机建议 14+） | `sw_vers` | 无法运行 / 无法用新 SDK 构建 |
| Xcode | ≥ 15（本项目在 27.2 验证） | `xcodebuild -version` | 缺 AppKit/SwiftUI 链接能力 |
| Swift | ≥ 5.9（本项目在 6.4.2 验证） | `swift --version` | 编译失败 |
| 磁盘 | ≥ 500 MB 可用（.build 中间产物） | `df -h .` | 构建中断 |
| 网络 | 不需要（零依赖） | — | — |

> Xcode 只用于提供 SDK 与工具链，**不需要**打开 Xcode GUI，也不需要 `.xcodeproj`。

### 3.2 从零配置步骤

**Step 1 · 确认工具链**

```bash
xcode-select -p     # 期望 /Applications/Xcode.app/Contents/Developer
swift --version     # 期望 Apple Swift version 5.9 及以上
```

若 `xcode-select -p` 指向 CommandLineTools 而构建报找不到 SwiftUI，执行：

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

**Step 2 · 放置项目**

项目是纯文本目录，直接拷贝即可（不要拷 `.build/` 与 `dist/`）：

```bash
# 示例：放到用户工作目录
cp -R AppUninstaller ~/Projects/AppUninstaller
cd ~/Projects/AppUninstaller
```

**Step 3 · 首次构建**

```bash
swift build --disable-sandbox -c release
```

期望输出末尾 `Build complete!`。首次约 30~60 秒（编译 SwiftUI 模块缓存）。

**Step 4 · 自测**

```bash
./.build/release/AppUninstaller --selftest
```

期望结尾：`全部通过 (34 项)`，退出码 0。

**Step 5 · 打包并运行**

```bash
./build.sh
open "dist/App Uninstaller.app"
```

**Step 6 · 授予必要权限（首次使用会触发）**

| 场景 | 系统弹窗 | 打开路径 |
|---|---|---|
| 卸载 `/Applications` 下其他 App | 「App Uninstaller 想要修改其他 App」 | 系统设置 › 隐私与安全性 › App 管理 |
| 访问某些受保护目录 | 「想要访问…文件夹」 | 系统设置 › 隐私与安全性 › 完全磁盘访问权限（可选） |
| 任何需要 root 的删除 | 系统验证窗口（输入登录密码） | 无需预先设置 |

### 3.3 依赖说明

**无第三方库**，仅链接系统框架：

| 框架 | 用途 |
|---|---|
| SwiftUI | 全部界面 |
| AppKit | `NSWorkspace`（废纸篓回收、图标、打开应用）、`NSRunningApplication`、`NSImage` |
| Foundation | 文件遍历、PropertyList、Process、JSON |
| Security（间接） | 由 AppleScript 的 `with administrator privileges` 内部使用，无直接调用 |

因此**没有 `Package.resolved`、不需要 `swift package resolve`、无版本冲突**。

### 3.4 受限终端 / 沙盒环境

`swift build` 默认用 `sandbox-exec` 隔离 manifest 解析，在部分受管终端会失败：

```
sandbox-exec: sandbox_apply: Operation not permitted
```

处理：所有构建命令加 `--disable-sandbox`（`build.sh` 已内置）。

---

## 4. 账号与模型切换后的配置说明

### 4.1 先说结论：本项目没有账号体系

| 可能被误认为"账号"的东西 | 实际情况 |
|---|---|
| 应用内登录 / 云同步 | **不存在**。全本地运行，不发起任何网络请求 |
| API Key / Token | **不存在**。无 LLM、无第三方服务调用 |
| 数据库 / 远程配置 | **不存在**。唯一持久化是 `UserDefaults` + 两个本地目录 |
| 开发者证书 | 仅 **ad-hoc 签名**，无 Apple Developer 账号依赖 |

所以"更换账号和模型"对本项目运行时**零影响**。需要处理的只是下面四类环境变化。

### 4.2 更换 macOS 用户账号（换人 / 换机）

路径、权限、偏好都跟着用户名走。逐项对照：

| 资源 | 旧位置（示例 jt） | 新账号下 | 处理 |
|---|---|---|---|
| 源码 | `/Users/jt/.../AppUninstaller` | `/Users/<new>/...` | 直接拷贝；**不要**保留旧绝对路径的脚本别名 |
| 构建产物 | `.build/`、`dist/` | 重新生成 | 拷贝后先 `./build.sh --clean` |
| 应用偏好 | `~/Library/Preferences/com.jt.AppUninstaller.plist` | 新用户无此文件 | 无需迁移，首次启动用默认值 |
| 扫描缓存 | `~/Library/Caches/com.jt.AppUninstaller/inventory-v2.json` | 新用户无 | 自动重建；路径含旧用户名不会串（以 `NSHomeDirectory()` 计算） |
| 操作日志 | `~/Library/Logs/AppUninstaller/*.log` | 新用户无 | 如需审计历史，手动拷贝该目录 |
| TCC 授权（App 管理 / 完全磁盘） | 绑定旧 app 签名 + 用户 | 需重新授权 | 首次卸载时按提示操作 |

**关键点**：代码中所有用户相关路径均通过 `FileManager.default.homeDirectoryForCurrentUser` / `NSHomeDirectory()` 计算，**没有硬编码 `/Users/jt`**，因此换账号无需改代码。可用以下命令确认：

```bash
grep -rn "/Users/" Sources Tools build.sh 2>/dev/null | grep -v "Users/Shared" || echo "无硬编码用户路径"
```

### 4.3 更换开发者身份 / bundle 标识（团队化改造）

当前标识 `com.jt.AppUninstaller` 含个人缩写。正式交付团队时建议改为 `com.<团队>.AppUninstaller`，需同步修改 **5 处**：

| # | 文件 | 位置 | 说明 |
|---|---|---|---|
| 1 | `Resources/Info.plist` | `CFBundleIdentifier` | 主标识 |
| 2 | `build.sh` | `codesign --identifier` | 签名标识，必须与 Info.plist 一致 |
| 3 | `Services/AppScanner.swift` | `cacheURL` 中的 `com.jt.AppUninstaller` | 缓存目录名 |
| 4 | `Services/LogStore.swift` | `DispatchQueue(label:)` | 队列标签（非必须，但保持一致） |
| 5 | `Views/SettingsView.swift` | 设置页展示的缓存路径文案 | 仅文案 |

改完后：

```bash
./build.sh --clean
defaults delete com.jt.AppUninstaller 2>/dev/null   # 清理旧偏好（可选）
```

⚠️ 改 bundleID 后，系统会视为**新应用**：TCC「App 管理」授权需重新授予，旧日志/缓存目录不会自动迁移。

### 4.4 更换机器架构（Intel Mac / 分发 Universal）

**现状**：`build.sh` 产出 **arm64 only**。

```
$ file "dist/App Uninstaller.app/Contents/MacOS/AppUninstaller"
Mach-O 64-bit executable arm64
```

在 Apple Silicon 上通过 Rosetta 无法运行 arm64-only 于 Intel 机器 —— Intel Mac 上会直接报「无法打开」。

**Universal 构建（已实测可行）**：

```bash
swift build --disable-sandbox -c release --arch arm64 --arch x86_64
# 产物位置（注意不是 .build/release/）：
file .build/out/Products/Release/AppUninstaller
# → Mach-O universal binary with 2 architectures: x86_64 ... arm64
```

打包时把 `build.sh` 里的 `BIN` 指向该路径即可：

```bash
# build.sh 中替换为：
BIN="$ROOT/.build/out/Products/Release/AppUninstaller"
```

构建时会出现警告 `The x86_64 architecture is deprecated for your deployment target (macOS 27.2)`，属正常提示（新 SDK 不再鼓励 x86_64），不影响产物。

### 4.5 更换 AI 模型 / 助手协作

本仓库**不含任何模型配置**（无 `.env`、无 API 地址、无 prompt 文件）。切换模型只影响"你用什么工具改代码"，不影响项目本身。

为了让任意模型快速接手，建议在会话开始时投喂以下三份文件：

1. `HANDOVER.md`（本文档，含边界与红线）
2. `README.md`（功能语义与策略说明）
3. `Sources/AppUninstaller/Services/Uninstaller.swift`（主流程，改动最频繁）

可直接复制的提示词模板：

```text
你在维护一个 macOS 原生卸载工具（Swift 6 / SwiftUI / SwiftPM，零第三方依赖）。
请先读 HANDOVER.md 与 README.md，遵守 §8.1 的安全红线：
1) 不得放宽 ProtectionPolicy 的 forbidden 判定或残留白名单；
2) 不得把用户路径/拼接进 shell 前跳过校验与转义；
3) 改动卸载主流程必须补 --selftest 断言并全部通过；
4) /System 为只读签名卷，不要尝试"绕过 SIP"式的实现。
改动请给出：根因 → 证据 → 修改点 → 验证命令。
```

### 4.6 迁移检查清单（换机后逐条打勾）

- [ ] `xcode-select -p` 指向完整 Xcode
- [ ] `swift build --disable-sandbox -c release` 成功
- [ ] `./.build/release/AppUninstaller --selftest` → `全部通过 (34 项)`
- [ ] `./build.sh` 生成 `dist/App Uninstaller.app`
- [ ] 启动后能列出应用，占用数字与 Finder「显示简介」量级一致
- [ ] 选中一个系统内置应用，详情显示「只读卷」且按钮为「移除…」
- [ ] 选中一个用户安装应用，能弹出确认面板并完成一次真实卸载（建议自建测试 App）
- [ ] 日志目录出现当天 `.log` 且内容为合法 JSONL
- [ ] 需要 root 的操作能弹出系统验证窗口

---

## 5. 运行与部署

### 5.1 本地运行（三种方式）

| 方式 | 命令 | 适用场景 |
|---|---|---|
| 打包后运行 | `./build.sh && open "dist/App Uninstaller.app"` | 验收、日常使用 |
| 直接跑二进制 | `./.build/release/AppUninstaller` | 快速验证，注意此时无 Info.plist 上下文 |
| 无头自测 | `./.build/release/AppUninstaller --selftest [--privileged]` | CI / 回归 |

> 直接跑二进制时 `Bundle.main.bundleIdentifier` 为 nil，「不能卸载自身」这条保护会失效——**仅用于调试**，不要用它做真实卸载测试。

### 5.2 打包流程（build.sh 做了什么）

```
1. swift build --disable-sandbox -c release
2. 定位可执行文件（.build/release/AppUninstaller，找不到则 find 兜底）
3. 组装 App Uninstaller.app/Contents/{MacOS,Resources}
4. 拷贝 Info.plist、AppIcon.icns，写 PkgInfo
5. codesign --force --sign - --identifier com.jt.AppUninstaller
6. 输出体积
```

手工等价步骤（便于排查打包问题）：

```bash
APP="dist/App Uninstaller.app"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/AppUninstaller "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
printf 'APPL????' > "$APP/Contents/PkgInfo"
codesign --force --sign - --identifier com.jt.AppUninstaller "$APP"
```

### 5.3 分发与签名

| 场景 | 做法 |
|---|---|
| 仅本机使用 | 现状即可（ad-hoc） |
| 同团队几台机器 | 拷贝 `.app` 后，接收方执行 `xattr -dr com.apple.quarantine "App Uninstaller.app"` 解除隔离标记 |
| 正式分发（推荐） | 用 Developer ID 签名 + 公证 |

```bash
# 1) 签名（替换为实际证书名，security find-identity -v -p codesigning 可查）
codesign --force --deep --options runtime \
  --sign "Developer ID Application: Your Team (TEAMID)" \
  --identifier com.jt.AppUninstaller "dist/App Uninstaller.app"

# 2) 打包为 dmg（可选）
hdiutil create -volname "App Uninstaller" -srcfolder "dist/App Uninstaller.app" \
  -ov -format UDZO "dist/AppUninstaller.dmg"

# 3) 公证并装订
xcrun notarytool submit "dist/AppUninstaller.dmg" \
  --apple-id "you@example.com" --team-id TEAMID --password "app-specific-password" --wait
xcrun stapler staple "dist/AppUninstaller.dmg"
```

### 5.4 安装到 /Applications 的注意点

- 把 `.app` 拖入 `/Applications` 后，**工具会把自己也列进列表**；「不能卸载自身」由 `bundleID == Bundle.main.bundleIdentifier` 拦截
- 若放在 `/Applications` 且属主为 root，后续升级替换时需要管理员权限
- 升级 = 覆盖 `.app`；`UserDefaults`、日志、缓存不受影响

### 5.5 CI 建议

本项目无外部依赖，CI 极简（以 GitHub Actions 为例）：

```yaml
name: build-and-test
on: [push, pull_request]
jobs:
  macos:
    runs-on: macos-15
    steps:
      - uses: actions/checkout@v4
      - name: Build
        run: swift build --disable-sandbox -c release
      - name: Self test
        run: ./.build/release/AppUninstaller --selftest
      - name: Package
        run: ./build.sh
```

注意：CI 上**不要**跑 `--privileged`（会弹系统密码窗，必然失败）。

---

## 6. 关键功能与核心逻辑

### 6.1 应用扫描与体积统计

**入口**：`AppScanner.scan(progress:)`

| 环节 | 实现要点 | 为什么这么做 |
|---|---|---|
| 根目录 | `/Applications`、`~/Applications`、`/System/Applications` | 覆盖用户安装、系统预装；`/Applications/Utilities` 会被递归带到 |
| 枚举 | `FileManager.enumerator`，深度 ≤ 3，遇 `.app` 立即 `skipDescendants()` | 防止把 `X.app/Contents/Library/LoginItems/H.app` 当成独立应用 |
| 体积 | `totalFileAllocatedSize` 逐文件累加 + `concurrentPerform` 并发 | 与 Finder 显示同量级；比 `du -sk` 更贴近"实际占用"，且不 fork 进程 |
| 并发安全 | 结果数组按下标写 + `NSLock` 保护计数器 | 不同元素写入虽安全但没有语言保证，加锁成本可忽略 |
| 来源判定 | `/System/` → 系统内置；`_MASReceipt/receipt` 存在 → App Store；托管根 → 用户安装；其余 → 其他 | 单一判据不可靠，按优先级排列 |
| 元数据 | `Contents/Info.plist` 直接 `PropertyListSerialization` 解析 | 不实例化 `Bundle`，避免加载代码/资源 |
| 架构 | `Bundle(url:).executableArchitectures` 映射 cputype | 比 `lipo -archs` 快，无子进程 |
| 缓存 | `~/Library/Caches/com.jt.AppUninstaller/inventory-v2.json` | 启动秒开；扫描完成后覆盖 |

**性能基准**（本机 85 个应用 / 15.45 GB）：冷启动全量扫描约 4~8 秒，热缓存首屏 < 0.3 秒。

### 6.2 四档移除判定（`RemovalScope`）

**入口**：`ProtectionPolicy.evaluate(path:bundleID:name:) -> ProtectionDecision`

判定顺序（**顺序即优先级，改动需谨慎**）：

| # | 规则 | 结果 |
|---|---|---|
| 1 | 符号链接（`resolvingSymlinksInPath` 后路径变化） | `forbidden` |
| 2 | 后缀不是 `.app` | `forbidden` |
| 3 | bundleID ∈ 19 条关键组件名单（Finder/Dock/SystemSettings/WindowManager/Spotlight/SecurityAgent…） | `forbidden` |
| 4 | 路径前缀命中 `/usr`、`/bin`、`/sbin`、`/private`、`/System/Library`、`/Library/Apple` 等 | `forbidden` |
| 5 | 位于 `/System/Applications/` | `systemVolume` |
| 6 | 位于 `/System/` 其他位置 | `forbidden` |
| 7 | 不在 `/Applications`、`/Users/Shared/Applications`、`~/Applications` 之下 | `forbidden` |
| 8 | 包内 `Contents` 不可写（属主 root） | `adminRequired` |
| 9 | 其余 | `userManaged` |

`requiresAdminPrivileges` 的判据是**包内 `Contents` 是否可写**，而不是看父目录：

- `/Applications` 对 admin 组可写，所以「能删掉目录项」≠「能删掉包内文件」
- 只有 `rm -rf` 能递归删除时才算真正可删

**这条判定在同一流程里被调用两次**：扫描时（决定 UI 展示与按钮状态）、`perform` 开头（防止扫描后状态被篡改）。

### 6.3 残留匹配（`ResidualScanner.scan(app:)`）

**16 类落点**：`Application Support`、`Caches`、`Preferences`、`Preferences/ByHost`、`Logs`、`Saved Application State`、`Containers`、`Group Containers`、`HTTPStorages`、`WebKit`、`Cookies`、`Application Scripts`、`LaunchAgents`、`LaunchDaemons`、`Receipts`、系统级 `/Library/*`。

三种匹配策略：

| 策略 | 例子 | 风险标注 |
|---|---|---|
| 精确 bundleID | `~/Library/Caches/com.google.Chrome` | `safe` |
| 应用名兜底 | `~/Library/Application Support/Google Chrome` | `caution` |
| 厂商目录 | `com.google.Chrome` → `Application Support/Google/Chrome`（大小写不敏感） | `caution` |
| 通配 | `Preferences/ByHost/<bid>.*.plist`、`Group Containers/*.<bid>` | `safe` / `risky` |

过滤链（任一不满足即丢弃）：去重 → 必须存在 → 不得落在应用包内 → 不得命中 `isForbiddenResidualPath` → 计算体积。

风险分级决定默认勾选：`safe`/`caution` 勾选，`risky`（Group Containers、LaunchDaemon）**默认不勾**。

### 6.4 卸载编排（`Uninstaller.perform`）

| 阶段 | 行为 | 失败处理 |
|---|---|---|
| 1 | 二次校验（forbidden / 自身 / 系统卷开关） | 直接返回并记录原因 |
| 2 | 退出运行实例：`terminate()` → 3 秒轮询 → `forceTerminate()` | 记录「强制退出」警告，继续 |
| 3 | 移除本体：`userManaged` 走 `NSWorkspace.recycle`（可撤销）或 `removeItem` | 权限类错误 → 标记待提权；其他错误 → 终止并复检 |
| 4 | 系统卷特判：先单独提权删本体 | 失败则**中止**，不清理残留（避免"应用还在、配置没了"） |
| 5 | 残留：普通项就地处理；`requiresAdmin` 或权限失败项**收集后一次授权批量删除** | 用户取消 → 标记 `authorizationCancelled`，已完成的普通删除不回滚 |
| 6 | `verify()` 重新 stat 所有路径 | 结果进 `UninstallResultSheet` |

**约定**：一次卸载最多弹 **一次** 密码框（阶段 3/5 的 root 操作合并）；root 删除不进废纸篓、不可撤销，确认面板必须提前告知。

### 6.5 管理员提权（`PrivilegedExecutor`）

为什么不用 `AuthorizationExecuteWithPrivileges`：该 API 已被 Swift 标记 `unavailable`（macOS 10.9 起废弃，Swift 中直接编译失败）。改用：

```applescript
do shell script "<shell 脚本>" with administrator privileges
```

| 环节 | 实现 |
|---|---|
| 触发窗口 | SecurityAgent 弹出标准验证窗口，标题为「App Uninstaller」，要求输入本机登录密码 |
| 批量执行 | 一次授权跑一个 `for p in 'a' 'b'; do ... rm -rf ...; done` 循环，逐路径回 `OK` / `GONE` / `FAIL` |
| 路径校验 | 绝对路径；不含 `\n`、`\r`；必须通过「托管根目录」或「残留白名单」二选一 |
| 转义 | 两层：先 POSIX 单引号转义（`'` → `'\''`），再做 AppleScript 双引号转义（`\` → `\\`，`"` → `\"`） |
| 取消识别 | 错误码 `-128` → 视为用户取消，不做任何修改 |
| 首次降级 | 进程刚启动时首次授权可能被系统降级为普通权限（表现为 `Permission denied` / 错误码 13）→ **仅此错误**自动重试一次 |

⚠️ **改这个文件前必读**：脚本拼接是唯一能造成"误删任意路径"的地方。任何新增路径来源都必须先过 `isForbiddenResidualPath` 与其托管根目录判断。

### 6.6 清理后复检（`Uninstaller.verify`）

语义：**不复用执行阶段的返回值，重新问文件系统一次**。

```swift
appStillExists  = FileManager.exists(app.path)
clearedPaths    = residuals 中已不存在的路径
remaining       = 仍存在的路径 + 重算体积 + 原因（只读卷 / 需管理员 / 被占用）
blockedBySystemVolume = appStillExists && path.hasPrefix("/System/")
```

`isFullyCleared = !appStillExists && remaining.isEmpty`。

结果面板按三种状态呈现：彻底清除（绿）／仍有残留（黄）／系统卷阻止（橙）。「以管理员权限重试」只对 `remaining` 生效，「重新检测」不执行任何删除。

### 6.7 撤销

只对**普通权限 + 移入废纸篓**的路径有效（`outcome.trashMap: 原路径 → 废纸篓新路径`）。执行 `undo` 时逐条把废纸篓中的项目 `moveItem` 回原位（必要时重建父目录）。root 删除的路径不在 map 中，因此不可撤销——这是设计取舍，不是缺陷。

### 6.8 日志与审计

| 项 | 说明 |
|---|---|
| 文件 | `~/Library/Logs/AppUninstaller/uninstall-YYYY-MM-DD.log` |
| 格式 | 每行一个 JSON 对象（JSONL），字段：`id/date/level/action/target/detail` |
| 级别 | `info` `success` `warning` `error` `destructive` |
| 写入 | 主线程更新内存（上限 500 条）+ 串行队列追加落盘；可从任意线程调用 |
| 读取 | 启动时加载当日最后 300 条；界面按级别筛选 |
| 内容 | 扫描汇总、每次卸载的每个路径、授权请求/取消/失败、复检结果、撤销 |

解析示例：

```bash
tail -5 ~/Library/Logs/AppUninstaller/uninstall-$(date +%F).log | jq -r '"\(.action) | \(.target) | \(.detail // "")"'
```

### 6.9 系统内置应用与「隐藏」

**事实**（实测，勿凭猜测推翻）：

```
$ mount | grep ' on / '
/dev/disk3s3s1 on / (apfs, sealed, local, read-only, journaled)
$ csrutil status
System Integrity Protection status: enabled.
```

`/System/Applications` 在只读签名卷上，**root 也无法删除**。因此：

1. 允许发起 root 删除尝试（若使用方关闭 SIP 且挂载可写，则会真的成功）
2. 失败时给准确原因，并提供 `SystemAppHider.hide(path:)` → `lsregister -u <path>`，从启动台/聚焦移除（可逆）
3. 设置页「恢复全部系统应用注册」→ `lsregister -f -R -trusted /System/Applications`

`/Applications` 下的 Apple 应用（Xcode、iWork、Final Cut…）属 `adminRequired`，可以正常卸载。

### 6.10 自测框架

```bash
./.build/release/AppUninstaller --selftest              # 34 项
./.build/release/AppUninstaller --selftest --privileged  # 42 项（含真实 root 删除）
```

| 分组 | 覆盖 |
|---|---|
| 判定 | 四档各一例 + 残留白名单正反例 + lsregister 存在性 |
| 构造 | 在 `~/Applications/AU SelfTest.app` 建假包（3 MB payload） |
| 解析 | 名称 / bundleID / 版本 / removalScope |
| 残留 | 4 类落点全命中（含厂商目录） |
| 卸载 | 本体移除、缓存与支持目录清理、trashMap 生成 |
| 复检 | `isFullyCleared`、0 残留、计数一致 |
| 撤销 | 恢复 5 项、复检转为"仍存在" |
| 系统卷 | 对 `Music.app` 复检应报 `blockedBySystemVolume` |
| 提权（`--privileged`） | 身份探测为 root、创建 `/Library/Application Support/AUPrivTest-*`、提权删除返回 `OK`、复检消失 |

测试数据在结束时全部清理，不会残留真实系统文件。

---

## 7. 常见问题与故障排查

### 7.1 构建类

| 症状 | 根因 | 处理 |
|---|---|---|
| `sandbox-exec: sandbox_apply: Operation not permitted` | 终端受限，SwiftPM 自身沙盒不可用 | 加 `--disable-sandbox`（`build.sh` 已内置） |
| CI 报 `The configuration 'macos-14-arm64-us-default' is not supported`，job 在 0s 被 cancelled、`runner_name` 为空 | GitHub 已退役该版本的托管 runner 镜像（macOS 14 于 2026-11-02 退役） | 把 `runs-on` 升到仍受支持的镜像（当前 `macos-15` / `macos-15-intel`），见 §8.7 |
| `error: unable to find utility "swift-frontend"` | `xcode-select` 指向 CommandLineTools | `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer` |
| `cannot convert value of type '[AnyHashable : Bool]'`（改代码后） | `FileManager.enumerator(options:)` 传了字典 | 传 `[]` 或 `[.skipsHiddenFiles]` |
| `'AuthorizationExecuteWithPrivileges' is unavailable` | 该 API 在 Swift 中已禁用 | 用现有的 `PrivilegedExecutor`（AppleScript 路径），勿再用该 API |
| 构建极慢 / 重复编译 | 改动了 `Package.swift` 或切换 debug/release | 正常现象；`./build.sh --clean` 可重置 |
| 打包出来的 app 架构不对 | 先跑过 universal 构建，`build.sh` 取到 `.build/release/` 下的旧单架构产物 | `./build.sh --clean` 重新构建 |

### 7.2 运行类

| 症状 | 根因 | 处理 |
|---|---|---|
| 双击无反应 / 一闪而过 | 签名失效或 bundle 不完整 | 终端运行 `dist/App Uninstaller.app/Contents/MacOS/AppUninstaller` 看报错 |
| 「App 已损坏，无法打开」 | 跨机拷贝带上 quarantine | `xattr -dr com.apple.quarantine "App Uninstaller.app"` |
| 列表为空 | 首次扫描未完成或根目录不可读 | 等待进度条；确认 `ls /Applications` 可读；查看日志"扫描完成"条数 |
| 体积明显偏小 | APFS 压缩/克隆，allocated size 小于逻辑大小 | 预期行为，非 bug |
| 出现重复条目 | 同一 bundle 存在于多个根目录（如 `/Applications` 与 `~/Applications` 各一份） | 预期行为（按路径去重，不按 bundleID 去重） |
| 详情面板空白 | 选中项在刷新后不存在了 | 重新点选；`refresh` 会自动落到第一项 |

### 7.3 卸载类

| 症状 | 根因 | 处理 |
|---|---|---|
| 提示「没有权限修改该应用」 | macOS 13+ 的 App Management TCC 未授权 | 系统设置 › 隐私与安全性 › App 管理 → 勾选本工具 |
| 授权窗口不出现，直接失败 | 进程刚启动首次授权被降级 | 已有自动重试；仍失败则手动再点一次 |
| 授权后仍失败（`Operation not permitted`） | 目标是 SIP 保护路径 | 属 `forbidden`/`systemVolume` 范畴，按其提示处理（隐藏 or 放弃） |
| 卸载按钮灰色 | `removalScope == .forbidden` | 查看详情页橙色横幅中的具体原因 |
| 系统内置应用提示「无法物理删除」 | 只读签名卷，非权限问题 | 用「隐藏」，见 §6.9 |
| 残留有 `Group Containers` 未被清理 | 默认 `risky` 未勾选 | 手动在确认面板勾选（可能影响其他 App，谨慎） |
| 撤销无效 | 该路径是 root 删除，未进废纸篓 | 设计如此；root 删除不可撤销 |
| 删除后应用仍出现在启动台 | LaunchServices 缓存 | 执行一次「隐藏」或重启 Finder；也可 `killall Dock` |

### 7.4 提权相关深入排查

提权失败时，**先判断是"没拿到 root"还是"拿到了但 OS 拒绝"**：

```bash
# 1) 手动验证 AppleScript 提权是否可用（会弹密码框）
osascript -e 'do shell script "id -u" with administrator privileges'
# 期望输出 0；若输出 501 说明未提权

# 2) 若拿到 0 但仍删不掉，判断卷是否只读
mount | grep ' on / '
csrutil status

# 3) 判断目标属主/权限
ls -lde "/Applications/Some.app" "/Applications/Some.app/Contents"
```

结论对照：

| 观察 | 结论 |
|---|---|
| `id -u` 返回 501 | 授权未生效 → 检查是否有安全软件拦截 AppleScript / 是否首次降级 |
| `id -u` 返回 0 但 `rm` 报 `Read-only file system` | 目标在只读卷 → 只能隐藏 |
| `id -u` 返回 0 但报 `Operation not permitted` | SIP 保护 → 放弃或隐藏 |
| 弹窗后立刻消失 | 密码错误次数过多被锁定 / 账户无管理员权限 |

### 7.5 日志与诊断入口

| 想看什么 | 去哪 |
|---|---|
| 本次操作做了什么 | 应用内「日志」（⇧⌘L） |
| 历史全部记录 | `~/Library/Logs/AppUninstaller/` |
| 扫描结果原始数据 | `~/Library/Caches/com.jt.AppUninstaller/inventory-v2.json` |
| 崩溃堆栈 | `~/Library/Logs/DiagnosticReports/AppUninstaller-*.ips` |
| 系统拒绝原因 | 打开「控制台」搜 `AppUninstaller` 或 `tccd` |

---

## 8. 后续维护注意事项

### 8.1 安全红线（改动前先读，不可突破）

1. **不得放宽 `ProtectionPolicy` 的 `forbidden` 判定**，也不得为了"能删更多"而移除关键组件名单。
2. **不得在未校验路径的情况下拼进 shell**。提权脚本只能来自 `PrivilegedExecutor.buildScript(for:)`，路径必须先过白名单。
3. **不得把残留白名单用在应用本体上**（历史上踩过：`~/Applications/*.app` 被误判为受保护，导致卸载全失败）。
4. **不得让 root 删除伪装成"可撤销"**。root 删除不进废纸篓，UI 必须如实告知。
5. **不得声称能删除 SSV 上的系统应用**。只能尝试 + 失败说明 + 隐藏。

### 8.2 改动前检查清单

- [ ] 改动是否触及 §2.3 中标为「高」的文件？如是，先补自测断言
- [ ] 是否新增了文件系统写入路径？若新增，加入 `isForbiddenResidualPath` 白名单并补正反例断言
- [ ] 是否新增 `InstalledApp` / `ResidualItem` 字段？若是，**升级缓存文件名**（见 §8.4）
- [ ] 是否改变 UI 文案中的承诺（可用性/撤销性）？与实现对齐
- [ ] 是否引入第三方依赖？**原则上不引入**（当前零依赖是重要资产）

### 8.3 回归测试

```bash
# 必跑（每次提交）
swift build --disable-sandbox -c release && ./.build/release/AppUninstaller --selftest

# 涉及提权逻辑时加跑（会弹窗，需人工输密码）
./.build/release/AppUninstaller --selftest --privileged
```

手工验收（10 分钟）：

1. 启动 → 列表有数据 → 总占用与「关于本机 › 储存空间」量级一致
2. 搜索 `xcode` → 命中；切换排序/筛选 → 无异常
3. 选中系统应用（Music）→ 显示「只读卷」+ 橙色横幅
4. 选中用户应用 → 确认面板 → 取消（不应有任何文件变化）
5. 真删一个**自建**测试 App（见 SelfTest 构造方式）→ 结果面板显示「已彻底清理」
6. ⇧⌘L 看日志 → 有对应记录

### 8.4 数据结构与缓存版本

`InstalledApp` 是 `Codable` 并整体缓存。**新增/改名字段会让旧 JSON 解码失败**，表现为"启动后列表空白"。处理方式：

```swift
// AppScanner.swift
return dir.appendingPathComponent("inventory-v2.json")   // 升到 v3
```

同时可选清理旧文件。**不要**用 `decodeIfPresent` 静默兜底——字段缺失通常意味着语义变化，宁可重扫。

### 8.5 版本号升级

改 `Resources/Info.plist`：

```xml
<key>CFBundleShortVersionString</key><string>1.1.0</string>  <!-- 面向用户 -->
<key>CFBundleVersion</key><string>2</string>                 <!-- 构建号，单调递增 -->
```

设置页「关于」读取的是 `CFBundleShortVersionString`，直接反映。

### 8.6 版本控制（当前缺失，建议尽快补）

```bash
cd AppUninstaller
git init
cat > .gitignore <<'EOF'
.build/
dist/
.DS_Store
*.xcuserstate
EOF
git add .
git commit -m "chore: initial import of App Uninstaller v1.0.0"
```

建议约定：`main` 保持可构建；每次改动同时更新 `HANDOVER.md` 的「已知限制」与「待改进」。

### 8.7 兼容性维护（新 macOS 发布时）

每年大版本更新后，按序检查：

| 检查项 | 方法 | 可能的变化 |
|---|---|---|
| CI runner 镜像 | 看 `.github/workflows/*.yml` 的 `runs-on`，对照 [actions/runner-images](https://github.com/actions/runner-images) 的支持列表 | GitHub 会定期退役旧镜像；退役后 job 在派发阶段即失败（`The configuration '<image>-<arch>-<region>-default' is not supported`），不会分配到 runner |
| 卷结构 | `mount \| grep ' on / '` | 若 `/System` 变为可写，`systemVolume` 分支可真正删除 |
| SIP 行为 | `csrutil status` | 影响提权后能否落盘 |
| AppleScript 提权 | `osascript -e 'do shell script "id -u" with administrator privileges'` | 若 Apple 收紧，需迁移到 `SMAppService` + 特权 helper |
| LaunchServices 路径 | `ls /System/Library/Frameworks/CoreServices.framework/.../Support/lsregister` | 路径变了则「隐藏」失效 |
| 新 TCC 类别 | 实测卸载是否被拦 | 需在 README/设置页补授权指引 |
| SwiftUI API | `swift build` 的 deprecation 警告 | 顺手升级，别攒 |

### 8.8 待改进项（Backlog，按优先级）

| ID | 事项 | 说明 |
|---|---|---|
| T-01 | `build.sh` 产物定位不够稳 | 先查 `.build/release/`，universal 构建后可能取到旧单架构产物；建议统一改为 `swift build --show-bin-path` 获取路径 |
| T-02 | Universal 分发 | Intel 机器无法运行当前产物，见 §4.4 |
| T-03 | 批量卸载 | 目前一次一个应用；如需批量，注意提权合并与结果面板聚合 |
| T-04 | 提权通道升级 | AppleScript 路径未来可能收紧，可评估 `SMAppService` 特权 helper（需 Developer ID） |
| T-05 | 体积统计缓存 | 二次扫描可只重算 mtime 变化的包 |
| T-06 | 已隐藏应用清单 | 目前只能"全部恢复"，缺少逐条恢复 |
| T-07 | 本地化 | 当前仅简体中文硬编码文案 |

---

## 9. 附录

### A. 常量与路径速查

| 项 | 值 | 定义位置 |
|---|---|---|
| Bundle ID | `com.jt.AppUninstaller` | `Resources/Info.plist` |
| 最低系统 | `13.0` | `Info.plist` / `Package.swift` |
| 扫描缓存 | `~/Library/Caches/com.jt.AppUninstaller/inventory-v2.json` | `AppScanner.cacheURL` |
| 日志 | `~/Library/Logs/AppUninstaller/uninstall-YYYY-MM-DD.log` | `LogStore.logDirectory` |
| 偏好 | `~/Library/Preferences/com.jt.AppUninstaller.plist` | `Prefs` |
| 扫描根 | `/Applications`、`~/Applications`、`/System/Applications` | `AppScanner.scanRoots` |
| 托管根 | `/Applications`、`/Users/Shared/Applications`、`~/Applications` | `ProtectionPolicy.allowedRoots` |
| 递归深度 | 3 | `AppScanner.discoverBundles` |
| 内存日志上限 | 500 条 | `LogStore.memoryLimit` |
| 退出应用超时 | 3 秒（30 × 100 ms） | `Uninstaller.terminateIfRunning` |
| 取消错误码 | `-128` | `PrivilegedExecutor.execute` |

### B. 关键数据结构

```swift
enum RemovalScope { case userManaged, adminRequired, systemVolume, forbidden }

struct InstalledApp {
    let path, name: String
    let bundleID, shortVersion, buildVersion, executableName: String?
    let sizeBytes: Int64
    let modifiedDate, createdDate: Date?
    let source: AppSource            // userInstalled / appStore / systemBuiltin / other
    let architectures: [String]
    let minimumSystemVersion: String?
    let isAppStoreSigned: Bool
    var removalScope: RemovalScope
    let protectionReason: String?
}

struct ResidualItem {
    let path: String
    let kind: ResidualKind           // 16 类
    let risk: RiskLevel              // safe < caution < risky
    let sizeBytes: Int64
    let requiresAdmin: Bool
    var isSelected: Bool
}

struct UninstallOutcome {
    var appRemoved, residualRemoved, residualFailed: Int
    var freedBytes: Int64
    var trashMap: [String: String]   // 原路径 → 废纸篓路径
    var errors: [String]
    var verification: VerificationReport?
    var blockedBySystemVolume, authorizationCancelled: Bool
}

struct VerificationReport {
    let appStillExists: Bool
    let clearedPaths: [String]
    let remaining: [RemainderItem]   // path + size + reason
    let blockedBySystemVolume: Bool
    var isFullyCleared: Bool { !appStillExists && remaining.isEmpty }
}
```

### C. 验收脚本（可直接跑）

```bash
#!/bin/bash
set -e
cd "$(dirname "$0")"

echo "== 1. 构建 =="
swift build --disable-sandbox -c release

echo "== 2. 自测 =="
./.build/release/AppUninstaller --selftest

echo "== 3. 打包 =="
./build.sh

echo "== 4. 产物校验 =="
APP="dist/App Uninstaller.app"
test -x "$APP/Contents/MacOS/AppUninstaller" || { echo "缺少可执行文件"; exit 1; }
test -f "$APP/Contents/Info.plist" || { echo "缺少 Info.plist"; exit 1; }
codesign -dv "$APP" 2>&1 | grep -q "Identifier=com.jt.AppUninstaller" || { echo "签名标识不符"; exit 1; }
plutil -p "$APP/Contents/Info.plist" | grep -q "LSMinimumSystemVersion" || { echo "缺少最低系统版本"; exit 1; }

echo "== 5. 启动 =="
open "$APP"
echo "全部检查通过"
```

保存为 `scripts/verify.sh` 并 `chmod +x` 即可。

### D. 交接确认单

| # | 事项 | 确认人 | 日期 |
|---|---|---|---|
| 1 | 能独立完成 `./build.sh` 并启动 | | |
| 2 | 能跑通 `--selftest`（34 项） | | |
| 3 | 读过 §8.1 安全红线并理解 | | |
| 4 | 知道改 bundleID 要同步 5 处（§4.3） | | |
| 5 | 知道系统内置应用不可物理删除的原因（§6.9） | | |
| 6 | 知道提权路径在哪、如何排查（§7.4） | | |
| 7 | 已初始化 git 并提交首个版本（§8.6） | | |
| 8 | 已确认 Backlog（§8.8）中哪些要继续做 | | |

---

**文档维护约定**：改动涉及「判定规则 / 提权通道 / 缓存结构 / 目录布局」时，必须同步更新本文档对应章节，并在 §1.4 更新状态表。
