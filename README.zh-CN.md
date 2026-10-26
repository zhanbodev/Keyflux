# Keyflux

[English](README.md) | **简体中文**

本地 AI 状态灯伴侣，使用面向 macOS / Windows 的 Zig 核心，将 Agent 活动映射为键盘灯光，并为键盘、AI 接入和灯效提供独立扩展入口。

**当前阶段：v0.1 内部验证，实体键盘灯光写入仍禁用。** 运行后端为只读或明确标注的模拟设备。识别 Kick75 IO 不代表已验证主灯控制；真实 Codex 桌面的思考／输出阶段仍需实测。

## 当前能力

- Zig 状态引擎：多会话汇总、工具与审批关联、结束回合的迟到事件隔离。
- 模拟键盘：相同写入去重、持久化恢复日志、强制终止后的恢复。
- NuPhy USB HID 只读枚举，包括 Kick75 IO（`19f5:1026`）。
- Codex hook 适配器，以及可选的本机鉴权 OTLP/HTTP 接收器，支持 JSON 和 protobuf 日志。
- macOS 原生菜单栏／设置应用：逐状态颜色和亮度、未保存配色预览、主题导入导出。
- 版本化的事件、键盘型号和主题契约，附校验工具及贡献指南。

Thinking 必须来自明确的 reasoning 事件；沉默、经过时间或没有工具调用都不能证明正在思考。完成色表示回合结束，不代表结果一定正确。

## 平台与技术

| 组件 | 技术／当前状态 |
| --- | --- |
| 核心 | Zig **0.17.0**，由 [.zigversion](.zigversion) 固定 |
| HID 传输 | 随仓库提供 HIDAPI，采用其 BSD 许可选项 |
| macOS | macOS 13+，Apple Silicon 开发构建；SwiftUI + AppKit 设置界面 |
| Windows | x64 核心已交叉编译；实机行为未验证；图形界面后续提供 |
| 本地 IPC | macOS Unix socket；Windows 当前用户权限限制的 named pipe |

运行时不依赖 Python、Node.js、浏览器、产品账号或模型 API key。Python 仅用于开发工具和测试；基础 USB 枚举不需要输入监控或辅助功能权限。

## 快速开始

macOS 需要 Zig 0.17.0 和 Xcode Command Line Tools；仅原生设置界面需要 Swift 6+。

```sh
git clone --branch dev https://github.com/zhanbodev/Keyflux.git
cd Keyflux
zig build -Doptimize=ReleaseSafe
zig build test
./zig-out/bin/keyflux diagnose
./zig-out/bin/keyflux replay examples/session.jsonl
./zig-out/bin/keyflux serve --simulate
```

`replay` 使用固定时间戳的测试材料，输出 `working → thinking → output → complete`。`serve --simulate` 在前台运行，只改变模拟设备。

在另一个终端进入仓库根目录：

```sh
./zig-out/bin/keyflux status
./zig-out/bin/keyflux preview thinking
./zig-out/bin/keyflux theme-set examples/theme.json
./zig-out/bin/keyflux theme-get
./zig-out/bin/keyflux stop
```

默认运行数据目录：

| 平台 | 目录 |
| --- | --- |
| macOS | `~/Library/Application Support/Keyflux` |
| Windows | `%LOCALAPPDATA%/Keyflux` |

服务端与客户端均可传入 `--state-dir PATH` 隔离实例。Unix socket 路径应保持简短。不要把固定日期的回放材料当成实时适配器事件；实时事件须生成当前 Unix 纳秒时间和唯一 event ID，见[扩展规范](docs/EXTENSIONS.zh-CN.md#ai-事件适配器)。

### macOS 设置应用

先构建核心，再运行：

```sh
swift run --package-path macos --scratch-path .build/macos KeyfluxApp --core "$PWD/zig-out/bin/keyflux"
```

当前设置界面使用简体中文，可以启动只读或模拟核心。关闭设置窗口或退出设置应用后，独立核心继续运行；使用“停止核心”或 `keyflux stop` 明确停止并恢复模拟设备。

生成本地开发包：

```sh
sh scripts/package-macos.sh
```

产物为 `dist/Keyflux.app`，使用本地临时签名，不是 Apple 公证发行包。当前没有登录项、自动安装器和 Windows 图形界面。

### Windows 核心

在安装了 Zig 0.17.0 的 Windows 仓库目录运行：

```powershell
zig build -Doptimize=ReleaseSafe
.\zig-out\bin\keyflux.exe serve --simulate
```

也可以从开发主机交叉编译：

```sh
zig build -Dtarget=x86_64-windows-gnu -Doptimize=ReleaseSafe --prefix zig-out/windows
```

Ubuntu 等开发系统可用 `zig test src/tests.zig` 验证纯 Zig 核心。macOS 运行时构建需要 Apple SDK，交叉构建时使用 `-Dmacos-sdk=PATH` 指定；当前不提供 Linux HID 运行时。

## Codex 接入

生成待审查的配置片段：

```sh
./zig-out/bin/keyflux setup-codex "$PWD/zig-out/bin/keyflux"
```

该命令不实施配置修改。按 [Codex 接入指南](docs/CODEX.md) 保留已有 hooks/exporter 设置、审查并信任 hooks，再验证实际桌面版本。

使用 `keyflux serve --simulate --otlp-port 4318` 启动可选接收器。它仅监听 `127.0.0.1`，Bearer token 保存在实例目录的 `otlp-token` 中，请勿分享该文件。接收器只保留结构字段，不保存提示词、对话正文和工具内容；Keyflux 不自动上传遥测。

真实桌面事件覆盖、会话关联、导出延迟和自动来源崩溃检测仍需验证。模拟输入不能证明这些能力已可用。

## 扩展 Keyflux

从 **[扩展接口规范](docs/EXTENSIONS.zh-CN.md)**（[English](docs/EXTENSIONS.md)）开始：

| 扩展类型 | 贡献方式 |
| --- | --- |
| 键盘型号 | 型号描述文件、准确的设备／固件证据与校验结果 |
| 键盘协议 | 实现 `KeyboardDriver` 的 Zig 驱动、测试和恢复证据 |
| AI 接入 | 任意语言适配器，通过 CLI／本地 IPC 提交 `AgentEvent v1` |
| 配色主题 | `Theme v1` JSON，校验后导入，无需重新编译 |
| 动态灯效 | 后续 renderer 契约；逐键输出和蛇形效果尚未实现 |

描述文件不能执行任意 HID 命令，也不会自动启用驱动。当前没有外部二进制插件加载器或稳定插件 ABI。验收清单见 [CONTRIBUTING.md](CONTRIBUTING.md)，机器可读契约见 [schemas/](schemas)。

## 验证与路线

```sh
zig build test
python3 tests/integration.py zig-out/bin/keyflux
python3 scripts/check-vendor.py
./zig-out/bin/keyflux validate-model models/nuphy-kick75-io.json
./zig-out/bin/keyflux validate-theme examples/theme.json
./zig-out/bin/keyflux gate examples/release-gates.json
```

最后一个命令预期退出 **2**：它检查自报发布证据，不解锁硬件驱动。测试仅使用临时数据、本机通信和模拟设备；Windows 集成测试传入对应的 `.exe` 路径。

已有模拟基准记录：空闲 CPU 约为单核 0.08%，驻留内存约 11.6 MiB，CLI 到模拟确认 P95 约 7.8 ms。这些数字不包含真实 HID、Codex 导出延迟或实体灯色变化。详见[验收记录](docs/VALIDATION.md)及[原始基准](docs/evidence/simulated-performance-20261026.json)。

| 版本 | 里程碑 |
| --- | --- |
| v0.1 | 内部核心、模拟、诊断、事件探针和扩展契约 |
| v0.2 | Kick75 主灯与真实 Codex 阶段验证通过后的 macOS Alpha |
| v0.3 | Windows Alpha、原生托盘／设置和实机验证 |
| v0.4 | 已验证逐键布局与蛇形动画模式 |
| v0.5 | Claude Code、DeepSeek 等 Harness 适配器和社区设备 |
| v1.0 | 稳定接口、兼容矩阵、迁移恢复和签名发行 |

首发硬件目标是一把 USB 有线 Kick75 **NuPhyIO**。QMK/VIA 版本、蓝牙／2.4 GHz 灯控、普通 ChatGPT 对话监听和侧灯效果不计入首发范围。完整路线见 [ROADMAP](docs/ROADMAP.md)。

## 许可

[MIT](LICENSE) © 2026 Nuclx Tech。HIDAPI 采用其 BSD 许可选项；来源与许可边界见[第三方声明](THIRD_PARTY_NOTICES.md)。本项目与 NuPhy、OpenAI、Anthropic、DeepSeek 无官方隶属关系。
