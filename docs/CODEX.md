# Codex 接入与精细阶段验证

## 支持边界

本实现不调用模型 API、不读取账号凭据、不提交提示词，也不控制已有 Codex app-server。hooks 为短命 Zig CLI，向当前用户核心提交结构事件，stdout 始终为 `{}`，核心不存在或输入不兼容也不阻塞 Codex。

支持事件：UserPromptSubmit、PreToolUse、PostToolUse、PermissionRequest、SubagentStart、SubagentStop、Stop、Interrupt、SessionEnd。后两类缺失回合字段时仅对当前明确关联的回合作清理。

PermissionRequest 在部分版本没有 tool_use_id：若同一任务仅有一个 tool_name 匹配的在途调用，使用该调用关联；否则保留未关联的审批，直到回合终止。其他工具结果不能任意清除审批。

子任务开始/结束按 agent_id 归属父会话。若某个版本的子任务工具事件没有可用身份，必须作为兼容性缺口记录，不能假装具备完整逐子任务阶段精度。

## 可审查配置

1. 构建 Keyflux，执行 `keyflux setup-codex /absolute/path/to/keyflux`，审查生成的 JSON。
2. 按 [官方 hooks 文档](https://learn.chatgpt.com/docs/hooks) 合并 hooks 到现有配置，保留其他条目，完成 hooks trust。不要用输出整体覆盖原文件。
3. 运行 `keyflux serve --simulate --otlp-port 4318`。32 字符随机 Bearer token 位于 Keyflux 状态目录的 `otlp-token`，不在控制台打印。
4. 按 [官方 OTel 文档](https://learn.chatgpt.com/docs/config-file/config-advanced#observability-and-telemetry) 配置本机日志 exporter。已有 exporter 时不覆盖；先解决路由冲突。

示意片段，填入本机 token，文件仅当前用户可读：

```toml
[otel]
log_user_prompt = false
exporter = { otlp-http = { endpoint = "http://127.0.0.1:4318/v1/logs", protocol = "binary", headers = { "Authorization" = "Bearer <LOCAL_TOKEN>" } } }
```

这是配置片段，不是自动安装器。重启 Codex 以使配置生效；不要为了测试中断未保存的任务。卸载时只移除 Keyflux hooks 与属于 Keyflux 的 exporter 改动，保留其他配置。当前版本不自动实施这些修改。

## 接收范围

- 仅支持 HTTP/1.1 `POST /v1/logs`，Content-Length、`application/json` 或 `application/x-protobuf`，不支持压缩或分块传输。
- 仅绑定 IPv4 loopback；Bearer 必须匹配；带 Origin 的请求拒绝；没有 CORS。
- 请求体限制 512 KiB，header 限制 8 KiB；每批最多 2048 条日志。请求超过边界或协议无效时拒绝，不落盘。
- 从 resource / record attributes 读取 `event.name` 或 `event_name`；事件须为 `codex.sse_event` 或 `codex.websocket_event`。
- 流事件类型键支持 `event.kind`、`event_kind`、`kind`；会话键支持 `conversation.id`、`conversation_id`、`session_id`；可选 `turn_id`。
- 只识别明确的 `response.reasoning_summary_text.delta` / `response.reasoning_text.delta` 和 `response.output_text.delta`。
- 缺少 turn_id 时，只有 session 已被 hook 建立一个活跃回合才可关联；缺少 timestamp/session 则拒绝。迟到的旧回合事件不会复活已结束任务。
- 这些是显式支持的编码，不保证当前安装版本实际输出这些字段。批处理可能显著增加延迟。

## 实测清单

提交一个明确有 reasoning 和文本输出的真实桌面任务，同时触发一次工具和审批。用 `status.result.evidence` 检查 reasoning/output、关联和拒绝数。`max_arrival_delay_ms` 仅是事件到接收器的最大时间差，不是 P95，也不是 HID/物理灯色延迟。

记录 Codex 版本、阶段产生时间、核心观察时间、HID 确认和实体观察。样本不足、事件字段缺失、批处理超时或无法可靠关联时，精细阶段门槛不通过。不要读取提示词/正文后用关键词分类补救。

来源异常退出后的可靠检测、终端状态与系统睡眠后的同步仍需真实接入验收。v0.1 的显式 source_lost 测试不能代替自动检测。
