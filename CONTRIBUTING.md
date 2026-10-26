# 贡献 Keyflux

## 新键盘型号

1. 阅读 [KeyboardDriver v1](docs/specs/keyboard-v1.md)，确认具体硬件是 IO、QMK/VIA 还是其他版本。
2. 先运行 `keyflux diagnose`。输出不包含序列号、系统设备路径或用户目录。
3. 同协议设备以 `models/nuphy-kick75-io.json` 为模板，填写型号、接口和证据。未验证的能力必须保持 false。
4. 不同协议新增 Zig 驱动，使用统一 `KeyboardDriver` vtable，并以模拟传输覆盖边界与失败路径；静态注册，禁止通过描述文件嵌入任意报文。
5. 运行 `validate-model`、`zig build test` 和相关集成测试。真机试验与自动测试分开记录。
6. 提交 PR 时附下列验收表；没有真机证据的设备只能保持 recognized 或 experimental。

## 验收材料模板

```text
型号与硬件版本：
USB VID/PID / usage page / usage / interface：
系统版本与 CPU 架构：
固件版本及 Mac/Win 档位：
连接方式：
协议来源及固定修订：
实际控制灯区：
原始状态捕获、写入、回读与恢复结果：
正常退出 / 拔插 / 崩溃后恢复 / 睡眠唤醒结果：
持久化行为、写入频率限制与依据：
物理逐键映射证据（如适用）：
脱敏报文文件与观察记录：
仍未验证的项目：
```

仅有 ACK、产品识别或 RGB 字节回读不足以证明实体灯区与布局正确。未经验证不得开放固件、恢复出厂、键位或 Flash 写入命令。

## AI 与灯效贡献

Adapter 用 `AgentEvent v1` 提交已观察的阶段，并声明能力。不要根据沉默、计时或提示词内容猜测 Thinking。新灯效通过纯计算 renderer 接口输出逻辑帧，不直接接触 HID。

每个贡献使用 MIT 或明确兼容的许可，附来源。不要移植 Keyphore 的 GPL 代码进入当前 MIT 项目。
