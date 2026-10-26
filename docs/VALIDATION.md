# 验收状态

本记录区分软件检查与真实硬件 / Codex 验证。更新时附命令、环境和证据，不把示例或模拟结果写成实测。

## 当前边界

| 能力 | 状态 |
|---|---|
| Zig 状态引擎、主题、模拟驱动 | 已有单元测试 |
| IPC、OTLP JSON/protobuf、模拟崩溃恢复 | 集成测试覆盖 |
| macOS / Windows 核心 | 构建与 CI 检查；跨编译不等于 Windows 真机 |
| macOS 原生设置窗口 | 提供源码与本地构建；视觉/交互实测须独立记录 |
| Kick75 IO USB 枚举 | 2026-10-26 在开发机识别 19f5:1026；Raw HID usage page 1 / usage 0 / interface 3；没有打开设备或发送 setter |
| Kick75 主灯颜色、恢复、档位和持久化 | **未验证，真实写入禁用** |
| 实际 Codex 桌面 reasoning / 输出及会话关联 | **未验证**，只完成模拟 OTLP 管道 |
| 500 ms 实体端到端 P95 | **未测量** |
| 自动来源崩溃检测、睡眠唤醒、系统安装卸载 | 尚未完成真实接入验收 |

## 放行规则

`keyflux gate evidence.json` 读取 `Gate` 结构，自报检查项全部成立且 P95 ≤ 500 ms 才返回 0；否则返回 2。字段含主灯、恢复、档位隔离、持久化、安全写入路径、reasoning/output、会话关联、真实桌面版本、P95 与证据文件清单。

这个工具不是签名认证器，不验证照片真实性，也不会把真实驱动切换为可写。代码审查与真机验收都通过后，才能增加对应的驱动注册和 verified 型号声明。`examples/release-gates.json` 故意全部保留未通过状态。

## 2026-10-26 软件检查与模拟性能

18 项 Zig 测试、7 项黑盒集成测试通过；Apple Silicon macOS 核心与 Swift 界面编译通过；Windows x64 核心交叉编译通过。Windows 尚未进行真机运行，CI 工作流已提供但未在远端执行。

[原始基准记录](evidence/simulated-performance-20261026.json)：ReleaseSafe，Darwin 27.0.0 / arm64，5 秒空闲采样为单核 CPU 0.0768%，驻留内存 12,173,312 bytes（约 11.6 MiB）；100 次模拟事件的 CLI 启动至模拟持久化确认 P95 为 7.799 ms。

该短时软件基准不测量实际 Codex、HID 或实体灯色，也不能证明长时间稳定性、设备写入安全或 500 ms 真实端到端目标。复现命令：

```sh
python3 scripts/benchmark.py zig-out/bin/keyflux --output /tmp/keyflux-benchmark.json
```

本地 `dist/Keyflux.app` 开发包已生成，约 3 MiB，通过临时签名的 `codesign --verify --deep --strict`；核心 Mach-O 最低部署版本为 macOS 13.0。此包没有 Developer ID 签名或 Apple 公证，原生界面尚未进行视觉与交互真机验收。

## 可复现软件检查

```sh
zig build test
zig build -Doptimize=ReleaseSafe
python3 tests/integration.py zig-out/bin/keyflux
zig build -Dtarget=x86_64-windows-gnu -Doptimize=ReleaseSafe --prefix zig-out/windows
swift build --package-path macos --scratch-path .build/macos
```

测试仅使用模拟设备。开发环境需要允许本机 socket 和临时目录；受限沙箱可能拒绝 bind，与运行时协议错误不同。Swift 的缓存目录需可写。
