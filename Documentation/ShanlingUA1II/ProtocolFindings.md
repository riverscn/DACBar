# 山灵 UA1 II 厂商协议 —— 逆向记录

对山灵 UA1 II（`20B1:3033`）厂商控制通道的逆向。协议七个命令字全部在真机上
双向验证过。

**下面每一条都有实机报文佐证，不是推测。**

## 访问方式：普通 HID，无需特权

厂商控制通道挂在接口 2 的 HID 上。macOS 的 HID 驱动允许非独占访问，所以读写
都不需要抢占它、不需要 root，也不影响音频播放。

```swift
let manager = IOHIDManagerCreate(kCFAllocatorDefault, 0)
IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey: 0x20B1,
                                        kIOHIDProductIDKey: 0x3033] as CFDictionary)
IOHIDManagerOpen(manager, 0)
let device = (IOHIDManagerCopyDevices(manager) as! Set<IOHIDDevice>).first!

IOHIDDeviceRegisterInputReportCallback(device, buffer, 64, callback, context)
let runLoop = CFRunLoopGetCurrent()
let tracking = CFRunLoopMode(
    rawValue: "NSEventTrackingRunLoopMode" as CFString)
CFRunLoopAddCommonMode(runLoop, tracking)
IOHIDDeviceScheduleWithRunLoop(device, runLoop,
                               CFRunLoopMode.commonModes.rawValue)
```

连 `IOHIDDeviceOpen` 都不必调。等价地，Node 的 `node-hid`、Python 的 `hidapi`
也能工作。

### ⚠️ 缓冲区必须自带 report ID

这是整条通道能否使用的分水岭。实测三种组合：

| `reportID` 参数 | 缓冲区 | 结果 |
|---|---|---|
| `0` | 41 字节，首字节 `0x01` | ✅ 生效（本项目用法） |
| `1` | 41 字节，首字节 `0x01` | ✅ 生效（hidapi 用法） |
| `1` | 40 字节，不含 ID | ❌ 无效 |

**决定因素是缓冲区内容，不是 `reportID` 参数。** IOKit 把缓冲区原样发往中断
OUT 端点 `0x03`，不会替你补上 ID；传 40 字节时设备收到的报文以 `0xAA` 开头、
没有 report ID，固件直接丢弃。三种情况 `SetReport` 都返回 `0x00000000`。

（macOS 对第三种情况具体做了什么没有进一步查证——只知道设备没有采纳。）

**弄错的代价极大**：写入无效、查询也没有回音，两个方向同时哑掉，很容易被解读成
「这条通道不通」。

### ⚠️ 每个请求回两条报文

数据帧之后紧跟一条结束帧（`01 00 00 …`）。**取到数据帧后必须把结束帧也收掉**，
否则下一个请求会先读到这条残留，真回复整体延迟一条，从第二个请求起全部超时——
看起来就像设备只返回空页。

连读四页约 1 秒（每页含约 120ms 排空）。

### 设备会主动上报

机身按键改动设置时，设备不请自来地发一条 `0x10` 应答帧：

```
01 55 AA 10 01 14 ...   命令 0x01（音量）值 20
01 55 AA 10 01 15 ...   命令 0x01（音量）值 21
```

所以界面不需要轮询也能与机身保持同步。

设备存在性是另一层。最初的 watcher 使用 USB device service 的 first-match / terminated
通知，但复合设备的 USB 节点与稍后出现的 HID service 生命周期并不一致，重新插回时
可能无法推动 HID 模型重连。现在由长期存活的 `IOHIDManager` 直接注册 device matching
和 removal callback，匹配条件与控制连接完全相同；只有 callback 到来时才合并读取一次
快照，没有周期轮询。

真机重插日志显示 matching callback 后约 500ms 的第一次状态查询仍可能 timeout：HID
service 已枚举不等于固件端点已经 ready。初始化读取因此在原 connection/session 内做
最多两次退避重试（600ms、1s），期间保持“正在读取”；任何 removal 或 generation 变化
都会取消它，只有连续三次读取失败才向用户显示错误。

### 写入节奏

同步 `IOHIDDeviceSetReport` 的边界测试中，连续写入间隔 100ms 会丢、150ms 与
200ms 可靠；按 10ms 步进、每档 30 条细测时，120ms 只有 15/30 落地，130ms 起
30/30。切换到 `IOHIDDeviceSetReportWithCallback` 后一度观察到 nominal 130ms、
150ms 乃至 200ms 仍有丢包，根因不是异步 API，而是节流从函数调用开始计时：
IOKit 的异步排队时间会缩短两次实际输出之间的间隔。现在从上一条输出的完成回调
开始等待 130ms；三轮约 180 次 UI 更新的真机压力测试没有出现应答超时。单次同步
`IOHIDDeviceSetReport` 往返（查找+发送）约 45ms。

随后直接对异步 API 做了 completion-to-next-send 阶梯测量，每档交替写入相邻亮度并
以 `0x10` ACK 和最终读回为准；所有 SetReport completion 都成功，但低于边界后 ACK
开始丢失：

| completion 后间隔 | ACK |
|---:|---:|
| 130ms | 120/120 |
| 129ms | 80/80 |
| 128ms | 120/120 |
| 127ms | 80/80 |
| 126ms | 73/80 |
| 125ms | 34/40 |
| 122ms | 34/40 |
| 120ms | 29/40 |

这台设备的实测台阶约在 127ms，但 127 与失败档只差 1ms，且样本只有一台设备、一个
固件，因此不具备工程余量；正式值继续保持 130ms。测试入口为 opt-in 的
`HardwareIntegrationTests.completionIntervalSweep`，每档结束后切回正式间隔并恢复
原亮度。

真实 SwiftUI 滑块还暴露了测试中没有的 run-loop 差异：按住鼠标时 AppKit 运行
`NSEventTrackingRunLoopMode`，只在 default mode 调度 IOHIDDevice 会让输入报告在
整段拖动期间停摆，输出 completion 仍成功但所有 ACK 超时。连接现在显式把 tracking
mode 加入当前 run loop 的 common 集合，再只 schedule 一次 common mode。真机回归
测试在只运行 tracking mode 时改变并恢复音量，修复前失败、修复后通过。

## 传输层

| | |
|---|---|
| 接口 | 2（HID class） |
| 写 | 中断 OUT `0x03`，**41 字节** = report ID `0x01` + 40 字节载荷 |
| 读 | 中断 IN `0x82`，**9 字节** |

**每个请求会产生两条回复**：数据帧 + 一条 `01 00 00 00 …` 结束帧。
读之前必须先排空 IN 端点，否则回复会整体延迟一条，看起来像「空页」。

## 请求格式（40 字节载荷）

```
[0..2] = AA 55 10        魔数
[3]    = command
[4]    = value
[5]    = 01
[6..38]= 00
[39]   = ~sum(payload[0..38]) & 0xFF
```

## 回复格式（9 字节）

```
[0]    = 01              report ID
[1..2] = 55 AA           魔数（注意与请求相反）
[3]    = 页 ID / 0x10=写应答
[4..7] = 数据
[8]    = ~sum(frame[1..7]) & 0xFF
```

四页的校验和都已逐条验算通过。

## 状态页

发 `command=0xFF`、`value=页号 0..3`，回复的 `[3]` 是 `0x20 + 页号`：

| 请求 | 回复页 | 内容 | 实测样本 |
|---|---|---|---|
| `FF 00` | `0x20` 版本 | `[4..6]` = 主.次.修订 | `01 55 AA 20 01 00 00 00 DF` → v01.00.00 |
| `FF 01` | `0x21` **音频** | `[4]`音量 `[5]`增益 `[6]`滤波器 `[7]`平衡 | `01 55 AA 21 1B 00 01 00 C3` → 音量 27 |
| `FF 02` | `0x22` 显示 | `[4]`亮度 `[5]`息屏 `[6]`方向 | `01 55 AA 22 06 00 00 00 D8` → 亮度 6 |
| `FF 03` | `0x23` 偏移 | `[4]` − 50 = 屏幕偏移 | `01 55 AA 23 34 00 00 00 A9` → 偏移 2 |

音频页 `[4] = 0x1B = 27` 与机身屏幕显示的数字**完全一致**，这是协议解对了的
决定性证据。

## 写命令（已验证）

写入后设备回一条 `[3]=0x10` 的应答，回显 command 和 value：

| command | 作用 | 验证过程 |
|---|---|---|
| `0x01` | 音量 | 写 `01 28`(40) → 音频页 `[4]` 从 `1B` 变 `28` ✓ |
| `0x02` | 增益 | 写 `02 01` → `[5]` 从 `00` 变 `01` ✓ |
| `0x03` | 滤波器 | 写 `03 03` → `[6]` 从 `01` 变 `03` ✓ |

其余命令字后来也逐个验证通过（`sudo ./.build/tools/capture verify`，写入后读回比对、
自动恢复原值）：

| command | 作用 | 编码 |
|---|---|---|
| `0x04` | 声道平衡 | **有符号字节**，−12…12 |
| `0x06` | 亮度 | 0–10 |
| `0x07` | 屏幕方向 | 0–3 |
| `0x09` | 息屏时间 | 秒，0 = 常亮 |
| `0x15` | 屏幕偏移 | **wire 值 = 逻辑值 + 50** |

**上游文档列出的命令字全部正确**，包括那个 +50 偏移。

## 设备标识

| 项 | 值 |
|---|---|
| idVendor | `0x20B1` (XMOS Ltd) |
| idProduct | `0x3033` |
| bcdDevice | `0x0201` |
| bDeviceClass | `0xEF` / `0x02` / `0x01` (Misc, IAD) |
| bcdUSB | `0x0200` (High Speed) |
| 供电 | Bus powered, 90 mA |

VID 属于 XMOS，说明是 XMOS 方案（山灵在 UA 系列上常用 XU316 一类）。

## 接口拓扑（1 个配置，wTotalLength = 343）

| 接口 | 类 | 说明 | 端点 |
|---|---|---|---|
| 0 | `0x01/0x01/0x20` | Audio Control (UAC2) | — |
| 1 | `0x01/0x02/0x20` | Audio Streaming (UAC2), alt 0–4 | ISO OUT `0x01` + 反馈 IN `0x81` |
| 2 | `0x03/0x00/0x00` | **HID（厂商控制通道）** | INT IN `0x82` (64B) + INT OUT `0x03` (64B) |

**没有 vendor-specific (class `0xFF`) 接口。** 这一点决定了 WebUSB 的可行性，见下。

### AudioControl 单元拓扑

```
Input Terminal 1 (USB Streaming)
        ↓
Feature Unit 3  ← 音量 / 静音都在这里
        ↓
Output Terminal 4 (Speaker, 0x0301)

Clock Source 5 (internal programmable, 频率 host-programmable)
```

Feature Unit 3 的 `bmaControls`：

| 通道 | 值 | 含义 |
|---|---|---|
| Master (0) | `0x0000000F` | Mute 可读写 + Volume 可读写 |
| Ch1 / FL | `0x0000000C` | Volume 可读写 |
| Ch2 / FR | `0x0000000C` | Volume 可读写 |

即标准 UAC2 通路可调：**主音量、主静音、左右声道独立音量（可做平衡）**。

### AudioStreaming alt setting

| alt | 格式 | bSubslotSize / bBitResolution |
|---|---|---|
| 0 | 零带宽 | — |
| 1 | PCM | 2 / 16 bit |
| 2 | PCM | 3 / 24 bit（当前激活） |
| 3 | PCM | 4 / 32 bit |
| 4 | **RAW_DATA**（`bmFormats = 0x80000000`，原生 DSD） | 4 / 32 bit |

CoreAudio 实测支持采样率（15 档）：

```
32000 44100 48000 64000 88200 96000 128000
176400 192000 256000 352800 384000 512000 705600 768000
```

三种位深 × 15 档 = 90 个 physical format。最高 **768 kHz / 32 bit**。

## HID 控制通道（关键发现）

接口 2 的 HID Report Descriptor（76 字节）：

```
05 01        Usage Page (Generic Desktop)
09 80        Usage (System Control)          ← 被当作通用数据管道用
A1 01        Collection (Application)
  15 00 25 FF  Logical Min 0 / Max 255
  85 01          Report ID 1
  95 08 75 08    Report Count 8, Report Size 8
  81 03          Input  (Const,Var,Abs)      ← 8 字节 IN
  09 80 15 00 25 FF
  75 08 95 28    Report Size 8, Report Count 40
  91 06          Output (Data,Var,Rel)       ← 40 字节 OUT
C0
05 0C        Usage Page (Consumer)
09 01        Usage (Consumer Control)
A1 01        Collection (Application)
  85 02          Report ID 2
  09 E9 Volume+   09 EA Volume-   09 CD Play/Pause
  09 B5 Next      09 B6 Prev      09 B3 FFwd   09 B4 Rewind
  81 02          Input (7 bits + padding)
C0
```

对应 IOKit 报告的 `MaxInputReportSize = 9`（8+ID）、`MaxOutputReportSize = 41`（40+ID），互相印证。

结论：

- **Report ID 2** = 机身实体按键（音量增减、播放暂停、上下曲、快进快退）上报，只进不出。
- **Report ID 1** = 厂商私有通道，**40 字节 OUT / 8 字节 IN**。增益模式、数字滤波器、灯效、显示等设置几乎肯定走这里。**字节格式未公开。**

## 其它接入方式：都不通（已实测）

以下路径都试过，结论是**只有接口 2 的中断端点接收命令**。

### EP0 上的 HID 类请求 —— 设备 STALL

```
SET_REPORT (bmRequestType=0x21 bRequest=0x09 wValue=0x0201 wIndex=2)
    -> 0xE000404F  kIOUSBPipeStalled
```

数据带不带 report ID、`wIndex` 用 2 还是 0，一律 STALL。山灵 UA Mini 走的是
这种方式，UA1 II 不支持。

### EP0 厂商通道 —— 存在但是哑缓冲

山灵其他型号走 EP0（`wIndex=0x09A0`、`bRequest=0xA0/0xA1`）。`USBDeviceOpen`
能成功、请求也不 STALL，但对无效命令 `11 22 33 44 55 66 77` 原样回显——存什么
读什么，没有命令处理。UA1 II 不走这条路。

### 抢占接口 2 —— 卡在所有权，不是权限

```
当前占有者: AppleUserUSBHostHIDDevice
USBInterfaceOpen      -> 0xE00002C5  kIOReturnExclusiveAccess
USBInterfaceOpenSeize -> 0xE00002C5  kIOReturnExclusiveAccess
```

seize 的机制是向当前占有者发 `kIOMessageServiceIsRequestingClose`，由占有者
自己决定放不放手。Apple 的 HID 驱动不实现自愿关闭，所以**任何 uid 都拿不到，
root 也不例外**。设备只有 1 个配置，也没法用 `SetConfiguration` 甩掉它。

这解释了为什么 WebUSB / libusb 这类需要认领接口的方案在 macOS 上行不通。
而 HID 路径根本不需要认领接口，所以不受影响。

### 设备捕获（root）—— 可行但不必要

`USBDeviceReEnumerate(kUSBReEnumerateCaptureDeviceMask)` 会重新枚举整个设备、
让所有内核驱动脱离，之后可直接读写接口 2 的中断端点。IOUSBLib.h 写明 **root
权限可替代 `com.apple.vm.device-access` 权限**。

代价是它会一并终止 `usbaudiod`，**音频中断 2–3 秒**。既然 HID 路径读写都通，
App 不再使用这条路；[tools/capture.c](../../tools/capture.c) 仍走它，作为独立于
App 的诊断工具。

用它时有两个 API 陷阱：`ReadPipeTO`/`WritePipeTO` 文档写明只支持 BULK，喂给
中断管道返回 `kIOReturnBadArgument`，必须用不带 `TO` 的版本；而同步 `ReadPipe`
在设备不回时会永久阻塞，要用 `ReadPipeAsync` + 有界 CFRunLoop + 超时
`AbortPipe`。

## 诊断时的两个陷阱

### 「设备有回应」不等于「设备听懂了」

发四种内容做对照，内核 `InputReportCount` 一律 +1：

| 发送内容 | 计数 |
|---|---|
| 合法读请求 | +1 |
| 校验和故意写错 | +1 |
| 全 `0xFF` 垃圾 | +1 |
| 全 `0x00` | +1 |

`IOHIDDeviceGetReport` 读回的更是逐字镜像：

```
发 DE AD BE EF …  ->  读回 DE AD BE EF 00 00 00 00 00
```

这是 macOS HID 栈的输出缓存在回显，与固件是否处理无关。**判断命令是否生效，
只能靠读回状态页确认数值真的变了。**

### 传输层不通时，看起来像协议错

早期曾穷举六种帧对齐/编码组合找「协议映射错误」——协议一直是对的，是
`reportID` 参数用错导致报文没送到命令处理器。**在确认传输层通之前，不要
去调协议细节。**

## 浏览器 API 可行性

> **2026-08-08 对着当前 Chromium 主干复查，结论不变。**
>
> 这里的「不可行」和「设备不支持」是两回事：**是 Chromium 有意拦截，不是系统
> 做不到**。同一台机器、同一个 report ID 1，原生代码收发自如。依据是下面引用的
> 源码，可自行复查。

### WebUSB —— 不可行

两个独立的原因，任一都足以否决：

1. **设备没有 vendor-specific 接口。** 只有 audio (`0x01`) 和 HID (`0x03`) 两类，而 Chromium 的 WebUSB 对这些「受保护类」拒绝 `claimInterface()`。即使 `requestDevice()` 成功拿到句柄，也永远认领不了接口，发不出任何传输。
2. **macOS 上三个接口已被内核驱动独占。** ioreg 显示接口 0/1 的 `UsbExclusiveOwner` 是 `usbaudiod`，接口 2 是 `AppleUserUSBHostHIDDevice`。macOS 不像 Linux 那样允许 detach kernel driver。

### WebHID —— 同样不可行（已核实 Chromium 源码）

HID 才是对的浏览器 API，但**恰好卡在保护名单上**。

判定逻辑在 `services/device/public/cpp/hid/hid_report_utils.cc` 的 `IsAlwaysProtected()`
（注意：旧路径 `hid_usage_and_page.cc` 在 2023 年后已不存在）：

```cpp
  if (usage_page != mojom::kPageGenericDesktop) {
    return false;
  }
  ...
  if (usage >= mojom::kGenericDesktopSystemControl &&
      usage <= mojom::kGenericDesktopSystemWarmRestart) {
    return true;
  }
```

`hid.mojom` 里的常量值：

| 常量 | 值 |
|---|---|
| `kPageGenericDesktop` | `0x01` |
| `kPageConsumer` | `0x0C` |
| `kGenericDesktopSystemControl` | `0x80` |
| `kGenericDesktopSystemWarmRestart` | `0x8f` |

即 Generic Desktop 的 **usage `0x80`–`0x8F` 无条件被保护**（三种报告类型全拦，没有 mouse/keyboard 那种 `kFeature` 例外）。本机厂商通道的顶层 usage 正是 `0x01`/`0x80`，**落在区间最底端**。

具体行为是**过滤报告，而非隐藏设备**：

1. 选择器里设备照常出现（`hid_chooser_controller.cc` 只按 VID/PID blocklist 和 FIDO 过滤）。
2. `HidService::RemoveProtectedReports()` 把 System Control collection 整个剥掉。因为 Consumer collection 还在，`collections` 非空，设备仍会由 `requestDevice()` 返回 —— 但里面只剩 Report ID 2。
3. `sendReport(1, ...)` → **`NotAllowedError: Failed to write the report.`**；Report ID 1 的输入报告被**静默丢弃**，`inputreport` 事件永不触发，也不报错。

对照之下，Consumer Control（`0x0C`/`0x01`）**不在保护名单**——`usage_page != kPageGenericDesktop` 就直接 `return false` 了。所以 WebHID 能拿到的恰恰只有那个只读的按键上报，唯一有用的 40 字节通道被拦死。

网页侧没有绕过手段：

- `--disable-hid-blocklist` 管的是另一套 VID/PID 名单，对 always-protected 路径无效
- WebHID 没有 WebUSB `usb-unrestricted` 那样的 Isolated Web App 逃生舱
- mojo 层的 `HidManager.Connect` 确实有个 `allow_protected_reports` 参数
  （「true 时该连接豁免 HID blocklist」），但那是内部服务接口；WebHID 的 JS API
  `HIDDevice.open()` 不接受任何这类参数，网页无从设置

> 附带一提：如果能改固件描述符，把厂商通道的顶层 usage 换成 vendor-defined page（`0xFF00`+），WebHID 就完全放行——厂商页不在任何保护列表里。

### 两条容易想到的退路，也都堵死了

**Chrome 扩展的 `chrome.hid`** —— 不行。`extensions/browser/api/hid/hid_device_manager.cc` 引用的是**同一个** `IsAlwaysProtected`：

```cpp
using ::device::IsAlwaysProtected;

// Return true if all reports in `device` with `report_id` are protected.
// Protected report IDs are not exposed in the API.
bool IsReportIdProtected(...)
```

扩展 API 和 WebHID 共用一套判定，Report ID 1 照样被过滤掉。

**Isolated Web App + `usb-unrestricted`** —— Chromium 这一层确实会放行。`web_usb_service_impl.cc`：

```cpp
  if (is_usb_unrestricted) {
    classes.clear();
  }
```

条件是 `kUnrestrictedUsb` feature 打开 + 权限策略里有 `kUsbUnrestricted` + `HasIsolatedContextCapability()`。但两个问题：IWA 是签名安装的 bundle，不是普通网页；而且**在 macOS 上仍然没用**——接口 2 被 `AppleUserUSBHostHIDDevice` 内核独占，Chrome 无法夺取。Linux 上 Chrome 能 detach 内核驱动，理论上这条路通。

### 原生方案 —— 已验证可用

见开头「访问方式」。HID 允许非独占打开，这是它和 audio 接口的关键区别；
Node 的 `node-hid`、Python 的 `hidapi` 同样可用。

## iOS / iPadOS 可行性

> **2026-08-08 查证。** macOS 那套方法在这里直接失效——**IOKit / IOHIDManager
> 不对第三方 App 开放**。这不是参数或用法问题，是框架层面就没有。

| 路径 | 可用性 |
|---|---|
| `IOHIDManager`（macOS 版所用） | ❌ IOKit 不开放给第三方 App |
| HIDDriverKit | ❌ Apple 明确说 iPadOS 上没有 |
| **USBDriverKit dext** | ⚠️ 仅 **M1 及以后的 iPad**，需 DriverKit 权限 |
| ExternalAccessory | ❌ 需 MFi 认证，UA1 II 不是 MFi 设备 |

Apple 工程师给出的唯一方案是自己写 USBDriverKit dext：

> 你可以用 USBDriverKit 检测自己的设备，自己写读写例程——通常就是控制管道写入
> 和中断管道读取。如果设备不算特别复杂，这比走 EA 简单，也不用处理 MFi 授权。
>
> —— [Apple Developer Forums #743193](https://developer.apple.com/forums/thread/743193)

对本设备而言，"自己写读写例程"并不难，协议已经全部摸清。**卡点在权限**：dext
要认领接口 2，就必须在匹配阶段赢过系统的 HID 驱动，这需要 Apple 授予的
DriverKit 权限。以个人身份、非厂商的立场，这条路与 macOS 上的 dext 方案同样
难走通，而且多两个硬限制：**只有 M1+ 的 iPad，iPhone 一概不行**。

### 对照：Android 可以

官方的 Eddict Player 就是这么工作的——Android 把 USB host API 开放给普通应用，
`UsbManager.claimInterface(force = true)` 用户授权一次即可，还只踢掉目标接口的
驱动、不影响音频。

**同一个设备、同一套协议，差别全在平台策略**：这和浏览器那节是同一类结论——
不是技术做不到，是有人明确决定不开放。

## 已有逆向资料（关键发现）

搜索引擎完全不索引，只能通过 GitHub API 找到：

**[pryid/shanling-control](https://github.com/pryid/shanling-control)** — 0BSD，Python/GTK4，建于 2026-07-26，0 star。
协议来自对 Eddict Player APK 的反编译，[PROTOCOL.md](https://github.com/pryid/shanling-control/blob/main/PROTOCOL.md) 有说明。
`device_registry.py` 里**明确列了 UA1 II / PID `0x3033`**（标记 `experimental=True`）。

### 它给出的 UA1 II 报文格式

`drivers/bulk41.py` 的 `_packet41()`：

```python
packet = bytearray(41)
packet[1] = 0xAA; packet[2] = 0x55; packet[3] = 0x10
packet[4] = command & 0xFF
packet[5] = value & 0xFF
packet[6] = 1
packet[40] = (~(sum(packet[:40]) & 0xFF)) & 0xFF
packet[0] = 1   # 校验和先按 byte0=0 算，之后才置 1
```

**这 41 字节和我实测的描述符严丝合缝**：

| 仓库 | 本机描述符 |
|---|---|
| 41 字节写 | `MaxOutputReportSize = 41`（Report ID + 40 字节） |
| `packet[0] = 1` | Report ID **1** |
| 9 字节读 | `MaxInputReportSize = 9`（Report ID + 8 字节） |
| 校验和按 `byte0=0` 计算 | 因为 byte 0 是 Report ID，不属于 40 字节载荷 |

也就是说，这就是个标准的 hidapi 写缓冲区。用载荷视角重写更清楚——40 字节 HID Output Report：

```
payload[0..2]  = AA 55 10        魔数
payload[3]     = command
payload[4]     = value
payload[5]     = 01
payload[6..38] = 00
payload[39]    = ~sum(payload[0..38]) & 0xFF     一字节反码校验和
```

### UA1 II 命令字

| 命令 | 值 | 范围 |
|---|---|---|
| volume | 1 | 0–99 |
| gain | 2 | 0 / 1 |
| filter | 3 | 0–4（ESS：线性快 / 线性慢 / 最小快 / 最小慢 / NOS 旁路） |
| balance | 4 | −12…+12（有符号字节） |
| brightness | 6 | 0–10 |
| orientation | 7 | 0–3 |
| screen_timeout | 9 | — |
| screen_offset | 21 | 0–10（写时 +50） |

### 读回状态

发 command `0xFF`、value = 页号 `0..3`，每次返回 9 字节，`frame[3]` 是页 ID：

| 页 | 内容 |
|---|---|
| 32 | 固件版本 → `frame[4:7]` 格式化为 `%02X.%02X.%02X` |
| 33 | 音频 → `[4]`音量 `[5]`增益 `[6]`滤波器 `[7]`平衡（有符号） |
| 34 | 显示 → `[4]`亮度 `[5]`息屏时间 `[6]`方向 |
| 35 | 偏移 → `[4] − 50` = 屏幕偏移 |

页间隔 15 ms，写后 25 ms。

### ⚠️ 该仓库对 UA1 II 有一处确定的错误

它把接口 2 当**批量端点**打开：

```python
self.transport = ClaimedEndpointTransport(
    detected, (2,), endpoint_type=usb.util.ENDPOINT_TYPE_BULK, timeout_ms=2000)
```

但本机描述符明确显示接口 2 的两个端点是**中断**端点，不是批量：

```
07 05 82 03 40 00 0a   →  EP 0x82 IN,  bmAttributes=0x03 (Interrupt), 64B
07 05 03 03 40 00 0a   →  EP 0x03 OUT, bmAttributes=0x03 (Interrupt), 64B
```

`ENDPOINT_TYPE_BULK` 匹配不到任何端点，这段代码在 UA1 II 上会直接找不到端点而失败。
正确做法是中断端点。

作者在 [AUDIT.md](https://github.com/pryid/shanling-control/blob/main/AUDIT.md) 里说明
只有 UA4 在真机上验证过，其余型号（含 UA1 II）未经硬件测试。

> **本项目已在 UA1 II 真机上补上这个验证**：除端点类型这一处外，
> 报文格式、校验和、页布局、命令字全部正确。详见文首「已确认的厂商协议」。

### 同族旁证

- **Moondrop Dawn** 系列（[frahz/mdrop](https://github.com/frahz/mdrop)）用的是 EP0 厂商请求，`wIndex=0x09A0`、`bRequest=0xA0/0xA1`、7 字节包，命令编号 `01`=滤波器 `02`=增益 —— 和山灵老型号的 `C7 A5` 协议**同一套**，只有魔数差一个字节（`C0 A5` vs `C7 A5`）。说明这是共用的 ODM 固件层。
- XMOS 官方 [lib_xua](https://github.com/xmos/lib_xua) 里，HID 参考实现只有 1 字节的媒体键报告，且没有 OUT 路径；但 `vendorrequests.c` 留了 `VendorRequests()` 弱符号钩子供 OEM 覆盖。所以这些协议全是厂商自己加的，XMOS 文档里查不到。
- UA1 II 走 HID 而非 EP0，属于山灵较新的设计分支。

## UAC2 数字音量（与硬件音量无关的另一套控制）

官方 app 的 `libusbaudio.so` 里有 `uac2SetVolume` / `getFeatureUnitId`，用于
**独占播放模式**。它对应描述符里的 Feature Unit ID 3，macOS 的 CoreAudio 可直接读写：

```
写 30% -> 读回 30%     写 65% -> 读回 65%
```

但这**不是**机身屏幕上的硬件音量——实测 macOS 侧显示 100% 时屏幕是 27，
两者完全独立。硬件音量只能走厂商协议的 `command=0x01`。

## 当前状态

| 能力 | 状态 | 前置条件 |
|---|---|---|
| 读设备状态 | ✅ | 无 |
| 写全部设置 | ✅ | 无 |
| 机身按键改动的同步 | ✅ | 无（设备主动上报） |

已交付 **macOS 菜单栏 App**（纯用户态，打开即用）与 **命令行诊断工具**
[tools/capture.c](../../tools/capture.c)。用法见 [README](../../README.md)。

**DriverKit dext 已放弃**：要 Apple 权限申请、开发者模式，还会让机身实体按键
失效，而 HID 路径不花任何代价就达到了同样效果。

## ⚠️ 安全提示

40 字节载荷里绝大部分是 `00`，**未文档化的命令字行为完全未知**。
不要遍历 command 空间——固件升级 / DFU 入口很可能就藏在某个未用命令后面。
已验证的 `01`/`02`/`03` 以及上游列出的其余几个属于安全范围。
---

## 修订记录

**2026-08-07**：本文早期版本断定「HID 通道读写都不通，必须以 root 捕获整个
设备」，并据此构造了一套基于 HID 描述符的解释。**那是错的**，根因是上文那个
`reportID` 参数用法；App 曾为此建立 LaunchDaemon + XPC + 系统设置审批流程，
并接受每次读写中断音频，现已全部移除。错误的推理已从本文删去，避免误导；
过程保留在 git 历史里。

教训：**「证据是观察不到现象」的结论要格外警惕**。当时为「收不到回复」编出的
机制自洽而严密，却建立在一次有缺陷的观测上。相比之下浏览器那节的结论依据是
可复查的源码，可靠得多。
