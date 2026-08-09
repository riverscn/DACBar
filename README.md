# DACBar

面向多厂商 USB DAC 的 macOS 菜单栏控制 App。首个且目前唯一完成真机验证的设备是
Shanling UA1 II（`20B1:3033`）；厂商品牌只存在于对应的设备模块中，不代表 App 品牌。

协议已在真机上双向验证，七个命令字全部确认——过程见
[ProtocolFindings.md](Documentation/ShanlingUA1II/ProtocolFindings.md)。

## 仓库内容

| 路径 | 说明 |
|---|---|
| `DACBar.xcodeproj` | 原生 macOS App、App tests、共享 Scheme 和发布入口 |
| `App/` | App 入口、SwiftUI、业务模型、组合根、Sparkle 与本地化资源 |
| `DACBarTests/` | 由 Xcode test target 托管的 App/业务层测试 |
| `Packages/DACDevices/` | 可独立测试的设备 SDK；包含厂商无关核心与 UA1 II plug-in |
| [`Documentation/Architecture.md`](Documentation/Architecture.md) | 多型号 Profile、Driver、能力与 UI 扩展边界 |
| [`CHANGELOG.md`](CHANGELOG.md) | 用户可见的版本变更 |
| [`Documentation/Releasing.md`](Documentation/Releasing.md) | CI、Developer ID、公证和发布流程 |
| [`tools/capture.c`](tools/capture.c) | 命令行诊断工具 |
| [`tools/make-icon.swift`](tools/make-icon.swift) | 生成 `App/Resources/AppIcon.icon` |

## 快速开始

开发时直接打开 Xcode 工程并选择共享的 `DACBar` Scheme：

```bash
open DACBar.xcodeproj
```

设备 SDK 也可单独打开 `Packages/DACDevices/Package.swift`，开发设备协议与运行其
单元测试。命令行可组装一个与发布流程相同的 Universal 2 App（`arm64 + x86_64`）：

```bash
./build.sh
cp -R dist/DACBar.app /Applications/
open /Applications/DACBar.app
```

需要 Xcode 27 / Swift 6.4；源码使用 Swift 6 language mode。打开即用，不需要授权、
不需要 root，也不必放在特定目录。

`build.sh` 默认使用 ad-hoc 签名，避免在装有多个团队证书的机器上误选身份。
debug 和 release 都生成同时支持 Apple Silicon 与 Intel Mac 的 Universal 2 App：

| 证书 | 适用范围 |
|---|---|
| Developer ID Application | 通过 `DACBAR_SIGN_ID` 显式指定，公证后可分发 |
| Apple Development | 通过 `DACBAR_SIGN_ID` 显式指定，仅本机开发 |
| ad-hoc（默认） | 本机使用 |

调试构建可用 `./build.sh debug`。

## 架构

当前发布版只启用经过真机验证的 UA1 II，但设备识别和 App 状态没有写死具体型号：
组合根注册设备模块，发现结果携带 Profile，Driver 把型号协议转换为通用的
`Snapshot`/`Mutation`，SwiftUI 再按 Driver 提供的 `SettingDescriptor` 动态生成控件。
新增型号只需新增设备 target 并在 `SupportedDevices` 注册，不需要修改 `DeviceModel`
或 `ContentView`。完整分层和接入清单见
[`Documentation/Architecture.md`](Documentation/Architecture.md)。

目前只有 `hidService + hidReports + shanling.ua1-ii.hid` 有实际 backend；源码里其它 discovery
和 transport 枚举只是预留词汇，不表示对应型号已经可用。支持范围以
`App/SupportedDevices.swift` 的组合结果为准。

设备的厂商控制通道挂在接口 2 的 HID 上，而 macOS 的 HID 驱动允许非独占访问——
读写都不需要抢占它，也就不需要任何特权组件：

```
DACBar.app  (用户态)
      ↕ IOHIDDevice
Shanling UA1 II  接口 2（HID）
```

写入是输出报告，读取是输入报告（四页约 1 秒），设备还会在**机身按键改动设置时主动上报**，
所以面板不用轮询也能跟机身保持一致。全程不影响音频。

### 关键：缓冲区必须自带 report ID

```swift
// 生效：41 字节，首字节就是报告 ID 0x01
IOHIDDeviceSetReportWithCallback(dev, kIOHIDReportTypeOutput, 0, frame41, 41, ...)
// 无效：40 字节载荷，缺少 ID
IOHIDDeviceSetReportWithCallback(dev, kIOHIDReportTypeOutput, 1, payload40, 40, ...)
```

IOKit 把缓冲区原样发往中断 OUT 端点 `0x03`，**不会替你补上报告 ID**。缺了它，
设备收到的报文以 `0xAA` 开头，固件直接丢弃。`reportID` 参数本身不是决定因素——
同步 API 传 0 或 1 都可以，只要缓冲区对；本项目的异步 API 使用真机验证过的 0。

弄错时写入不生效、查询也没有回音，很容易被当成「这条通道不通」。

另有两条同样要紧的规矩：**每个请求会回两条报文**（数据帧 + 结束帧，必须把结束
帧也收掉），以及异步路径上要从**上一条完成回调之后**再等待至少 130ms。详见
[ProtocolFindings.md](Documentation/ShanlingUA1II/ProtocolFindings.md)。

### 为什么只有 macOS 版

同一个 HID 通道，macOS 原生程序收发自如，换个平台就未必：

| 平台 | 可行性 |
|---|---|
| **macOS** | ✅ 本项目 |
| 网页（WebHID / WebUSB） | ❌ Chromium 无条件保护这类 usage |
| iPhone | ❌ IOKit 不开放给第三方 App |
| iPad（M1+） | ⚠️ 只能写 USBDriverKit dext，需 Apple 授予权限 |
| Android | ✅ 官方 App 即如此（平台开放 USB host） |

**网页**：设备把厂商通道的顶层 usage 声明为 Generic Desktop / System
Control（`0x01`/`0x80`），Chromium 对 `0x80`–`0x8F` 这段无条件保护、输入输出
全拦（`hid_report_utils.cc` 的 `IsAlwaysProtected`）。WebUSB 也不行：设备只有
audio 和 HID 两类接口，都在受保护类里，`claimInterface()` 永远失败。真要打开
这条路只能靠固件——顶层 usage 换成厂商自定义页（`0xFF00+`）即可放行。

**iOS**：`IOHIDManager` 根本不可用，HIDDriverKit 在 iPadOS 上也没有。

这些都不是设备或协议的限制，而是各平台的策略差异。完整论证与出处见
[ProtocolFindings.md](Documentation/ShanlingUA1II/ProtocolFindings.md)。

### 多台设备

按 `locationID`（USB 端口路径）区分。UA1 II 的序列号是常量 `"Shanling"`，
两台同型号在身份上无法区分，插在哪个口是唯一依据。设备名相同，所以界面上只能
按端口标示，且只在多于一台时才显示选择器。

> **两台同时插入的行为尚未在真机验证** —— 开发时只有一台。

设备拔插由长期存活的 `IOHIDManager` 被动通知：matching callback 表示匹配的 HID
service 已完成枚举，removal callback 表示它已移除。这与实际控制层使用同一套 HID
匹配条件，不依赖更早出现的 USB 设备节点，也没有周期轮询。

HID service 出现并不保证设备固件已经能回答厂商命令。重新插入后的初始读取若遇到
短暂 timeout，界面会保持“正在读取”，按 600ms、1s 两档退避自动重试；连续三次失败
才进入错误状态。拔出、切换设备或 session 更新会立即取消这些等待。

### 写入节奏与确认

同步 API 的极限测试中，120ms 只有 15/30 落地，130ms 起 30/30。异步 API 也使用
130ms，但节流基准必须是 `IOHIDDeviceSetReportWithCallback` 的**完成回调**，不能是
函数调用开始。旧实现从调用开始计时，IOKit 的异步排队时间会吃掉设备真正收到的
间隔，因此表面上把门限提高到 200ms 仍可能丢包。修正后，三轮约 180 次 UI 更新的
真机压力测试没有出现应答超时。拖动时中间 UI 值会合并，最终值由确认与有限重发
保证必达。

HID 设备调度在 run loop 的 common modes 中，而不是只放在 default mode。AppKit 在
按住滑块时会进入 event-tracking mode；若只注册 default mode，设备虽然发出了确认，
输入回调也会在整段拖动期间停摆，最后被 App 误判成写入失败。

**每条写入都会跟踪设备的 `0x10` 应答确认**，但不会让下一条写入阻塞等待。
`IOHIDDeviceSetReportWithCallback` 的完成回调返回成功不能说明
什么——被丢弃的写入照样返回成功；而丢弃时不会有应答（实测 100ms 间隔发 6 条、
只回 3 条应答，设备停在最后一条**有应答**的值上）。没等到应答就重发一次；仍失败
则回滚内部状态并显示明确错误，由“重试”重新读取设备，不会无限发送或默默跑偏。

### 真机回归与间隔测量

真机测试默认关闭。只有一台支持设备时可以直接运行；检测到多台时测试会拒绝默认
选择，必须用 `SHANLING_HARDWARE_LOCATION_ID` 指定目标，避免修改错误的设备：

```bash
SHANLING_HARDWARE_TESTS=1 \
SHANLING_HARDWARE_LOCATION_ID=0x01100000 \
swift test --package-path Packages/DACDevices --scratch-path .build/package --no-parallel
```

若只接了一台，`SHANLING_HARDWARE_LOCATION_ID` 可以省略；多台而未指定时，错误信息
会列出当前可用的 location ID。所有会改变设置的测试都会保存并恢复原值。

异步 completion 后间隔的阶梯测量是独立 opt-in 项，不修改正式的 130ms 常量：

```bash
SHANLING_HARDWARE_TESTS=1 \
SHANLING_HARDWARE_LOCATION_ID=0x01100000 \
SHANLING_SWEEP_INTERVALS=140,135,130,128,127,126,125,120 \
SHANLING_SWEEP_COUNT=80 \
swift test --package-path Packages/DACDevices --scratch-path .build/package --no-parallel \
  --filter HardwareIntegrationTests.completionIntervalSweep
```

每档会输出 completion、ACK、timeout、压力结束时的实际亮度及恢复结果。ACK 丢失是
测量数据，不会让测试提前退出；发送失败或无法恢复原值才算测试失败。为控制风险，
间隔限定为 50–1000ms、每档 2–500 次，只交替写入相邻亮度值。

## 协议速览

写 41 字节到中断 OUT `0x03`（report ID `0x01` + 40 字节载荷），读 9 字节自中断 IN `0x82`。

```
请求载荷 (40B):  AA 55 10 <cmd> <val> 01 00…00 <~sum(p[0..38])>
回复     (9B):   01 55 AA <page> <data×4> <~sum(f[1..7])>
```

读状态发 `cmd=0xFF, val=页号 0..3`，回复页 ID 为 `0x20+页号`：

| 页 | 内容 |
|---|---|
| `0x20` | 固件版本 `[4..6]` |
| `0x21` | 音频：`[4]`音量 `[5]`增益 `[6]`滤波器 `[7]`平衡 |
| `0x22` | 显示：`[4]`亮度 `[5]`息屏 `[6]`方向 |
| `0x23` | `[4]`−50 = 屏幕偏移 |

写命令（全部真机验证）：

| 命令 | 项目 | 编码 |
|---|---|---|
| `0x01` | 音量 | 0–99 |
| `0x02` | 增益 | 0 低 / 1 高 |
| `0x03` | 滤波器 | 0–4 |
| `0x04` | 声道平衡 | **有符号字节**，−12…12 |
| `0x06` | 亮度 | 0–10 |
| `0x07` | 屏幕方向 | 0–3 |
| `0x09` | 息屏时间 | 秒，0 = 常亮 |
| `0x15` | 屏幕偏移 | **wire 值 = 逻辑值 + 50** |

写入后设备回一条 `[3]=0x10` 的应答，回显 command 和 value。

> **每个请求会回两条报文**（数据 + 结束帧）。取到数据帧后必须把结束帧也收掉，
> 否则下一个请求会先读到这条残留，真正的回复整体延迟一条，看起来像设备只返回
> 空页——很容易据此误判协议不通。走 HID 路径同样如此。

## 命令行工具

```bash
mkdir -p .build/tools
clang -o .build/tools/capture tools/capture.c -framework IOKit -framework CoreFoundation
sudo ./.build/tools/capture              # 读四页状态
sudo ./.build/tools/capture 01 40        # 写 command 0x01 = 40，然后读回验证
sudo ./.build/tools/capture verify       # 批量验证命令字，自动恢复原值
```

走的是 root 设备捕获路径（会中断音频），与 App 的 HID 路径互相独立。
排查设备本身的问题时最直接——它不依赖 App 的任何代码。

## 构建说明

项目以 Xcode 27 / Swift 6.4 为工具链基线，并使用 Swift 6 language mode。
`DACBar.xcodeproj` 直接拥有唯一的 App target 和 App test target；
`Packages/DACDevices/Package.swift` 只提供 `DACDeviceKit` 与 `ShanlingUA1II` 两个
可复用库。`build.sh` 调用共享的 `DACBar` Scheme，再完成 Universal 2 产物的签名与验证。

Xcode 的 Debug 与 Release 都是可直接运行的本地配置；ad-hoc 主程序使用
`DACBar.Local.entitlements` 加载独立 ad-hoc 签名的 Sparkle。Distribution 不携带该
调试权限，是 Archive 和 `build.sh release` 使用的干净发布输入；正式签名仍由脚本按
嵌套代码由内到外完成。

**部署目标与链接 SDK 分开。** Xcode Target 的 deployment target 是 macOS 14，链接
SDK 则来自当前 Xcode；因此仍能在 macOS 14+ 运行，同时使用新 SDK 提供的系统外观。

**签名带安全时间戳。** 它是公证的前置条件；ad-hoc 无法加时间戳，所以那条路径
显式关闭。

默认 Bundle ID 只在 `App/Configuration/Identity.xcconfig` 中维护。分发时必须同时
指定 Developer ID 证书、公证配置、Sparkle appcast 地址和 Ed25519 公钥：

```bash
DACBAR_SIGN_ID="Developer ID Application: Example (TEAMID)" \
DACBAR_NOTARY_PROFILE=dacbar-notary \
DACBAR_SPARKLE_FEED_URL=https://github.com/example/dacbar/releases/latest/download/appcast.xml \
DACBAR_SPARKLE_PUBLIC_KEY=<Base64-encoded-Ed25519-public-key> \
./build.sh
```

### 环境变量

| 变量 | 作用 |
|---|---|
| `DACBAR_SIGN_ID` | 完整签名身份；不设置时使用 ad-hoc |
| `DACBAR_SIGN_KEYCHAIN` | 可选的签名钥匙串路径；CI 用它避免修改 runner 默认钥匙串 |
| `DACBAR_NOTARY_PROFILE` | `notarytool` 的钥匙串配置名，设置后自动公证 |
| `DACBAR_NOTARY_KEYCHAIN` | 可选的公证凭据钥匙串路径 |
| `DACBAR_BUILD_NUMBER` | `CFBundleVersion`，默认使用当前 Git commit 数量 |
| `DACBAR_SPARKLE_FEED_URL` | Sparkle appcast 的 HTTPS 地址；公证构建必填 |
| `DACBAR_SPARKLE_PUBLIC_KEY` | 用于验证更新归档的 32 字节 Ed25519 公钥（Base64）；公证构建必填 |

App 身份只在 `App/Configuration/Identity.xcconfig` 中维护，脚本通过 Xcode 的有效
`PRODUCT_BUNDLE_IDENTIFIER` 读取它；用户可见版本只在
`App/Configuration/Version.xcconfig` 的 `MARKETING_VERSION` 中维护；
Xcode Run、`build.sh`、Git tag、DMG 和 Sparkle appcast 都从该有效设置或构建后的 App
读取。CI 只覆盖递增的 `CURRENT_PROJECT_VERSION`，不会改写用户版本。

### 应用图标

`App/Resources/AppIcon.icon` 已入库，改动后用 `swift tools/make-icon.swift` 重新生成。

这是 Icon Composer 的 `.icon` 格式——一个目录，含 JSON 清单和图层美术。
Xcode App Target 用 asset catalog compiler 编译，同时产出 `Assets.car`（macOS 26 走
`CFBundleIconName`）和回退用的 `AppIcon.icns`（更早的系统走
`CFBundleIconFile`），两个键都写进 Info.plist。

不再直接生成 `.icns`：macOS 26 会把旧式 `.icns` 缩小、嵌进一块灰色系统底板，
显示成两层圆角矩形套在一起；`.icon` 则铺满整个图标框，并自动获得深色和着色变体。

asset catalog compiler 随完整 Xcode 提供，命令行工具包里没有。发布构建不再容忍缺失
图标；若没有完整 Xcode，构建会直接失败，避免生成看似可分发但没有图标的 App。

## ⚠️ 安全提示

40 字节载荷绝大部分是 `00`，**未文档化的命令字行为未知**。不要遍历 command
空间——固件升级 / DFU 入口很可能藏在某个未用命令后面。

## 致谢

协议线索来自 [pryid/shanling-control](https://github.com/pryid/shanling-control)
（对 Eddict Player 的反编译）。该项目未在 UA1 II 上验证过，本仓库补上了这个验证：
除端点类型标注有误（写作 bulk，实为 interrupt）外，其余全部正确。

## 分发

用 Developer ID 签名只是前提，还需公证，否则别人首次打开会被 Gatekeeper 拦
（`spctl -a` 报 `Unnotarized Developer ID`）。

先把凭据存进钥匙串（**只需一次**，此后不再出现在命令行或仓库里）：

```bash
xcrun notarytool store-credentials dacbar \
    --apple-id <你的 Apple ID> --team-id <TEAMID> --password <app 专用密码>
```

app 专用密码在 [appleid.apple.com](https://appleid.apple.com) 生成，
不是 Apple ID 的登录密码。

之后显式指定发布身份、Bundle ID 和配置名；`build.sh` 会构建 Universal 2 App，分别
完成 App 与安装镜像的签名、公证和票据装订，并生成 APFS/LZFSE DMG：

```bash
DACBAR_SIGN_ID="Developer ID Application: Example (TEAMID)" \
DACBAR_NOTARY_PROFILE=dacbar \
DACBAR_SPARKLE_FEED_URL=https://github.com/example/dacbar/releases/latest/download/appcast.xml \
DACBAR_SPARKLE_PUBLIC_KEY=<Base64-encoded-Ed25519-public-key> \
./build.sh
```

不带这些变量时使用 ad-hoc 并跳过公证，构建照常完成，只是产物仅本机可用。
公证失败时会自动拉取 `notarytool log` 打印原因。

GitHub Actions 已把检查拆成 `ci.yml`、`release.yml` 和手动的 `hardware.yml`。源码测试、
Universal 2 构建、签名和公证都运行在隔离的标准 GitHub-hosted `xcode-27` ARM64 runner；
随后 `macos-26-intel` 下载**同一个 DMG**，校验 x86_64 切片并实际启动 App。只有两边都
通过，独立的 Ubuntu job 才以最小 `contents: write` 权限创建 GitHub Release。普通 CI
使用 `pull_request`、只读 token 且不接触发布 secrets；公开仓库的 standard hosted runner
不计 Actions 分钟，larger runner 不在本项目的自动化路径中。

USB 真机回归仍需要接有设备的 Mac，因此只保留一个带 `DACBar-Hardware` 自定义标签的
Apple Silicon self-hosted runner。它只允许仓库所有者在 `main` 上手动触发，不参与普通
push、PR 或发布，也不持有发布凭据。推送与 Xcode 有效 `MARKETING_VERSION` 一致的 `v*`
tag 后，发布 workflow 才会读取仓库 secrets 完成签名、公证、DMG、SHA-256 和
GitHub Release。完整配置见
[`Documentation/Releasing.md`](Documentation/Releasing.md)。

正式发布版使用 Sparkle 2.9.5。第二次正常启动时由 Sparkle 的标准授权界面询问用户是否
每 24 小时后台检查，并默认建议自动下载、安装；App 不替用户强制开启。面板中的
“检查更新”仍可立即触发一次交互式检查。appcast 签名覆盖内嵌发布说明，Universal 2
DMG 另行经过 Ed25519 签名验证；DMG 与其中的 App 还须通过 Developer ID 与公证验证，
且不直接执行 GitHub API 返回的内容。密钥生成、轮换、CI secrets 和 N-1 → N 发布验收见
[`Documentation/Releasing.md`](Documentation/Releasing.md)。Dependabot 每周检查 Sparkle
与 Actions 依赖更新。

公开下载与 Sparkle enclosure 使用同一个只读 APFS/LZFSE DMG，其中仅包含
`DACBar.app` 和指向 `/Applications` 的拖放安装链接。ZIP 只作为向 Apple 提交 App
公证时的临时容器，不会上传到 Release；项目不使用已弃用的 XIP。

App 当前刻意保持**非沙箱**：Developer ID 分发不要求 App Sandbox，IOHID/IOKit 控制也
已在非沙箱路径完成真机验证。发布签名不带 sandbox entitlement；本地 ad-hoc
Debug/Release 以及 `build.sh` 的 ad-hoc 产物只为加载同为 ad-hoc 签名的 Sparkle
framework 添加 `disable-library-validation` 调试权限。
正式构建会在签名前移除非沙箱路径未启用的 Sparkle `Installer.xpc`、`Downloader.xpc`
及其 symlink，减少休眠代码和签名节点；`Updater.app` 与 `Autoupdate` 仍负责正常更新。

后续计划是不再拦截系统媒体键，而提供两个可选能力：仅当受控 DAC 是默认输出时，使用
Core Audio 事件监听把系统数字音量保持为 100%；使用用户自定义的普通全局快捷键调节
DAC 硬件音量。这样可以避免键盘全局监控权限，并为 App Sandbox 留出可行路径。沙箱迁移
仍须验证 USB entitlement 下的完整 IOHID 读写/拔插，以及 Sparkle sandbox XPC 更新；
在这些真机门禁通过前，正式产物继续保持非沙箱。具体边界、候选 entitlements 和验收矩阵
见
[`Documentation/Architecture.md`](Documentation/Architecture.md#多型号支持下的沙箱策略)。

UA1 II 的 HID 控制路径目前只在 Apple Silicon 真机完成过硬件回归。CI 在 `xcode-27`
ARM64 runner 编译并检查 App 和所有保留的 Sparkle 可执行文件同时包含 `arm64`、
`x86_64`，再由 `macos-26-intel` 启动同一个 DMG 中的 Intel 切片；在 Intel Mac 上连接
UA1 II 的真机回归仍是正式宣称该组合已验证前的最后一道门禁。

验证结果：

```bash
spctl -a -vvv -t exec dist/DACBar.app     # 应为 accepted
xcrun stapler validate dist/DACBar.app
```

## 许可证

DACBar 采用 [MIT License](LICENSE)。设备与协议名称的商标权归各自权利人所有。
