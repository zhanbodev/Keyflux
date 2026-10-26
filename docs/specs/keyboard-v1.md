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

**当前 Capture/Lease 仅完整实现模拟后端。** 其 color/brightness 结构不足以代表真实原厂效果，真实驱动接入前须扩展为带协议版本和完整原始状态的 capture variant。禁止把该模拟快照用于硬件恢复。

`per_key` 和 `max_frames_per_second` 已预留能力字段，v0.1 没有 writeFrame，也没有蛇形 renderer。后续加帧接口必须验证实际物理映射、可恢复的原调色板与安全持续写入路径。

## 型号描述

模板为 `models/nuphy-kick75-io.json`。字段：schema_version、id、name、protocol、usb、firmware、verified_on、layout、capabilities、verification、evidence。USB 需要 vendor_id、product_id、usage_page、usage、report_bytes，可指定 interface_number。

- recognized：只识别，不开放变色/逐键/恢复能力。
- experimental：存在受控实验与记录，尚未完成验证矩阵。
- verified：平台 × 固件 × 连接方式 × 灯区的真机验收完整，evidence 必填。

当前描述校验只允许已登记的 `nuphy_io_s4` 协议和 64 字节报告；新协议必须增加代码、schema 与测试。描述文件不含 opcode、任意脚本、动态库路径或固件图片。文件通过校验并不使真实运行时自动开放设备。

`firmware` 指定 family 与精确 versions 列表，使用明确验证版本而不是宽泛版本通配。`verified_on` 每项指定 platform、architecture、firmware、profile、transport、zone 与 evidence 清单；版本必须在 firmware.versions 中。verified 描述要求非空版本与验收矩阵。

可选 `layout` 包含 key_count、led_count 和 leds；每个灯位包含唯一 id、唯一 index、非负有限坐标 x/y。key_count 必须等于映射数，索引小于 led_count，保留未定位通道不需要强行映射。per_key 能力必须附布局。当前 recognized Kick75 不猜测物理索引。

## 验证工具与贡献

`keyflux diagnose` 只调用 HIDAPI enumerate，不打开设备或发送报告。`keyflux validate-model file.json` 检查描述；模拟设备用于离线验证接管、去重和恢复。当前没有对真实键盘发出主灯 setter 的 CLI。

协议研究用 `src/protocol.zig` 的只读 A1/D5 codec；它不与诊断命令绑定，不发送 EE/D6/D8，更不开放固件/IAP 命令。必须先补齐并审查 Kick75 的固件、主灯状态、档位与持久化证据，才可实现真实 setSolid。

贡献必须附 [CONTRIBUTING.md](../../CONTRIBUTING.md) 的验收材料。错误类别包括 UnsupportedCapability、DeviceDisconnected、ReadbackMismatch、IdentityMismatch、UnsupportedReportSize、InvalidCapabilities、UnverifiedCapability、MissingEvidence。
