# Keyflux

本地 AI 状态灯伴侣。Zig 核心面向 macOS / Windows，macOS 设置界面采用 SwiftUI / AppKit。

**当前是 v0.1 内部验证工程。真实键盘主灯写入仍禁用。** 已提供状态聚合、模拟设备、只读 HID 枚举、Codex hooks 适配、OTLP/HTTP JSON 与 protobuf 接收、恢复日志、配色校验和贡献接口。原生 Mac 设置应用可在只读或模拟模式下使用。

Kick75 IO `19f5:1026` 的设备识别与灯光控制是不同能力。仓库没有把 Air75 主灯协议当作 Kick75 主灯实现，没有侧灯降级，也没有依据“无工具活动”猜测 Thinking。

## 构建与运行

需要 **Zig 0.17.0**。macOS 构建需要 Command Line Tools；Swift 界面需要 Swift 6+。运行时不需要 Python、Node.js 或浏览器。

```sh
zig build -Doptimize=ReleaseSafe
zig build test
./zig-out/bin/keyflux diagnose
./zig-out/bin/keyflux serve --simulate --otlp-port 4318
```

另一个终端：

```sh
./zig-out/bin/keyflux status
./zig-out/bin/keyflux emit examples/start.json
./zig-out/bin/keyflux emit examples/thinking.json
./zig-out/bin/keyflux preview output
./zig-out/bin/keyflux theme-get
./zig-out/bin/keyflux stop
```

示例事件的时间戳是固定回放数据。实时发送时用当前 Unix 纳秒时间和新的 event ID；完整顺序可直接离线运行：

```sh
./zig-out/bin/keyflux replay examples/session.jsonl
./zig-out/bin/keyflux validate-model models/nuphy-kick75-io.json
./zig-out/bin/keyflux validate-theme examples/theme.json
./zig-out/bin/keyflux gate examples/release-gates.json
```

最后一个命令预期退出码为 **2**，因为真机和真实桌面阶段验收尚未完成。它检查自报材料完整性，不会解锁真实硬件驱动。

运行时数据默认位于 macOS 的 `~/Library/Application Support/Keyflux` 或 Windows 的 `%LOCALAPPDATA%/Keyflux`。可以用 `--state-dir PATH` 隔离测试。Unix socket 路径长度有限，测试目录应保持简短。

## macOS 界面

```sh
swift run --package-path macos --scratch-path .build/macos KeyfluxApp --core "$PWD/zig-out/bin/keyflux"
```

设置窗口提供核心启停、未保存配色的模拟预览、逐状态颜色/亮度、完成保持时间、配色导入导出。关闭窗口或退出设置应用不停止独立核心；通过“停止核心”或 CLI 明确停止并恢复模拟状态。设置窗口打开时刷新状态，关闭或最小化后停止刷新；灯光计时由核心处理。

```sh
sh scripts/package-macos.sh
```

生成 `dist/Keyflux.app`，仅使用本地临时签名，不能视为已公证发行包。尚未提供 Windows 图形界面、登录项或自动安装器。

## Codex 接入验证

```sh
./zig-out/bin/keyflux setup-codex "$PWD/zig-out/bin/keyflux"
```

命令仅生成待审查的 hooks 与 OTel 配置片段，不更改 Codex 设置。按 [Codex 接入指南](docs/CODEX.md) 手动合并并信任 hooks 后，启动带 `--otlp-port` 的核心，再在真实 Codex 桌面任务中验证。已有 exporter 冲突时先停止配置，不覆盖现有路由。

- Hooks 提供回合、工具、审批、取消和子任务生命周期。
- `Thinking` / 输出只接受明确的流事件类型。OTLP 包缺少阶段字段、时间戳或关联信息时不猜测。
- OTLP 接收只绑定 `127.0.0.1`，使用状态目录中的 `otlp-token` 验证 Bearer。不要分享该文件。
- 请求体只存在于请求内存；正文、提示词和工具内容不进入状态文件或日志。
- 当前没有自动检测 Codex 进程崩溃的可靠机制。显式 `source_lost` 可恢复灯效并标记未知；安静不等于来源断开。该限制属于真实接入验收项。

完整兼容边界及验证状态见 [验收记录](docs/VALIDATION.md)。

## 接口与贡献

- [键盘驱动与型号贡献](docs/specs/keyboard-v1.md)
- [AI 事件与本地通信](docs/specs/agent-event-v1.md)
- [配色与灯效接口](docs/specs/theme-v1.md)
- [贡献流程](CONTRIBUTING.md)
- [版本路线](docs/ROADMAP.md)

同协议设备提交型号描述、测试与证据；新协议设备提交编译注册的 Zig 驱动。当前不支持加载任意设备命令或外部动态库。

## 测试

```sh
zig build test
python3 tests/integration.py zig-out/bin/keyflux
zig build -Dtarget=x86_64-windows-gnu -Doptimize=ReleaseSafe --prefix zig-out/windows
```

Python 仅用于开发测试。集成测试只访问临时目录、模拟设备和本机 socket / HTTP，不写入真实键盘或 Codex 配置。Windows 测试传入相应 `.exe` 路径。

Ubuntu 等系统可用 `zig test src/tests.zig` 验证纯 Zig 核心，也可交叉构建 Windows 核心；macOS 运行时构建需要 Apple SDK（可通过 `-Dmacos-sdk=PATH` 指定），不提供 Linux HID 运行时。

MIT © 2026 Nuclx Tech。HIDAPI 使用 BSD 许可，来源和其他研究参考见 [第三方声明](THIRD_PARTY_NOTICES.md)。本项目与 NuPhy、OpenAI 无官方隶属关系。
