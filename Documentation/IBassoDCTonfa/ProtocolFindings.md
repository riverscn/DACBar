# iBasso DC-Tonfa HID 协议调查

## 已验证硬件

- 产品：iBasso DC-Tonfa
- VID/PID：`2FC6:F121`
- 固件：`1.66.39`
- HID：Usage Page `0x0C`、Usage `0x01`
- 输入/输出报告：各 8 字节，Report ID `0`

iBasso WebHID 控制台的设备表还登记了 PID `0x6011`。当前真机以 `0xF121` 枚举，产品名与
HID 描述符一致；Profile 同时接受两者。

## 信息来源与验证方式

协议先从 `https://devices.ibasso.cn/#/device/Tonfa` 当前加载的 WebHID 前端脚本还原，再以
macOS `IORegistry` 确认真机描述符，最后用 `IOHIDDeviceSetReportWithCallback` 在不抢占音频
接口的情况下完成五类读取和同值写回。真机测试读取成功，向当前熄屏设置写回相同值后再次
读取，完整状态保持不变。

## 读取

| 状态 | 请求（8 bytes） | 响应字段 |
|---|---|---|
| 固件 | `58 F1 0E 00 00 00 00 00` | `[4].[5].hex([6])` |
| 滤波 | `59 21 DE 00 00 00 00 00` | `[4]`，`0...4` |
| 音量 | `42 11 EE 00 00 00 00 00` | `[4]`，`0...100` |
| 音频组合 | `60 31 CE 00 00 00 00 00` | `[4]` 同轴、`[5]` 平衡、`[6]` 增益 |
| 屏幕组合 | `61 41 BE 00 00 00 00 00` | `[4]` 方向、`[5]` 灭屏旋钮、`[6]` 熄屏时间 |

平衡在线上为 `0...20`，`10` 居中；Driver 对 App 暴露 `-10...10`。熄屏时间是枚举：
`0=10s`、`1=20s`、`2=30s`、`3=常亮`。屏幕方向只有 `0°` 与 `180°`。
增益枚举为 `0=低`、`1=中`、`2=高`。官网 Tonfa 页面当前只渲染低/高两个按钮，并把所有
非零读值折叠成第二档；但其共享本地化资源包含中增益，真机菜单也暴露三档，因此 Driver
保留完整的三档线值。

## 写入

```text
音量       01 10 EF <v> <v> 00 00 00
滤波       11 20 DF 00 <filter> 00 00 00
音频组合   19 30 CF 00 <spdif> <balance+10> <gain> 00
屏幕组合   19 40 BF 00 <orientation> <keyControl> <timeout> 00
```

后三项与屏幕三项分别共享组合报告。改变一个字段时必须带上刚读到或刚确认的其它字段，不能
把未知字段填零。官网实现对写入不等待独立设备 ACK；本驱动因此声明
`confirmation = .transportCompletion`，IOKit 输出完成后更新缓存，下一次五类读取仍是权威状态。

## 真机回归

```bash
IBASSO_TONFA_HARDWARE_TESTS=1 \
swift test --package-path Packages/DACDevices \
  --filter IBassoDCTonfaTests.HardwareIntegrationTests
```

测试默认关闭。当前用例包含完整只读同步，以及保持熄屏设置不变的同值写回与再次读取；后者
验证输出路径而不改变用户配置。
