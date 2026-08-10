# 多型号设备架构

DACBar 是厂商无关的产品；当前发布版本仍只启用经过真机验证的 Shanling UA1 II。
厂商和型号名称只允许出现在具体设备 target、App 的组合根、对应测试及研究文档中。
把一个 Profile 加入组合根并不等同于宣称该型号可用；每个型号仍需在 macOS 上确认
描述符、传输权限和真实报文。

## Xcode App 与设备 Package 边界

```text
DACBar.xcodeproj
├── DACBar App target
│   └── App/：@main、SwiftUI、DeviceModel、composition root、Sparkle、资源
├── DACBarTests target
│   └── DACBarTests/：App 与业务层测试
└── local package dependency
    └── Packages/DACDevices/
        ├── DACDeviceKit：厂商无关 contracts
        └── ShanlingUA1II：profile + HID transport + wire codec
```

`DACBar.xcodeproj` 直接拥有唯一的 App target 与 App test target。App 的生命周期、界面、
业务模型、组合根、更新器和 App 资源都是该 target 的正常源文件，不存在为了启动 Xcode
而额外建立的 executable 壳，也不把 App 本身伪装成库产品。

设备领域独立放在嵌套的 `Packages/DACDevices/Package.swift` 中，只输出
`DACDeviceKit` 与 `ShanlingUA1II` 两个库产品。这样设备协议可用 `swift test
--package-path Packages/DACDevices` 独立验证，App 则使用 Xcode 的资源、Scheme、签名、
测试宿主和发布模型。两个设备库仍位于同一 package；只有当某个模块需要跨 App 复用、
独立发布或由不同团队维护时，才提取成外部 package。

## 当前冻结范围

当前唯一实现并启用的组合是 `hidService + hidReports + shanling.ua1-ii.hid`。代码中的
`usbRegistry`、`vendorControl`、`interruptEndpoints` 和 `hidFeatureInterrupt` 只是为
讨论未来型号保留的类型词汇，并没有对应的运行时 backend。它们不能用于判断某个型号
已经受支持，唯一依据是 `App/SupportedDevices.swift` 的组合清单。

在取得第二个型号并完成 macOS 真机调查前，不提前实现通用 USB discovery、bulk/vendor
transport、轮询器或状态缓存。这样可以避免把 Linux/libusb 的接口占用假设带进 macOS，
也避免抽象尚未出现的共同生命周期。

## 数据流

```text
SupportedDevices composition root
    ↓ registered DeviceProfile + Driver factory
DeviceRegistry
    ↓ USB/HID identity
DeviceWatcher → AttachedDevice(profile, location, registry generation)
                                  ↓
                             Driver factory
                                  ↓
            DriverDescriptor + Snapshot + Mutation
                                  ↓
                    @MainActor @Observable DeviceModel
                                  ↓
                      capability-driven SwiftUI
```

### Profile 与发现

`Packages/DACDevices/Sources/DACDeviceKit/DeviceProfile.swift` 定义稳定的 `ModelID`、`DriverID`、
USB/HID 匹配条件、发现方式、传输类型和验证状态。通用核心不枚举任何厂商或型号；
`Packages/DACDevices/Sources/ShanlingUA1II/ShanlingUA1II.swift` 声明 UA1 II profile，设备 target 通过
`DevicePlugin` 暴露 profiles、枚举和 factory；App 的 `SupportedDevices` 只组合要随
当前版本发布的 plug-ins。

HID watcher 的 matching dictionaries 由注册表生成，并与初始枚举使用同一套条件。
`AttachedDevice` 携带完整 Profile；选择持久化使用 `profile + locationID`，不会把同一
端口上的不同型号误认为同一个设备。`registryEntryID` 继续用于识别 USB reset 后的
新一代 service。

当前只有 `hidService` discovery backend。若某个型号只暴露 endpoint-zero vendor
control 或非 HID 接口，应新增独立的 USB registry discovery backend，而不是放宽
IOHID 匹配条件。

### Driver 与能力

`Packages/DACDevices/Sources/DACDeviceKit/DeviceDriver.swift` 是 App 与型号协议之间的边界：

- `Driver` 提供状态读取、语义写入、设备变化/确认/丢弃/移除事件；
- `DriverDescriptor` 声明设置、读回策略、确认策略和有限重试；
- `SettingDescriptor` 声明控件类型、范围、选项、分组和说明；
- `Snapshot` 与 `Mutation` 只使用逻辑值，不包含 report ID、命令字、偏移或校验和。

`Packages/DACDevices/Sources/ShanlingUA1II/UA1IIDriver.swift` 将逻辑设置映射到已经真机验证的
`ShanlingUA1II.Connection`。例如平衡的
有符号字节和屏幕偏移的 `+50` 只存在于 Driver/协议层；`DeviceModel` 与 SwiftUI 不
知道这些 wire 细节。

`UA1IIWireCodec` 是纯编解码边界：生成完整 41 字节输出报告，分类 9 字节状态页、ACK
和结束帧，并把捕获的四页状态合并到 `State`。它不依赖 IOHID、run loop 或 actor，因而
可直接用真机捕获帧覆盖畸形校验和、未知页和值域；`Connection` 仍保留已验证的 callback、
buffer ownership、transaction gate 与 pacing。

`readback` 与 `confirmation` 是 Driver 对外声明并自行兑现的协议语义，不是
`DeviceModel` 的分支开关。无论底层是完整读回、部分读回还是 write-only cache，
`Driver.read()` 都必须先合并为完整逻辑 `Snapshot`；无论确认来自设备 ACK、写后读回
还是传输完成，Driver 都必须转换成统一的 `onConfirmed` / `onDropped` 回调。这样
`DeviceModel` 不会逐渐长出型号或协议分支。

不同传输家族各自实现 Driver。不要直接复制 Linux/libusb 的 claim/detach 方案：
macOS 上是否能非独占访问、是否影响音频、是否需要 entitlement，必须逐型号验证。
等出现第二个确实共享 I/O 生命周期的 Driver 后，再抽取共同 Transport；现在保留
UA1 II 已验证的 callback、run-loop、buffer ownership 和 pacing 实现，避免为了抽象
改动硬件行为。

### Observation 与并发

`DeviceModel` 是唯一的 `@MainActor @Observable` reference model，App 根用 `@State`
持有并显式传给 SwiftUI。Driver、任务句柄和 watcher 使用 `@ObservationIgnored`；
纯 Profile、Descriptor、Snapshot 和 Mutation 都是 `Sendable` value types。

发布版的 `UpdateController` 是独立的 `@MainActor @Observable` Sparkle 包装器，也由
App 根用 `@State` 保持生命周期。它只投影 Sparkle 的 `canCheckForUpdates` KVO 状态，
使手动检查按钮在 updater 忙碌或尚未启动时正确禁用；controller 和 observation token
用 `@ObservationIgnored` 保持实现细节。后台授权、检查、下载和安装仍由 Sparkle 管理，
不进入设备状态模型。
App 与 Driver 分别持有自己的 String Catalog；Driver 先把本地化后的能力描述投影成
`SettingDescriptor`，SwiftUI 不包含型号专用文案。

Driver 目前为 `@MainActor`，因为 UA1 II 的 IOHID callback 与 AppKit event-tracking
run loop 已按此模型完成真机验证。纯编码、解码和能力表显式 `nonisolated`，不会把
不需要 UI actor 的计算错误地扩大隔离范围。

发布 App 为 Universal 2（`arm64 + x86_64`）。标准 GitHub-hosted `xcode-27` ARM64
runner 是 Swift 6.4 源码测试与唯一构建环境，并逐个检查 App 与 Sparkle 嵌套可执行文件的
两个架构切片。Xcode 27 不提供 Intel runner；`macos-26-intel` 不重新编译源码，而是下载
上述 job 生成的同一个 DMG，在 Intel CPU 上重新验证签名和 bundle 后实际启动 x86_64
切片。这样既保持工具链真相源唯一，也验证最终交付物而非另一份独立构建。

UA1 II 的实际 HID 读写目前只在 Apple Silicon 真机验证过。`.github/workflows/hardware.yml`
把它隔离到带 `DACBar-Hardware` 标签、连接真机的 self-hosted runner，并且只允许个人仓库
所有者从 `main` 手动触发；它不持有发布凭据，也不执行 PR 代码。Universal 2 与 Intel
启动验证仍不等同于 Intel + UA1 II 硬件验证。不得为两种 CPU 架构维护不同的协议或状态机
分支。

当前发布 App 采用 Developer ID + hardened runtime + 公证，但尚未启用 App Sandbox。
IOHID/IOKit 设备访问目前只在非沙箱模型下完成真机验证，Sparkle 也使用对应的非沙箱
安装路径。本地 ad-hoc 包为加载 ad-hoc Sparkle framework 临时关闭 library validation；
该 entitlement 不得进入 Developer ID 分发包。下面的沙箱设计仍是迁移提案，不代表
当前产物已经沙箱化。

非沙箱归档会在最终签名前移除 Sparkle 的 `Installer.xpc`、`Downloader.xpc` 及其框架
symlink。这两个服务只用于 Sparkle 的沙箱集成；当前更新链保留 `Updater.app`、
`Autoupdate` 和 Sparkle framework。产物校验同时要求 XPC 服务不存在、对应 Info.plist
开关未启用，避免发布休眠代码或形成配置与 bundle 不一致。

更新信任链同时要求 `SURequireSignedFeed` 与 `SUVerifyUpdateBeforeExtraction`：feed
签名覆盖内嵌发布说明，归档使用同一 Ed25519 密钥另行验证，App 则由 Developer ID、公证与
Gatekeeper 验证。自动检查不由 Info.plist 强制开启；Sparkle 的标准授权界面保存用户
选择。发布 job 在一次性 GitHub-hosted VM 的独立临时钥匙串中导入证书并保存公证
profile，不修改任何持久 runner；workflow 结束时仍显式清理，随后 VM 被销毁。持有
`contents: write` 的发布 job 只下载已通过 Intel 门禁的 DMG、校验和与 appcast，不接触
签名或公证 secrets。

### 多型号支持下的沙箱策略

DACBar 采用“保持可沙箱化、非沙箱作为当前发布默认值”的策略。设备已经通过协议与真机
验证，不代表它已经通过沙箱验证；两者必须分别记录。`SupportedDevices` 只决定当前版本
组合哪些设备 plug-in，不能隐式扩大 App entitlement，也不能把某个 backend 的沙箱结论
套用到另一种传输方式。

| 设备 backend | 可能需要的沙箱能力 | 接入与发布要求 |
|---|---|---|
| HID input/output/feature reports | `com.apple.security.device.usb` | 每个型号真机验证枚举、报告读写、异步 callback、拔插、睡眠唤醒和多设备；UA1 II 当前尚未做沙箱真机回归。 |
| USB control/vendor/bulk/interrupt | `com.apple.security.device.usb` | 即使使用公开 USB API，也要逐型号确认 interface ownership、IOUserClient 和 class driver 共存；不得假定 HID 的验证结果适用。 |
| USB serial | `com.apple.security.device.serial`，必要时再加 USB | 验证设备节点变化、独占策略、断线恢复和多设备身份；只在 backend 实际需要时加入 entitlement。 |
| Bluetooth | `com.apple.security.device.bluetooth` | 验证系统授权、重新连接和后台行为；不能为了预留未来型号提前扩大权限。 |
| 网络/Bonjour DAC | 通常为 `com.apple.security.network.client`；只有监听入站连接时才考虑 server | 明确发现与控制各自需要的网络方向，验证本地网络权限、地址变化和不可达恢复。 |
| DriverKit / USBDriverKit | System Extension、DriverKit transport 和 user-client 等受限 entitlements | 作为独立受签名 target 和发布组件设计，并取得 Apple 授权；设备 package 中增加一个 Driver factory 不能替代这些要求。 |

当前不支持运行时下载或加载第三方设备 plug-in。设备模块必须在构建时静态组合并随 App
共同签名，这既保持 library validation，也避免让沙箱边界变成任意代码加载机制。如果未来
确实要开放第三方 plug-in，需要单独设计扩展进程、协议、签名信任和版本兼容，不能直接把
现有 Swift package 当作运行时插件系统。

新增 backend 时必须在研究文档或 Profile 附属记录中分别标注：协议验证状态、非沙箱真机
状态、沙箱兼容状态、所需 entitlement 和已知限制。沙箱兼容状态至少分为：`未验证`、
`已验证`、`不兼容（原因）`。如果实现依赖 IOKit temporary exception、私有 API、任意文件
访问、动态代码或只为绕过沙箱而存在的 privileged helper，该 backend 不得推动正式版本
切换为沙箱；应继续使用经过公证的非沙箱 Developer ID 发行方式，或重新设计 backend。

只有同时满足以下条件，才能提议把正式 Developer ID 版本切换为沙箱：

1. 当前所有启用型号都通过沙箱真机回归，且至少覆盖 HID 和第二种实际传输 backend；
2. 只使用稳定、公开且用途明确的 entitlement，不依赖 IOKit/file temporary exception；
3. Sparkle 已恢复并正确签名 Installer XPC，且旧的非沙箱版本能够更新到沙箱版本；
4. 系统音量保护、全局快捷键、默认输出切换和睡眠唤醒通过沙箱验收；
5. CI 同时构建非沙箱迁移来源与沙箱候选产物，并校验主 App、XPC/System Extension 各自
   的签名和最小 entitlement；
6. 新型号接入清单明确规定：任何新增 backend 都必须重新评估沙箱发布结论。

若某个重要型号只能在非沙箱模型下可靠工作，DACBar 主版本应继续非沙箱发布。只有在存在
明确的 Mac App Store 产品需求时，才考虑另建沙箱变体；该变体只能包含已验证的设备子集，
移除 Sparkle，并接受与直接发行版不同的能力矩阵和发布流程。

### 全局快捷键与拟议的系统音量保护

硬件音量快捷键已经实现。`GlobalHotKeyController` 通过 Carbon
`RegisterEventHotKey` 只注册用户指定的两个组合键，而不使用 `NSEvent` 全局键盘监控、
`CGEventTap` 或系统媒体键拦截，因此正常路径不申请 Accessibility 或 Input Monitoring
权限。默认组合为 `⌃⌘↑` / `⌃⌘↓`，默认关闭；设置窗口负责启用、录制、冲突状态和恢复
默认值。

快捷键的路由真相源是 `DeviceModel.selected` 所代表的当前控制 session。播放器使用独占
模式时，macOS 默认输出可能仍是另一台设备，因此 Core Audio 默认输出不能作为快捷键的
前置条件或目标选择依据。所选设备不在 ready 状态时操作 fail closed；多设备场景沿用面板
中的显式选择。快捷键最终进入与音量滑块相同的 capability-driven mutation 路径，从而
复用 Driver 的范围、步长、合并、USB pacing、确认和有限重试语义。

系统媒体键仍完全由 macOS 处理，不会直接改变 DAC 的硬件音量。“系统数字音量保持
100%”尚未实现，且必须作为与硬件快捷键解耦的未来功能重新设计。若以后通过 Core Audio
property listener 被动监听音量和静音属性，不能假定受控 DAC 同时是系统默认输出；需要
明确定义独占模式、设备身份映射、瞬时音量跳变和多设备 fail-closed 行为。该功能应由 App
层独立 controller 负责 callback 生命周期与隔离，不放入设备 wire protocol，也不得改变
上述快捷键路由规则。

沙箱候选配置至少包括：

- `com.apple.security.app-sandbox = true`；
- `com.apple.security.device.usb = true`，用于现有 USB/HID 控制；
- `com.apple.security.network.client = true`，用于 appcast 与更新下载；
- Sparkle sandbox installer 所需的 XPC service、Info.plist 配置和受限 Mach lookup
  entitlement。不得把本地 `disable-library-validation` 调试例外带入分发包。

迁移只有在以下验收全部通过后才能成为发布默认值：

1. 沙箱产物能够枚举、读写、连续调节并被动侦测 UA1 II 拔插；
2. `IOHIDDeviceSetReportWithCallback` 的完成、ACK、pacing 和重试语义与非沙箱构建一致；
3. 默认输出切换、音量回写、静音、睡眠唤醒及多台同型号设备均 fail safe；
4. App 在前台、后台和全屏 App 场景下都能注册、释放并响应用户快捷键；
5. 旧的已签名版本可以通过 Sparkle XPC 路径更新到新的已签名、公证版本；
6. 最终签名确实包含预期 sandbox/USB/network entitlements，且 Console 中没有 sandbox
   violation。

直接 Developer ID 分发可以同时使用 App Sandbox 和 Sparkle。若未来提供 Mac App Store
变体，则必须使用独立发布配置、移除 Sparkle 自更新入口，并由 Mac App Store 分发更新。
参考：[Apple USB entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.device.usb)、
[Apple App Sandbox](https://developer.apple.com/documentation/security/app-sandbox)、
[Apple temporary exception entitlements](https://developer.apple.com/library/archive/documentation/Miscellaneous/Reference/EntitlementKeyReference/Chapters/AppSandboxTemporaryExceptionEntitlements.html)、
[Apple DriverKit entitlements](https://developer.apple.com/documentation/driverkit/requesting-entitlements-for-driverkit-development)、
[Sparkle sandboxing](https://sparkle-project.org/documentation/sandboxing/)。

## 添加型号

1. 在 macOS 上采集 USB/HID 描述符，确认 VID/PID、产品名、interface、usage、端点
   类型和 report sizes。
2. 为厂商/型号新增独立 target（或加入已有的同厂商 target），只依赖
   `DACDeviceKit`；在其中定义 `DeviceProfile` 和稳定的 `DriverID`。共享 PID 必须提供
   可区分的产品名，未真机验证时标记 `experimental`。
3. 若 discovery backend 不同，先实现并测试对应的被动插拔通知。
4. 在设备 target 内新增 Driver/协议实现；所有 wire 编码、值域验证、readback/ACK/
   pacing 语义留在 Driver 内。
5. 用 `SettingDescriptor` 描述该型号能力。正常情况下不应修改 `DeviceModel` 或
   `ContentView`。
6. 用捕获或重建的报文测试解析、写入编码、值域和固件变体；真机测试默认保持 opt-in。
7. 分别记录非沙箱与沙箱兼容状态、所需 entitlement 和限制；没有沙箱真机证据时必须
   标记为“未验证”，不能从同类 transport 推断。
8. 真机验证插拔、首次读取、连续拖动、机身按键同步、多设备切换和恢复原值后，才在
   `SupportedDevices` 组合根注册该 Profile 与 factory。

## 验证命令

```bash
swift build --package-path Packages/DACDevices \
  --scratch-path .build/package \
  -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors
swift test --package-path Packages/DACDevices \
  --scratch-path .build/package \
  -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors
xcodebuild -project DACBar.xcodeproj -scheme DACBar \
  -disableAutomaticPackageResolution \
  -destination "platform=macOS,arch=$(uname -m)" test
# build.sh 会编译并校验 arm64 与 x86_64 两个切片
./build.sh release

# 明确选择并连接真机后才运行；多台设备必须指定 location ID
SHANLING_HARDWARE_TESTS=1 \
SHANLING_HARDWARE_LOCATION_ID=0x01100000 \
swift test --package-path Packages/DACDevices --scratch-path .build/package --no-parallel

# 独立的 completion 间隔测量，不改变正式 130ms
SHANLING_HARDWARE_TESTS=1 \
SHANLING_HARDWARE_LOCATION_ID=0x01100000 \
SHANLING_SWEEP_INTERVALS=130,128,127,126 \
SHANLING_SWEEP_COUNT=80 \
swift test --package-path Packages/DACDevices --scratch-path .build/package --no-parallel \
  --filter HardwareIntegrationTests.completionIntervalSweep
```
