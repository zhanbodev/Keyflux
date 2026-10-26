# 验收状态

本记录区分软件检查与真实硬件 / Codex 验证。更新时附命令、环境和证据，不把示例或模拟结果写成实测。

## 当前边界

| 能力 | 状态 |
|---|---|
| Zig 状态引擎、主题、模拟驱动 | 已有单元测试 |
| IPC、OTLP JSON/protobuf、模拟崩溃恢复 | 集成测试覆盖 |
| macOS / Windows 核心 | 构建与 CI 检查；跨编译不等于 Windows 真机 |
| macOS 原生设置窗口 | 提供源码与本地构建；视觉/交互实测须独立记录 |
| Kick75 IO USB 枚举 | 2026-10-26 识别 19f5:1026；Raw HID usage page 1 / usage 0 / interface 3；已有独立主灯手动驱动 |
| Kick75 主灯常亮、配置回读、原灯效恢复 | **实测通过**：macOS 27.0.1 / arm64、USB、4.0.18.6、Mac 档；限定手动 CLI，详见下方证据 |
| Win 档、Windows 实机、D6 持久化及完整拔插／睡眠／崩溃时机矩阵 | **未验证**；自动实体灯控保持禁用 |
| 实际 Codex 桌面 reasoning / 输出及会话关联 | **未验证**，只完成模拟 OTLP 管道 |
| 500 ms 实体端到端 P95 | **未测量** |
| 自动来源崩溃检测、睡眠唤醒、系统安装卸载 | 尚未完成真实接入验收 |

## 放行规则

`keyflux gate evidence.json` 读取 `Gate` 结构，自报检查项全部成立且 P95 ≤ 500 ms 才返回 0；否则返回 2。字段含主灯、恢复、档位隔离、持久化、安全写入路径、reasoning/output、会话关联、真实桌面版本、P95 与证据文件清单。

这个工具不是签名认证器，不验证照片真实性，也不会自动扩大真实驱动的写入范围。代码审查与真机验收都通过后，才能增加对应的驱动注册和 verified 型号声明。`examples/release-gates.json` 故意全部保留未通过状态。

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

## 2026-10-26 Kick75 IO 手动实机验证

[协议和运行方法](hardware/kick75.md)，[脱敏原始记录](evidence/kick75-main-20261026.json)。主灯红／青／紫三色常亮、D5 配置回读、原渐变灯态恢复已通过；用户确认目视效果与侧灯保持。默认 working／thinking／output 三色、`#40000E` 及黑色分别完成严格回读与当前颜色原态的 D6→D5 精确恢复测试；最后 17 字节状态与最初完全一致。

记录区分 RGB 量化与恢复：请求 `128,0,255` 回读 `132,0,255`；重连后也观测到直接回读请求 RGB 的路径，原因尚未确定；常亮仅接受请求值或已知换算值的精确匹配，恢复不采用通道容差。单独 ACK 不作成功依据，未知固件／档位不开写。恢复记录持久化后才发送 D6；不确定事务先显式恢复再继续。型号仍为 experimental，只有受控手动链路已开放；Win 档、Flash 行为、设备生命周期和真实 Codex 事件均未放行。

受控 SIGKILL 实测：D6 已应用、pending 尚未清除时终止写入进程，下一颜色返回 RecoveryRequired；显式恢复后最初 17 字节完全一致，日志随后删除。其他崩溃时机与无人值守重连不作已验证声明。

本次最终软件复核：30 项 Zig 测试、8 项黑盒集成测试通过；Windows x64 ReleaseSafe 交叉构建和 macOS Debug 应用打包／签名校验通过。重连后的直接 RGB 返回路径再次完成五色回读、去重和当前颜色精确恢复，最后原灯态一致。远端 CI 是否通过以 GitHub 实际记录为准。

## 2026-10-26 App 配色与型号预览

App 顶部固定整键盘预览，下方分主键区／侧边灯条编辑七种状态的取色器、HEX 和亮度；可跟随核心阶段，编辑时切换到对应状态预览。侧灯支持跟随主键区或独立配色，当前只保存配置与屏幕预览，status 的 side_write_enabled 保持 false。

Kick75 的 81 个键帽／旋钮元素由用户提供的 NuPhy IO DOM 提取，保留坐标、双行字符与媒体图标语义；网页脚本、账号内容和外部图片不导入。外壳使用本地线框，侧灯位置为示意。Air75 V3 是独立布局示例，不作为硬件兼容证明。界面已通过本 App 窗口截图检查，验证了主灯、侧灯与两种布局显示。

Theme v2 显式增加 side 字段；v1 导入和导出字段不变。已验证 v2 热加载、重启后回读、两区配色隔离、非法侧灯亮度拒绝与旧配置序列化兼容。扩展规范增加 KeyboardPreview v1、DOM 提取工具、屏幕布局校验器以及默认拒绝的侧灯驱动接口。任何型号预览或主题字段都不能开放实体写入。

检查包括 32 项 Zig 测试、9 项 IPC／配置集成测试、3 项预览贡献／DOM 惰性提取测试；Windows x64 核心跨编译、SwiftPM 资源打包和 macOS Debug 本地签名构建。新增预览与配色验证没有发送实体 HID 报告。先前硬件验收记录的范围不扩大。

开发检查已改为 `.build/macos-check/Keyflux Check.app` 独立目录，可在已有开发实例运行时执行 `scripts/dev-macos.sh --check`；该路径已实际通过，不需要停止现有会话。


## 2026-10-27 Tauri 2 + React/TypeScript 迁移

默认开发入口与打包已切换至 `desktop/`；旧 SwiftUI 实现仅保留为历史参考。Zig 协议、设备门槛及恢复链路保持原实现。共享布局移至 `assets/keyboard-layouts/`，Kick75 使用本地校验缓存中的原外壳、三段键帽遮罩、旋钮及媒体图标；仅提取坐标后重画通用圆角键帽的旧方案不再作为默认预览。侧灯位置仍是示意，字体仍可能与网页不同。

[本地软件证据](evidence/tauri-migration-20261027.json)：14 项前端契约测试、3 项 Playwright 交互测试、4 项 Rust 测试（包含真实 Zig 模拟 IPC）、32 项 Zig 测试、10 项核心集成测试及 3 项预览贡献测试通过。验证了 v1→v2、两区配色隔离、非法配置拒绝、Unicode 主题保存与重启回读、外部核心不被退出操作停止、实际 WKWebView 连接随包核心。完整演示经过 working/thinking/output/tool/attention/complete，启动器退出后自有模拟核心正常停止。

最终 macOS release `.app` 约 **7.22 MiB**，通过 `codesign --verify --deep --strict`，使用 ad-hoc 签名而非 Developer ID／公证。正常退出实际 release App 后，自有核心停止。原生导入导出对话框交互、关闭窗口后从托盘重开仍需手动验收；Windows 实机与真实 Codex 阶段仍未验收。整个 App 加 WebView 的 CPU/RSS 尚未基准测试，不能复用早先核心指标。本次未发送实体 HID 报告。素材仅缓存于本地，不能据此发布含原始 NuPhy 美术的二进制。


迁移后的 Windows CI 复现既有连续请求失败：上一 named pipe 连接尚在等待 ACK／断开时，下一次 CreateFile 返回 ERROR_PIPE_BUSY，旧客户端立即报告 DaemonUnavailable。客户端现按 [Microsoft 的 named pipe 连接流程](https://learn.microsoft.com/en-us/windows/win32/ipc/named-pipe-client)，在发送任何请求前进行最多 1 秒的可用性等待；发送后不重放请求。回读按块读取并保留完整换行与 ACK 语义，上限为 2 秒。新增连续与六路并发客户端测试。修复已本地跨编译；Windows 运行结论以对应远端 CI 为准。

主题导入也对齐 Zig 的合法省略值：部分状态、v2 侧灯默认字段与 side:null 会被明确展开为可编辑的 v2；v1 显式 side（包括 null）仍拒绝。实际开发入口与 React Fast Refresh 已通过本机 WebView 截图验证；临时测试标题已还原。
