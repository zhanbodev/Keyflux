# KeyboardDriver v1 与型号描述

统一入口：[Extension Interface Specification](../EXTENSIONS.md)（[简体中文](../EXTENSIONS.zh-CN.md)）。本文保留键盘接口的专项说明。

状态：源码接口草案；固定 Zig 0.17.0 编译，不承诺动态库 ABI。

## 生命周期

`KeyboardDriver` 位于 `src/device.zig`，context + 静态 vtable：

| 方法 | 输入 / 输出 | 要求 |
|---|---|---|
| probe | → Identity(model_id, firmware, profile) | 默认只读；不顺带接管 |
| capabilities | → Capabilities | 仅声明已验证能力 |
| capture | → Capture | 完整保存即将修改的原始状态 |
| setSolid | Lighting(color RGB u8, brightness 0–100) → void/error | 仅主键区，不能改侧灯 |
| restore | Capture → void/error | 校验型号、固件、档位与所有权后恢复并回读 |

核心在首次写入前原子提交 recovery journal；回读确认后才能公布 acknowledged。相同颜色亮度不重复写。退出/空闲/来源失效恢复；失败保留 journal。拔线后不得把恢复成功当作已完成；下次匹配设备恢复后再接管。

`Capture` 增加可选 `native` tagged union；null 为兼容既有模拟快照，`nuphy_s4_main_v1` 保存 fingerprint `[64]u8` 与完整 state `[17]u8`。Kick75 实现相同 vtable，通过独立手动 CLI 和版本化原始状态日志接入；模拟 Lease 不负责实体灯态。详见[真实驱动、恢复日志与边界](../EXTENSIONS.zh-CN.md#驱动源码契约)。

`per_key` 和 `max_frames_per_second` 已预留能力字段，v0.1 没有 writeFrame，也没有蛇形 renderer。后续加帧接口必须验证实际物理映射、可恢复的原调色板与安全持续写入路径。

## 型号描述

模板为 `models/nuphy-kick75-io.json`。字段：schema_version、id、name、protocol、usb、firmware、verified_on、layout、capabilities、verification、evidence。USB 需要 vendor_id、product_id、usage_page、usage、report_bytes，可指定 interface_number。

- recognized：只识别，不开放变色/逐键/恢复能力。
- experimental：存在受控实验与记录，尚未完成验证矩阵。
- verified：平台 × 固件 × 连接方式 × 灯区的真机验收完整，evidence 必填。

当前描述校验只允许已登记的 `nuphy_io_s4` 协议和 64 字节报告；新协议必须增加代码、schema 与测试。描述文件不含 opcode、任意脚本、动态库路径或固件图片。文件通过校验并不使真实运行时自动开放设备。

`firmware` 指定 family 与精确 versions 列表，使用明确验证版本而不是宽泛版本通配。`verified_on` 每项指定 platform、architecture、firmware、profile、transport、zone 与 evidence 清单；版本必须在 firmware.versions 中。verified 描述要求非空版本与验收矩阵。

可选 `layout` 包含 key_count、led_count 和 leds；每个灯位包含唯一 id、唯一 index、非负有限坐标 x/y。key_count 必须等于映射数，索引小于 led_count，保留未定位通道不需要强行映射。per_key 能力必须附布局。当前 experimental Kick75 不猜测物理索引。

## 验证工具与贡献

`keyflux diagnose` 只调用 HIDAPI enumerate，不打开设备或发送报告。`keyflux validate-model file.json` 检查描述；模拟设备用于离线验证接管、去重和恢复。`hardware-probe` 只读固件、档位与 D5 灯态；`hardware-solid`、`hardware-verify-restore`、`hardware-restore` 提供固定固件／Mac 档的手动实机验证。见[Kick75 专项记录](../hardware/kick75.md)。

`src/protocol.zig` 保留只读研究 codec；真实驱动 `src/kick75.zig` 独立校验 S4 编解码。Zig 和原生传输共同限制 D6 为 offset 0、9 字节的主灯设置；不发送 EE/D8、固件/IAP 或侧灯 setter。Mac 档常亮与原态恢复已有证据；Win 档、持久化与设备生命周期未完成，因此保持 experimental，尚未接入 AI 自动灯控。

贡献必须附 [CONTRIBUTING.md](../../CONTRIBUTING.md) 的验收材料。硬件错误包括 RecoveryRequired、RecoveryIdentityMismatch、MissingNativeCapture、UnsupportedOriginalEffect、RestoreColorUnrepresentable、UnverifiedFirmwareOrGeometry、UnverifiedProfile、ConcurrentDeviceChange、ProfileChanged、SideStateChanged、DeviceBusy、MultipleDevices、HidTimeout；其他错误类别包括 UnsupportedCapability、DeviceDisconnected、ReadbackMismatch、IdentityMismatch、UnsupportedReportSize、InvalidCapabilities、UnverifiedCapability、MissingEvidence。
