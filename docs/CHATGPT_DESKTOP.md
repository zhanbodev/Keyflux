# ChatGPT desktop App: Work, Chat and Codex

The first user release targets the **ChatGPT desktop App**, including **Work**,
**Chat** and **Codex**. Users should connect their keyboard and manage colors in
Keyflux. Running Codex CLI, editing hooks files or configuring telemetry by hand
must not be a normal product prerequisite. macOS is the first platform; the same
source contract must support Windows later.

The installed test application is named ChatGPT with bundle ID
`com.openai.codex`. A shared application bundle does not imply the three surfaces
export the same lifecycle or streaming events.

## Current acceptance matrix

| Surface | Actual evidence | Remaining gate |
| --- | --- | --- |
| Codex in the App, local machine | Read-only local-index/events adapter; real Desktop working/tool observed; working drove real Kick75 with D5 readback and exact disconnect restoration | Live streaming Thinking/output, real completion/approval observations, latency and broader lifecycle |
| Work in the App, locally orchestrated | Official documentation says supported local hooks continue to work | Verify this execution mode, account/version and actual phases in the App |
| Work Cloud | Official documentation distinguishes cloud orchestration from local execution; local hooks and OTel do not cover the entire run | Establish an App-compatible channel, including personal-account support; do not label local tool execution as model Thinking |
| Chat in the App | No unified exported lifecycle/phase channel has been established in this project | Establish and validate a channel for actual generation, output, completion and disconnect |

The local Codex adapter now starts automatically and follows existing Desktop
sessions without CLI setup. See [source behavior and verification](CODEX_LOCAL.md).
Work and Chat remain unverified. No synthetic source, automatically installed
Codex configuration or default OTLP listener is used. The earlier temporary CLI
configuration was rolled back; original user configuration remains restored.

The App reports actual local-source availability instead of deriving an
integration failure from an idle AI phase. A real local-source -> Zig -> USB
main-light/readback -> exact disconnect restoration test passed. The current
recordings expose completed reasoning/message items, so this adapter keeps those
as ordinary working evidence and does not emit live Thinking/output claims.

## Adapter rules

Use the existing `AgentEvent v1` contract with separate provider identities such
as `chatgpt.work`, `chatgpt.chat` and `chatgpt.codex`. Each adapter must declare its
observed phases, supported App versions, execution mode and scope (all sessions,
selected session or visible session). Session and turn identity must be stable;
Work/Chat/Codex must not overwrite each other's active tasks.

- Thinking requires an actual exposed reasoning phase. Running tools, elapsed
  time or the appearance of a desktop window cannot establish Thinking.
- Output requires evidence of assistant streaming, not an old response on screen.
- No source or a lost source means unknown/unavailable, never successful completion.
- Do not silently replace existing desktop sessions with a new CLI/app-server run.
- No prompt or answer bodies, access tokens or full UI trees in persisted diagnostics.
- A proposed accessibility/UI adapter is not accepted until actual identifiers,
  app versions, account/execution modes and failure behavior are verified. A
  foreground-only observer cannot be advertised as multi-session monitoring.
- Any required first-time permission must be explained and initiated from the App.
  Do not bypass hook trust, operating-system permission or application access checks.

In this development session, the computer-use tool explicitly refused access to
`com.openai.codex`. No alternate UI-reading technology was used to bypass that
restriction. This blocks that inspection/verification path in the agent's
environment; it is not evidence that a user-installed integration is impossible.

## Delivery gates

1. Record supported App version, mode and account/execution scope for each surface.
2. Demonstrate a real turn's lifecycle, exact phase evidence and thread association.
3. Verify concurrent sessions, cancellation, source loss and App restart.
4. Measure export/coalescing delay together with device delay. The experimental
   driver's one-second pre-write delay means the 500 ms end-to-end goal is not met.
5. Verify D6 persistence/flash behavior and physical device lifecycle before a
   public recurring-lighting release. Strip and Windows hardware writes stay gated.

References read on 2026-10-27:

- [Official glossary: ChatGPT desktop, Work and Codex](https://learn.chatgpt.com/docs/glossary)
- [Official hooks and trust behavior](https://learn.chatgpt.com/docs/hooks)
- [Work Cloud and local hooks/telemetry compatibility](https://learn.chatgpt.com/docs/enterprise/cloud-local-access#check-hooks-and-network-compatibility)
- [OTel events and asynchronous batching](https://learn.chatgpt.com/docs/config-file/config-advanced#observability-and-telemetry)
