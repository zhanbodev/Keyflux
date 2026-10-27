# 扩展接口规范

[English](EXTENSIONS.md) | **简体中文**

状态：**面向 Keyflux v0.1 的 v1 草案**。本文描述已实现的扩展入口和贡献者应遵循的约束。标记为“后续规划”的内容是设计边界，不是可调用 API。Zig 类型和校验器是可执行的事实依据；JSON Schema 负责结构校验，不能表达全部跨字段与生命周期规则。

## 扩展入口

```text
AI source → adapter → AgentEvent v1 → state aggregation
                                         ↓
                                  Theme v1/v2 / renderer (planned)
                                         ↓
                               KeyboardDriver → HID transport
```

| 入口 | 契约／源码 | 当前接入方式 |
| --- | --- | --- |
| AI 适配器 | [AgentEvent Schema](../schemas/agent-event-v1.schema.json)、[event.zig](../src/event.zig) | CLI 或本地 IPC，语言不限 |
| 键盘型号 | [Keyboard Schema](../schemas/keyboard-v1.schema.json)、[device.zig](../src/device.zig) | 提交经过校验的 JSON 与证据；没有根据型号文件自动发现驱动的机制 |
| 键盘驱动 | [device.zig](../src/device.zig) 中的 `KeyboardDriver` | 编译进入核心的 Zig 源码；模拟守护进程和实验性 Kick75 手动 CLI 驱动 |
| 配色主题 | [Theme v1](../schemas/theme-v1.schema.json)、[Theme v2](../schemas/theme-v2.schema.json)、[theme.zig](../src/theme.zig) | 主灯／侧灯配置校验、导入导出与主灯信号热加载 |
| 型号预览 | [KeyboardPreview v1](specs/keyboard-preview-v1.md) | 独立屏幕几何资源，不等于 HID 灯位映射 |
| 桌面桥接 | [内部桌面契约](DESKTOP.md#bridge-contract-internal-v1) | 受审查的本地 Tauri 命令；界面迁移不改变公开 CLI／事件／驱动契约 |
| 动态灯效 | EffectRenderer，规划于 v0.4 | 尚无 renderer 注册、帧提交或二进制插件加载器 |

核心统一负责状态汇总、灯光所有权、恢复与设备调度。AI 适配器不打开 HID，主题不包含硬件命令，驱动不解释对话正文。

## AI 事件适配器

### 事件信封

通过文件参数或 stdin，向 `keyflux emit` 提交一个 UTF-8 JSON 对象。事件拒绝未知字段，最大 16 KiB。

| 字段 | 类型 | 必填／规则 |
| --- | --- | --- |
| `schema_version` | integer | 必填，值为 `1` |
| `provider` | string | 必填，稳定的适配器命名空间 |
| `session_id` | string | 必填，该 provider 内稳定的会话标识 |
| `turn_id` | string | 必填，每个根回合使用不同标识 |
| `event_id` | string | 必填，在 provider/session/turn 内唯一；重试复用原 ID |
| `timestamp_ns` | integer | 必填，正 Unix 纳秒时间，最多超前核心时钟 10 秒 |
| `kind` | enum | 必填，取下表中的事件类型 |
| `task_id` | string 或 null | 可选，父会话／回合内的子任务标识；缺失或 null 表示根任务 |
| `request_id` | string 或 null | 工具／待处理的开始和解除事件必须提供非 null 值 |
| `tool_name` | string 或 null | 可选，仅工具名称，不含参数或输出 |

标识均为 1–192 字节可打印 ASCII（`0x21`–`0x7e`），不含空格。`task_id` 不能以 `@` 开头。`@current`、`@uncorrelated` 是 Codex 适配器内部约定，不应作为通用标识。`timestamp_ns` 必须无损编码为 JSON 整数，不能改成字符串或通过浮点近似传输。

```json
{
  "schema_version": 1,
  "provider": "example.harness",
  "session_id": "session-a",
  "turn_id": "turn-a",
  "event_id": "event-1",
  "timestamp_ns": 1,
  "kind": "turn_started"
}
```

上面的时间戳仅用于结构校验／离线演示。实时适配器必须填写来源事件的真实产生时间。

### 事件语义

| kind | 含义 |
| --- | --- |
| `turn_started` | 开始根回合或子任务，只建立 `working`，不证明 `thinking` |
| `working` | 已确认的普通活动；阶段未知，保留未解决的请求 |
| `thinking` | 明确观测到 reasoning 活动 |
| `output` | 明确观测到 assistant 文本输出 |
| `tool_started` / `tool_finished` | 打开／关闭同一个 `request_id` |
| `attention` / `attention_resolved` | 标记／解除同一个 `request_id` 的等待 |
| `turn_completed` | 根回合或子任务结束，不代表结果正确 |
| `turn_cancelled` / `turn_failed` | 明确中断／明确运行失败 |
| `source_lost` / `source_resumed` | 来源不可用／重新连接；连接恢复本身不提供阶段证据 |
| `session_ended` | 结束并清理当前根回合 |

阶段事件之前必须先有根回合 start。同一个 provider/session 只允许一个当前根回合，结束后才能创建下一个。子任务沿用父级 `session_id`、`turn_id`，使用独立 `task_id` 并显式 start。子任务结束不结束父任务，根回合终止会关闭其子任务。

保持来源事件顺序。旧阶段／生命周期事件以及已结束回合的事件返回 `stale`；重复事件返回 `duplicate`，两者都不增加 revision。近期 event ID 去重有容量上限，不是无限期 exactly-once 保证。重新连接后状态不确定时，不能伪造完成或思考事件。

未结束的工具请求使任务保持 `tool`，待处理状态优先。解除 attention 不等于工具已结束，真正结束后仍须发送 `tool_finished`；不相关的工具结果不能清除其他请求的 attention。

汇总优先级为：活跃待处理 → 已记录错误 → 来源不可用 → 活跃工作 → 完成保持 → 空闲。普通活跃任务取最近的有效阶段；任务存在在途工具请求时，工具状态覆盖其普通阶段。其他会话完成不能覆盖仍在进行的 working/thinking/output/tool。unknown 和 idle 释放模拟灯光租约并恢复原状态。

当前上限：64 个会话、每回合 8 个任务（含根任务）、每任务 8 个待关联请求、256 个近期去重摘要。仅在会话容量满时回收最早结束的墓碑；退役时间水位拒绝旧 start。活动会话不被淘汰，全部活动时返回容量错误。核心不持久化活动任务。本地 Codex adapter 使用真实 writer 与结构事件重建状态和检测失联，其他 adapter 负责各自的来源可用性。

草案修订 2026-10-27：新增 `working` kind，现有字段与 kind 语义不变。旧核心不支持此 kind，使用方须显式升级核心。详见 [AgentEvent 专项说明](specs/agent-event-v1.md)。

### 最小适配器示例

在 `keyflux serve --simulate` 已运行时，下面的 Python 示例通过公共 CLI 提交**合成演示事件**。真实适配器可以使用同一入口。如果可执行文件不在 PATH，设置 `KEYFLUX_BIN`；隔离实例时，服务端和客户端必须使用同一个 `--state-dir`。

```python
import json
import os
import subprocess
import time
import uuid

binary = os.environ.get("KEYFLUX_BIN", "keyflux")
session_id = "demo-" + uuid.uuid4().hex
turn_id = uuid.uuid4().hex

def emit(kind):
    event = {
        "schema_version": 1,
        "provider": "example.harness",
        "session_id": session_id,
        "turn_id": turn_id,
        "event_id": uuid.uuid4().hex,
        "timestamp_ns": time.time_ns(),
        "kind": kind,
    }
    result = subprocess.run(
        [binary, "emit"], input=json.dumps(event),
        text=True, capture_output=True, check=True,
    )
    return json.loads(result.stdout)

emit("turn_started")
emit("thinking")
emit("output")
emit("turn_completed")
```

真实适配器只能从对应来源回调触发这些状态，不能用定时器或提示词关键词推断阶段。贡献材料应声明 provider 命名空间、来源版本、支持阶段、子任务映射、不可用状态、断开检测和实测延迟。这些是贡献元数据，不是新增的运行时 manifest 格式。

### 本地 IPC 与错误

推荐使用 CLI 作为集成边界。内部事件 IPC 信封为：

```json
{"op":"emit","event":{"schema_version":1,"provider":"example.harness","session_id":"session-a","turn_id":"turn-a","event_id":"event-1","timestamp_ns":1,"kind":"turn_started"}}
```

```json
{"ok":true,"result":"applied","state":{"phase":"working","active_tasks":1,"tracked_sessions":1,"revision":1}}
```

macOS：实例目录中的 `control.sock`，目录权限 `0700`；每次连接一行 JSON 请求、一行 JSON 响应。Windows：根据实例目录生成、受当前用户 ACL 限制的 named pipe；原生客户端读到响应换行后发送 `0x06` 确认字节，再断开。pipe 命名规则属于内部实现，建议使用 CLI，避免硬编码。本地控制 IPC 不是 HTTP API，OTLP HTTP 端点不提供 `emit` 操作。

| 操作 | 附加请求字段 | 成功数据 |
| --- | --- | --- |
| `status` | 无 | `result`：汇总状态、后端、证据计数和进程指标 |
| `emit` | `event` | `result`：`applied`、`duplicate` 或 `stale`；汇总 `state` |
| `theme-get` | 无 | `theme` 对象 |
| `theme-set` | `theme` 对象 | 校验与持久化后的 `ok: true` |
| `preview` | `phase`，可选 `signal`（`color`、`brightness`） | 模拟预览 3000 ms，不保存主题 |
| `reset` | 无 | 清空任务／预览／设备错误，并尝试恢复模拟状态 |
| `stop` | 无 | 确认已收到关闭请求，进程随后尝试恢复 |

必须结合 `backend` 解读 `main_write_enabled`：模拟后端上的 true 不代表实体写入已开放。本内部版本的 `release_ready` 保持 false。`stop` 响应是请求确认，不能当作硬件恢复已完成。

错误编码为 `{"ok":false,"code":"ErrorName"}`。CLI 操作失败时退出码非零，应先检查退出状态，再解析成功对象。Codex 的 `hook` 命令刻意 fail-open，即使守护进程不可用也输出 `{}`，不能把它当作通用适配器提交 API。

| 错误类别 | 示例 | 调用方处理 |
| --- | --- | --- |
| 契约 | `UnsupportedVersion`、`InvalidIdentifier`、`ReservedIdentifier`、`MissingRequestId`、`PayloadTooLarge` | 修正输入，不原样重试 |
| 生命周期 | `MissingTurnStart`、`TurnStillActive`、`UnknownTask`、`FutureEvent` | 核对身份、顺序和来源时钟，不伪造 start |
| 容量 | `SessionCapacity`、`TaskCapacity`、`RequestCapacity` | 报告限制，不无限重试或静默 reset |
| 运行时 | `DaemonUnavailable`、`HardwareGateNotPassed`、`StateWriteFailed` | 显示不可用／失败原因，核对状态后再重试 |

可选 OTLP 端点是独立、经过鉴权的 Codex 观测入口。支持字段、Content-Type、大小限制和实际版本验证流程见 [Codex 指南](CODEX.md)。

## 键盘型号与驱动

### 型号描述文件

型号贡献放在 `models/`。[现有 Kick75 描述](../models/nuphy-kick75-io.json) 是绑定具体固件的实验性示例，不证明相近型号支持同一套灯光协议。

| 字段 | 契约 |
| --- | --- |
| `schema_version`、`id`、`name` | 版本 `1`；ASCII 标识；1–128 UTF-8 字节的显示名称 |
| `protocol` | 当前仅 `nuphy_io_s4`，新协议需要修改代码和 Schema |
| `usb` | 十进制 `vendor_id`、`product_id`、`usage_page`、`usage`、`report_bytes`；可选 `interface_number`，默认 `-1` 表示未指定 |
| `firmware` | 可选 `family`，默认 `unknown`；精确 `versions` 列表，默认空 |
| `verified_on` | 可选验收矩阵，每项含 `platform`、`architecture`、`firmware`、`profile`、`transport`、`zone`、`evidence` |
| `layout` | 可选／null 的物理映射，含 `key_count`、`led_count`、`leds` |
| `capabilities` | `solid_main`、`per_key`、`readback`、`restore`、`max_frames_per_second`；省略成员默认 false／0 |
| `verification` | `recognized`、`experimental`、`verified` |
| `evidence` | 必填的协议／验收引用数组，verified 时不能为空 |

USB VID/PID 是非零 16 位数值。`report_bytes` 当前固定为 64，`interface_number` 为 -1 或 0–32767。描述文件不能包含脚本、opcode、动态库路径或固件镜像。

recognized 不允许开放 `solid_main`、`per_key`、`restore`。verified 必须提供非空证据、精确固件版本和 `verified_on` 条目。矩阵平台为 macos/windows、架构为 aarch64/x86_64、档位为 mac/win、连接为 usb、灯区为 main。每项须提供证据，固件版本必须出现在 `firmware.versions`。验证结论只覆盖这些组合，不能推广为某个产品名的所有固件。

逐键型号必须设置 `solid_main: true`、正的 `max_frames_per_second` 并附 layout。每个灯位包含 `id`、`index`、`x`、`y`；ID 与 index 唯一，坐标有限且非负，索引小于 led_count。key_count 等于映射数量（1–256），且 `key_count ≤ led_count ≤ 1024`。未定位通道应保留未映射，不能编造物理位置。

```sh
keyflux diagnose
keyflux validate-model models/nuphy-kick75-io.json
```

`diagnose` 枚举 HID 身份，不打开设备或发送灯光报告；`validate-model` 只校验文件，不安装、发现或启用驱动。JSON Schema 不能验证 LED 索引唯一性和固件列表引用关系，仍须运行 CLI 校验器。

### 驱动源码契约

使用 Zig 0.17.0，实现 [device.zig](../src/device.zig) 中实际定义的 vtable：

```zig
pub const VTable = struct {
    probe: *const fn (*anyopaque) anyerror!Identity,
    capabilities: *const fn (*anyopaque) Capabilities,
    capture: *const fn (*anyopaque) anyerror!Capture,
    setSolid: *const fn (*anyopaque, Lighting) anyerror!void,
    restore: *const fn (*anyopaque, Capture) anyerror!void,
    setSideSolid: ?*const fn (*anyopaque, Lighting) anyerror!void = null,
};
```

Identity 包含 model_id、firmware、profile；Lighting 包含字节 RGB 和 0–100 的整数亮度。KeyboardDriver 持有 context 指针与 vtable；驱动所有者必须保证 context 以及被 Capture 引用的身份字符串存活至相关快照不再使用。Simulated 是可运行的源码示例，不是包含安全真机设置的 HID 驱动模板。

贡献者须实现以下生命周期保证：

1. probe 不接管灯光，仅声明独立验证过的能力。
2. 捕获所有将被修改的原状态；运行时必须在任何修改**之前**持久化恢复日志，仅使用 Lease 不会自动写日志。
3. 由核心串行访问，验证亮度和参数范围，遵守有证据的写入限制；不修改侧灯、键位或固件。
4. 完成声明的校验后才公布 acknowledged。传输 ACK 本身不证明实体灯光正确。
5. 只恢复匹配设备／固件／档位，校验恢复结果；失败或拔线保留日志，不盲目重放结果不明的写入。

`Capture` 新增可选的编译期 `native` tagged union；`null` 保持既有模拟表示。`nuphy_s4_main_v1` variant 保存 `fingerprint: [64]u8` 和完整 `state: [17]u8`。只保存 RGB／亮度无法恢复原厂效果。新协议须新增受审查的源码 variant 和测试，不能把任意报告命令塞进 Capture 或型号文件。

[Kick75 驱动](../src/kick75.zig) 实现同一 vtable。手动 CLI 使用独立的 `kick75-recovery.json`：显式 `schema_version: 1`、`format: kick75-s4-main-v1`、原始 probe／完整灯态、预期状态和 `pending` 事务标记。恢复须匹配原设备指纹、固件与档位；修改前先持久化 pending 记录，未完成事务禁止继续变色，必须显式恢复。实体灯效不复用模拟 Lease 的日志。守护进程与界面仍仅使用只读／模拟设备。详见[手动命令、精确量化与恢复规则、剩余门槛](hardware/kick75.md)。当前没有公共 registerDriver API，也没有实体灯光事件路由。

错误包括 `UnsupportedCapability`、`DeviceDisconnected`、`ReadbackMismatch`、`IdentityMismatch`、`InvalidModel`、`UnsupportedReportSize`、`UnverifiedCapability`、`MissingEvidence`、`UnlistedFirmware`、`MissingLayout`、`InvalidLayout`、`DuplicateLed`。

## 配色主题

Theme v1 是可导入 JSON，不是可执行代码：

```json
{
  "schema_version": 1,
  "name": "Glacier",
  "completion_hold_ms": 5000,
  "signals": {
    "thinking": {"color": "#06B6D4", "brightness": 50},
    "output": {"color": "#8B5CF6", "brightness": 50}
  }
}
```

signals 可以包含 working、thinking、output、tool、attention、complete、error，省略的状态使用内置默认值。idle／unknown 没有可配置颜色项，通常恢复原灯效租约。

- color：严格 `#RRGGBB`，十六进制大小写不限。
- brightness：0–100 整数。
- completion_hold_ms：1000–60000 整数，默认 5000。
- name：1–64 UTF-8 字节，默认 Keyflux。
- schema_version：1；当前解析器在省略该值时也默认使用 1。
- 拒绝未知字段和版本，文档最大 16 KiB。

```sh
keyflux validate-theme examples/theme.json
keyflux theme-set examples/theme.json
keyflux theme-get
```

先校验和持久化，再热加载；非法主题保留上一个有效配置。theme-get 返回包含 theme 的响应信封，导出时应取出内部 theme 对象，以便再次导入。`preview <phase> --signal-stdin` 接受 signal 对象，在模拟后端临时预览未保存颜色，不持久化主题修改。

错误包括 `InvalidColor`、`InvalidBrightness`、`InvalidDuration`、`InvalidThemeName`、`UnsupportedVersion`、`StateWriteFailed`。

## 动态灯效：后续规划

预定的纯计算边界为：

```text
render(state, monotonic_time, layout, capabilities, parameters) → logical_frame
```

这是**伪代码**，不是已有 Zig 签名。帧类型、参数格式、renderer 注册和 writeFrame 均未实现；per_key 和 max_frames_per_second 当前只描述后续能力。

后续灯效只能输出逻辑 RGB 帧，不访问 HID。核心负责调度、写入限速和替换过期帧，驱动负责把逻辑位置映射到已验证设备索引。蛇形路径必须遵循经过验证的物理行，不能假设 LED 索引顺序等于物理顺序。没有已验证逐键输出能力的设备不能宣称支持蛇形模式。

## 兼容、隐私与贡献验收

显式区分事件、型号和主题版本。v1.0 之前也不能静默重解释已有字段。序列化契约的破坏性变更需要新 schema_version 和迁移文档；Zig 源码接口绑定固定编译器，不提供稳定二进制 ABI。修改公共事件／Schema 时，应同步更新源码、Schema、示例、中英文 README、中英文扩展规范和相关测试。

适配器只发送结构化身份、类型、时间、关联 ID 和工具名称。事件和公开证据中不得包含提示词、对话正文、工具输入／输出、凭据、序列号或用户路径。接入配置须保留无关集成，并让冲突可审查；型号描述、主题和证据文件都不能授权任意硬件命令。

贡献应提供：

- 范围、来源／协议依据、兼容许可与支持能力矩阵。
- 最小示例与校验结果；按贡献类型补充顺序、重复、非法输入和不支持能力等确定性测试。
- 硬件：准确型号、USB 接口、系统／CPU、固件、键盘档位、连接方式、实际灯区、持久化行为、写入限制、回读、实体观察、恢复、拔插／崩溃／睡眠结果及明确未测试项。
- AI：真实来源版本、阶段／关联覆盖、缺失／歧义状态、断开行为，以及从来源产生事件开始计算的实测延迟；合成事件始终标注为合成。
- 软件／模拟与真机验收分开记录；CLI gate 检查自报材料，不能解锁设备。

运行 `zig build test`、相关集成测试及对应 validate-* 命令。详见[贡献清单](../CONTRIBUTING.md)、[验收记录](VALIDATION.md)，以及专项草案：[事件](specs/agent-event-v1.md)、[键盘](specs/keyboard-v1.md)、[主题](specs/theme-v1.md)。

### 主键区／侧灯与型号预览扩展

[Theme v2](specs/theme-v2.md) 保留主键区语义，显式增加 enabled、follow_main／independent 和独立侧灯状态配色。v1 导出字段不变。侧灯配置会持久保存，但当前不调度硬件写入；status 返回 side_write_enabled:false。编译期驱动预留 Zone、solid_side 能力和可选 setSideSolid 回调，默认拒绝，且必须具有恢复能力。原始恢复 variant 和协议写入白名单须独立扩展、验证后才能启用。

[KeyboardPreview v1](specs/keyboard-preview-v1.md) 定义外壳边界、键帽矩形／字符／系统图标及灯条形状。贡献 JSON、来源和校验结果即可扩展预览。屏幕坐标不是固件 LED 索引，模型选择器不启用 HID 控制。导入 NuPhy IO 元素的工具只提取布局，不执行网页，也不导入远程素材。
