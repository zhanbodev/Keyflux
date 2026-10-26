const std = @import("std");
const ev = @import("event.zig");
const Value = std.json.Value;
pub fn field(v: Value, key: []const u8) ?Value {
    return if (v == .object) v.object.get(key) else null;
}
pub fn string(v: ?Value) ?[]const u8 {
    const x = v orelse return null;
    return if (x == .string) x.string else null;
}

/// Only allowlisted structural fields escape this function. Hook stdout is {}.
pub fn hook(v: Value, id: []const u8, now: u64) !?ev.Event {
    const name = string(field(v, "hook_event_name")) orelse return error.InvalidHook;
    const kind: ev.Kind = if (eq(name, "UserPromptSubmit")) .turn_started else if (eq(name, "PreToolUse")) .tool_started else if (eq(name, "PostToolUse")) .tool_finished else if (eq(name, "PermissionRequest")) .attention else if (eq(name, "Stop") or eq(name, "SubagentStop")) .turn_completed else if (eq(name, "SubagentStart")) .turn_started else if (eq(name, "Interrupt")) .turn_cancelled else if (eq(name, "SessionEnd")) .session_ended else return null;
    const session = string(field(v, "session_id")) orelse return error.InvalidHook;
    // SessionEnd has no stable turn_id; runtime correlates it explicitly.
    const turn = string(field(v, "turn_id")) orelse if (kind == .session_ended) "@current" else return error.MissingTurnId;
    var result: ev.Event = .{ .schema_version = 1, .provider = "codex", .session_id = session, .turn_id = turn, .event_id = id, .timestamp_ns = now, .kind = kind };
    if (eq(name, "SubagentStart") or eq(name, "SubagentStop")) result.task_id = string(field(v, "agent_id")) orelse return error.MissingTaskId;
    if (kind == .tool_started or kind == .tool_finished or kind == .attention) {
        result.request_id = string(field(v, "tool_use_id")) orelse if (kind == .attention) "@uncorrelated" else return error.MissingRequestId;
        result.tool_name = string(field(v, "tool_name"));
    }
    try result.validate();
    return result;
}

pub fn streamKind(kind: []const u8) ?ev.Kind {
    // Exact matches only. Generic websocket frames, missing text, and absence of
    // tools never count as reasoning. The probe must prove actual emitted names.
    if (eq(kind, "response.reasoning_summary_text.delta") or eq(kind, "response.reasoning_text.delta")) return .thinking;
    if (eq(kind, "response.output_text.delta")) return .output;
    return null;
}
fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
