# Theme v1 与灯效接口

统一入口：[Extension Interface Specification](../EXTENSIONS.md)（[简体中文](../EXTENSIONS.zh-CN.md)）。本文保留主题接口的专项说明。

状态：配色 JSON 已实现；动画接口为后续版本设计。

```json
{"schema_version":1,"name":"Keyflux","completion_hold_ms":5000,"signals":{"thinking":{"color":"#06B6D4","brightness":50},"output":{"color":"#8B5CF6","brightness":50}}}
```

`signals` 包含 working、thinking、output、tool、attention、complete、error。省略的状态采用内置默认值。idle / unknown 没有颜色项，释放灯光控制并恢复原状态。

- color：严格 `#RRGGBB`，大小写均可。
- brightness：0–100 整数，硬件转换由 driver 完成。
- completion_hold_ms：1000–60000，默认 5000。
- name：1–64 字节，默认 Keyflux。
- schema_version：1。未知字段和版本拒绝，输入最多 16 KiB。

`validate-theme` 只校验；`theme-set file.json` 向运行中的核心提交，校验和持久化成功后热加载。无效主题保留旧配置。`theme-get` 返回活动主题，可提取 theme 对象作为导出文件；原生界面提供导入导出。

错误包括 InvalidColor、InvalidBrightness、InvalidDuration、InvalidThemeName、UnsupportedVersion、StateWriteFailed。解析后的字符串由主题专属 arena 持有，替换时整体释放，不能借用请求缓冲区。

## 后续 EffectRenderer

预定纯计算契约：`render(state, monotonic_time, layout, capabilities, parameters) -> logical_frame`。帧描述逻辑灯位 RGB，不携带硬件报文。核心负责限速、丢弃过期帧和唯一写入者；驱动负责地址映射。

蛇形路径按验证过的物理行交替方向遍历，不假设设备 LED 索引顺序就是物理顺序。没有 per_key 能力时不开放此效果。v0.4 才引入具体帧类型与 renderer 源码贡献示例，不在 v0.1 提供虚假的可执行动画接口。

## Theme v2

[Theme v2](theme-v2.md) 显式增加侧灯配置：enabled、follow_main／independent 以及独立状态配色。v1 的字段与导出语义保持不变；v1 不允许 side 字段。App 可导入旧配置，导出新版时明确使用 schema_version:2。侧灯仅保存和屏幕预览，当前没有实体侧灯写入。
