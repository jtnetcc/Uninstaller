# App Uninstaller

macOS 原生应用管理与卸载工具。列出已安装应用、统计真实磁盘占用、支持搜索/排序/筛选，在确认后安全卸载应用及其残留数据，并对清理结果做二次核验。

- 技术栈：Swift 6 / SwiftUI / AppKit，SwiftPM 构建，无第三方依赖
- 最低系统：macOS 13.0 (Ventura)，已在 macOS 26/27 上验证
- 产物：`dist/App Uninstaller.app`（可直接双击运行，ad-hoc 签名）

> 接手维护、换机器/换账号、排障，请看 **[HANDOVER.md](HANDOVER.md)**。本文档面向功能说明，HANDOVER 面向工程交接。

---

## 1. 功能

| 模块 | 能力 |
|---|---|
| 应用清单 | 扫描 `/Applications`、`~/Applications`、`/System/Applications`（含 Utilities），读取 `Info.plist` 得到名称、版本（短版本 + Build）、Bundle ID、可执行文件、架构（arm64 / x86_64 / Universal）、最低系统版本、安装/更新时间 |
| 体积统计 | 按 **allocated size** 逐文件累加（非"表观大小"），`concurrentPerform` 并发计算 |
| 搜索 / 排序 / 筛选 | 关键词匹配名称、Bundle ID、路径；5 种排序；侧边栏按「全部 / 可卸载 / >1GB / 受保护 / 来源」筛选 |
| 残留识别 | 覆盖 16 类落点，支持 `<Vendor>/<Product>` 厂商目录结构与大小写不敏感匹配 |
| 安全卸载 | 退出运行实例 → 移入废纸篓（默认）或永久删除 → 逐项清理残留；用户级删除可撤销（⇧⌘Z） |
| **管理员授权** | 需要 root 的操作会弹出 **系统验证窗口**，输入本机登录密码完成授权；多路径合并为**一次**授权，避免反复弹窗 |
| **系统内置应用** | `/System/Applications` 中的预装应用可发起移除尝试（走管理员授权）；受只读卷限制失败时提供「隐藏」作为替代 |
| **清理后复检** | 执行完成后自动重新扫盘，逐项确认是否真正清除，弹窗反馈「已清除 / 仍残留」并列出残留路径与原因，可一键重试 |
| 确认与日志 | 卸载前确认面板（勾选残留、显示预计释放空间）；每步写入 `~/Library/Logs/AppUninstaller/uninstall-YYYY-MM-DD.log`（JSONL） |

---

## 2. 权限模型（四档判定）

`ProtectionPolicy.evaluate` 返回 `RemovalScope`，决定权限与可行性：

| 档位 | 判定条件 | 行为 |
|---|---|---|
| `userManaged` | 位于 `~/Applications`，或 `/Applications` 下当前用户可写 | 直接删除 / 移入废纸篓，可撤销 |
| `adminRequired` | 位于 `/Applications` 但包内属主为 root（Xcode、iWork、多数第三方安装的 App） | 先尝试普通权限，失败后弹出系统授权窗口以 root 删除 |
| `systemVolume` | 位于 `/System/Applications`（只读签名卷 SSV） | 允许发起 root 删除尝试；失败提示原因并提供「隐藏」 |
| `forbidden` | 命中关键组件名单（Finder、Dock、System Settings、WindowManager、Spotlight、SecurityAgent 等）、系统禁止目录（`/usr`、`/bin`、`/private`、`/System/Library`）、符号链接、非 `.app` | 界面禁用，任何情况下不可操作 |

判定在**扫描时**与**执行前**各做一次，避免状态变化导致误删。

### 授权流程

1. 点击「授权卸载 / 授权并尝试删除」→ 弹出确认面板，明确告知「以管理员权限删除的内容不进入废纸篓，无法撤销」
2. 确认后调用 AppleScript `do shell script … with administrator privileges`，由 SecurityAgent 弹出**系统标准验证窗口**，要求输入登录密码
3. 授权通过后以 root 执行删除脚本，逐路径返回 `OK` / `GONE` / `FAIL`
4. 用户取消（错误码 -128）时不做任何修改，并如实反馈
5. 首次调用若被系统降级为普通权限执行（表现为 `Permission denied`），自动重试一次

---

## 3. 系统内置应用的处理

macOS 11 之后，`/System` 是**只读签名系统卷（SSV）**，受 SIP 保护。实测：

```
/dev/disk3s3s1 on / (apfs, sealed, local, read-only, journaled)
System Integrity Protection status: enabled.
```

因此 `/System/Applications` 下的预装应用（Safari、Music、Mail 等）**即使 root 也无法物理删除**——这是系统设计，不是权限问题。工具对此的处理：

- 允许发起移除：以管理员权限尝试 `rm -rf`，如系统卷可写（SIP 关闭且已挂载可写）则真实删除成功
- 失败时明确回复原因（`Read-only file system` / SIP 状态），并给出两个选项：
  - **隐藏**：通过 `lsregister -u` 注销 LaunchServices 记录，使应用从启动台与聚焦中消失（文件仍在，可逆）
  - **以管理员权限重试**
- 设置中提供「恢复全部系统应用注册」，一键还原

预装在 `/Applications` 的 Apple 应用（Xcode、iWork、Final Cut、GarageBand 等）属于 `adminRequired`，可由本工具正常卸载，之后可从 App Store 重新下载。

---

## 4. 构建与运行

```bash
cd AppUninstaller

# 打包（release + 组装 .app + ad-hoc 签名）
./build.sh

# 可选：清理后重建
./build.sh --clean

# 运行
open "dist/App Uninstaller.app"
```

仅编译不打包：

```bash
swift build --disable-sandbox -c release
# 产物: .build/release/AppUninstaller
```

> `--disable-sandbox`：在受限/沙盒化终端中 SwiftPM 自身的 sandbox-exec 可能不可用，加此参数可正常构建。普通终端可省略。

### 自测（不触碰真实应用）

```bash
# 基础链路：扫描 → 判定 → 残留匹配 → 卸载 → 复检 → 撤销
./.build/release/AppUninstaller --selftest

# 追加管理员授权链路测试（会弹系统验证窗口，需输入登录密码）
./.build/release/AppUninstaller --selftest --privileged

# 追加进程回收测试（启动真实进程树，验证 helper 子进程被一并终止；需要 cc）
./.build/release/AppUninstaller --selftest --proctest
```

- 基础模式 35 项断言；`--proctest` 共 41 项（含真实进程树回收）；`--privileged` 共 43 项（含 root 提权删除）
- 测试数据全部位于 `~/Applications` 与 `/Library/Application Support/AUPrivTest-*`，结束时自动清理
- 退出码非 0 表示失败

---

## 5. 目录结构

```
AppUninstaller/
├── Package.swift
├── build.sh                     # 构建 + 组装 .app + 签名
├── HANDOVER.md                  # 交接文档（环境/架构/排障/维护红线）
├── scripts/verify.sh            # 一键验收：构建 → 自测 → 打包 → 产物校验
├── Resources/{Info.plist, AppIcon.icns}
├── Tools/make_icon.swift        # 图标生成（CoreGraphics 绘制）
└── Sources/AppUninstaller/
    ├── AppMain.swift            # @main / 菜单 / 自测入口
    ├── Models/Models.swift      # InstalledApp / RemovalScope / VerificationReport / LogEntry
    ├── Services/
    │   ├── AppScanner.swift     # 枚举、Info.plist 解析、体积统计、缓存
    │   ├── ProtectionPolicy.swift   # 四档判定、SIP / 只读卷探测、残留白名单
    │   ├── ResidualScanner.swift    # 16 类落点匹配
    │   ├── PrivilegedExecutor.swift # root 授权执行 + 系统应用隐藏
    │   ├── Uninstaller.swift        # 卸载、提权编排、清理后复检、撤销
    │   ├── LogStore.swift
    │   └── SelfTest.swift
    ├── ViewModels/AppViewModel.swift
    └── Views/                   # ContentView / Sidebar / AppList / Detail / UninstallSheet / UninstallResultSheet / Log / Settings
```

---

## 6. 清理后复检

`Uninstaller.verify` 在执行结束后**重新 stat 每个目标路径**（不复用执行阶段的返回值），生成 `VerificationReport`：

| 字段 | 含义 |
|---|---|
| `clearedPaths` | 已确认不存在的路径 |
| `remaining` | 仍存在的路径 + 体积 + 原因（只读卷 / 需管理员权限 / 被占用） |
| `appStillExists` | 应用本体是否残留 |
| `blockedBySystemVolume` | 是否因只读卷无法移除 |

结果面板（`UninstallResultSheet`）展示三个统计卡、原因说明、残留清单，并提供「重新检测 / 以管理员权限重试 / 隐藏 / 撤销 / 完成」。

---

## 7. 残留数据落点

| 类别 | 位置 |
|---|---|
| 应用支持数据 | `~/Library/Application Support/<bundleID>`、`<名称>`、`<Vendor>/<Product>` |
| 缓存 | `~/Library/Caches/<bundleID>`、`<名称>`、`<Vendor>/<Product>` |
| 偏好设置 | `~/Library/Preferences/<bundleID>.plist`、`ByHost/<bundleID>.*.plist` |
| 沙盒数据 | `~/Library/Containers/<bundleID>`、`Group Containers/*.<bundleID>`（共享，默认不勾选） |
| 状态与网络 | `Saved Application State`、`HTTPStorages`、`WebKit`、`Cookies` |
| 登录项 | `~/Library/LaunchAgents/<bundleID>.plist`、`/Library/LaunchAgents`、`/Library/LaunchDaemons` |
| 收据 | `~/Library/Receipts`、`/private/var/db/receipts` |
| 系统级 | `/Library/Application Support`、`/Library/Caches`、`/Library/Preferences`、`/Library/Logs`（需管理员权限，自动提权） |

残留白名单采用「默认禁止、白名单允许」：只允许 `~/Library/` 与 `/Library` 下可清理子目录，拒绝 `~/Library`、`/Library/Caches` 等目录本体。

风险分级：`安全`（缓存、日志、偏好）/ `留意`（应用支持数据、沙盒容器）/ `谨慎`（群组容器、LaunchDaemon，默认不勾选）。

---

## 8. 兼容性

- 部署目标 macOS 13.0；使用 `NavigationSplitView`、`WindowGroup`、`.task(id:)` 等 macOS 13 起可用 API
- 系统应用位于只读系统卷（macOS 11+）的情况已识别并单独处理
- macOS 13+ 修改 `/Applications` 中其他应用会触发「App 管理」TCC 授权；被拒时界面给出指引：系统设置 › 隐私与安全性 › App 管理
- 未启用 App Sandbox（需遍历 `/Applications` 与用户 Library）；上架 App Store 需改为 Security-Scoped Bookmark + 用户逐目录授权

---

## 9. 已知限制

- **系统内置应用无法物理删除**：只读签名卷 + SIP 所致，非工具限制；「隐藏」是安全可行的替代
- 隐藏依赖 LaunchServices 数据库，系统更新后可能被重新注册
- 体积统计基于 allocated size，APFS 压缩/克隆文件可能小于逻辑大小
- 不清理 `~/Library/Developer`、`~/Library/Mobile Documents` 等用户文档型数据（避免误删）
- root 删除不进废纸篓，不可撤销（确认面板已明确提示）
- ad-hoc 签名分发给其他机器需自行签名/公证：`codesign --deep --sign "Developer ID Application: ..."`
