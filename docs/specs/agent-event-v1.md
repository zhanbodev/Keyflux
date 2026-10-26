# AgentEvent v1 与本地通信

统一入口：[Extension Interface Specification](../EXTENSIONS.md)（[简体中文](../EXTENSIONS.zh-CN.md)）。本文保留事件接口的专项说明。

状态：草案。编码 UTF-8 JSON，`schema_version` 必须为 1。类型定义以 `src/event.zig` 为准，JSON Schema 位于 `schemas/agent-event-v1.schema.json`。

## 事件

| 字段 | 类型 | 约束 |
|---|---|---|
| schema_version | integer | 1 |
| provider | string | adapter 来源，如 codex |
| session_id | string | 来源内稳定的会话标识 |
| turn_id | string | 会话内稳定的回合标识 |
| event_id | string | 来源、会话、回合范围内唯一 |
| timestamp_ns | integer | 来源事件的 Unix 纳秒时间；大于 0，不可超前本机 10 秒以上 |
| kind | enum | 下表之一 |
| task_id | string / null | 子任务标识；缺失表示根任务，@ 前缀保留 |
| request_id | string / null | 工具和审批事件必填，用于关联清理 |
| tool_name | string / null | 可选工具名称，不得包含参数或正文 |

标识均为 1–192 字节可打印 ASCII，排除空白。未知字段拒绝；不得在本协议中附带 prompt、message、tool_input、tool_output 或用户路径。单事件最多 16 KiB。

| kind | 意义 |
|---|---|
| turn_started | 创建根回合或子任务；开始时仅显示 working |
| thinking / output | 已观测 reasoning / assistant 输出阶段 |
| tool_started / tool_finished | 相同 request_id 的工具开始和结束 |
| attention / attention_resolved | 相同 request_id 的等待及解除 |
| turn_completed | 回合或子任务结束，不声称结果成功 |
| turn_cancelled / turn_failed | 明确取消 / 明确运行失败 |
| source_lost / source_resumed | 来源失效 / 重连；重连后仍待新阶段证据 |
| session_ended | 清理当前回合 |

根回合必须先 start。根回合结束会终止其子任务；子任务结束不会终止父任务。相同 session 同时只允许一个根回合；新回合必须有新的 ID 和更晚的时间戳。已结束回合不能被阶段事件或旧 start 复活。

当前上限：64 个会话、每回合 8 个任务（含根任务）、每任务 8 个待关联请求、最近 256 个去重摘要。会话保留最新回合墓碑，容量满时明确报错，不偷偷淘汰仍需隔离的身份。v0.1 没有跨重启恢复活动任务；恢复日志只恢复灯光。长驻使用的会话回收策略在稳定版前补充。

## 提交与响应

```sh
keyflux emit event.json
# 或向 stdin 输入一个完整 JSON 事件
```

macOS 使用状态目录 `control.sock`，目录 0700。请求是一行 JSON，响应一行 JSON，单次连接一个请求。Windows 使用当前用户 ACL 限制的 named pipe，命名基于状态目录；原生客户端处理响应读取确认再断开。暂不承诺 pipe 名称为永久公共标识；跨语言贡献推荐 CLI。

```json
{"op":"emit","event":{"schema_version":1,"provider":"example","session_id":"session-a","turn_id":"turn-a","event_id":"event-a","timestamp_ns":1,"kind":"turn_started"}}
```

```json
{"ok":true,"result":"applied","state":{"phase":"working","active_tasks":1,"tracked_sessions":1,"revision":1}}
```

其他操作：`status`、`stop`、`theme-get`、`theme-set`（theme 对象）、`preview`（phase，可选 signal 对象，3 秒）、`reset`。preview 只在已开放设备能力上执行；当前仅模拟后端。signal 具有 color/brightness，可临时预览未保存配色，不更改主题。CLI 使用 `preview thinking --signal-stdin` 从 stdin 读取该对象。成功响应 `ok:true`；错误响应 `ok:false,code:<ErrorName>`；事件处理结果为 applied / duplicate / stale。

错误包括 UnsupportedVersion、InvalidIdentifier、MissingRequestId、MissingTurnStart、TurnStillActive、UnknownTask、FutureEvent、SessionCapacity、TaskCapacity、RequestCapacity、HardwareGateNotPassed。CLI 对操作失败非零退出；Codex hook 客户端例外，始终 fail-open 且 stdout `{}`。

## Adapter 能力声明

每个 adapter 文档必须列明实际版本、可观察阶段、子任务范围、关联字段、失联检测和延迟证据。例如当前 Codex hooks 能建立 working/tool/attention/completion；thinking/output 依赖单独的流事件验证。能力缺失必须上报 unknown 或保留 working，不能推断。

v1.0 前有破坏性改动时提升 schema_version 并给迁移说明，不重解释旧字段。
