const std = @import("std");
const testing = std.testing;
const Event = @import("event.zig").Event;
const Kind = @import("event.zig").Kind;
const Engine = @import("engine.zig").Engine;
const devices = @import("device.zig");
const themes = @import("theme.zig");
fn e(kind: Kind, session: []const u8, turn: []const u8, id: []const u8, ts: u64) Event {
    return .{ .schema_version = 1, .provider = "codex", .session_id = session, .turn_id = turn, .event_id = id, .timestamp_ns = ts, .kind = kind };
}
fn core() !*Engine {
    const ptr = try testing.allocator.create(Engine);
    ptr.* = .{};
    return ptr;
}

test "real evidence drives thinking output tool thinking; no timing inference" {
    const c = try core();
    defer testing.allocator.destroy(c);
    _ = try c.apply(e(.turn_started, "s", "t", "1", 1), 1);
    try testing.expectEqual(.working, c.snapshot(1000).phase);
    _ = try c.apply(e(.thinking, "s", "t", "2", 2), 2);
    try testing.expectEqual(.thinking, c.snapshot(2).phase);
    _ = try c.apply(e(.output, "s", "t", "3", 3), 3);
    try testing.expectEqual(.output, c.snapshot(3).phase);
    var tool = e(.tool_started, "s", "t", "4", 4);
    tool.request_id = "call-a";
    _ = try c.apply(tool, 4);
    try testing.expectEqual(.tool, c.snapshot(4).phase);
    var done = e(.tool_finished, "s", "t", "5", 5);
    done.request_id = "call-a";
    _ = try c.apply(done, 5);
    try testing.expectEqual(.working, c.snapshot(5).phase);
    _ = try c.apply(e(.thinking, "s", "t", "6", 6), 6);
    try testing.expectEqual(.thinking, c.snapshot(6).phase);
}
test "concurrent completion does not hide active work; completion expires" {
    const c = try core();
    defer testing.allocator.destroy(c);
    _ = try c.apply(e(.turn_started, "a", "1", "1", 1), 1);
    _ = try c.apply(e(.turn_started, "b", "1", "1", 2), 2);
    _ = try c.apply(e(.turn_completed, "a", "1", "2", 3), 3);
    try testing.expectEqual(.working, c.snapshot(3).phase);
    _ = try c.apply(e(.turn_completed, "b", "1", "2", 4), 4);
    try testing.expectEqual(.complete, c.snapshot(4).phase);
    try testing.expectEqual(.idle, c.snapshot(4 + 5 * std.time.ns_per_s).phase);
}
test "approval correlates request IDs; unrelated result cannot clear attention" {
    const c = try core();
    defer testing.allocator.destroy(c);
    _ = try c.apply(e(.turn_started, "a", "1", "1", 1), 1);
    var wait = e(.attention, "a", "1", "2", 2);
    wait.request_id = "permission-a";
    _ = try c.apply(wait, 2);
    var result = e(.tool_finished, "a", "1", "3", 3);
    result.request_id = "other";
    _ = try c.apply(result, 3);
    try testing.expectEqual(.attention, c.snapshot(3).phase);
    result.event_id = "4";
    result.timestamp_ns = 4;
    result.request_id = "permission-a";
    _ = try c.apply(result, 4);
    try testing.expectEqual(.working, c.snapshot(4).phase);
}
test "duplicates delayed events and old turn starts cannot revive work" {
    const c = try core();
    defer testing.allocator.destroy(c);
    const start = e(.turn_started, "a", "1", "1", 1);
    _ = try c.apply(start, 1);
    try testing.expectEqual(.duplicate, try c.apply(start, 1));
    _ = try c.apply(e(.output, "a", "1", "2", 3), 3);
    try testing.expectEqual(.stale, try c.apply(e(.thinking, "a", "1", "late", 2), 4));
    _ = try c.apply(e(.turn_completed, "a", "1", "3", 5), 5);
    try testing.expectEqual(.stale, try c.apply(e(.output, "a", "1", "late2", 6), 6));
    _ = try c.apply(e(.turn_started, "a", "2", "new", 7), 7);
    try testing.expectEqual(.stale, try c.apply(e(.turn_started, "a", "1", "old", 1), 8));
    try testing.expectEqual(.working, c.snapshot(8).phase);
}
test "source loss cannot become completion; reconnect alone supplies no phase" {
    const c = try core();
    defer testing.allocator.destroy(c);
    _ = try c.apply(e(.turn_started, "a", "1", "1", 1), 1);
    _ = try c.apply(e(.source_lost, "a", "1", "2", 2), 2);
    try testing.expectEqual(.unknown, c.snapshot(2).phase);
    _ = try c.apply(e(.source_resumed, "a", "1", "3", 3), 3);
    try testing.expectEqual(.unknown, c.snapshot(3).phase);
    _ = try c.apply(e(.output, "a", "1", "4", 4), 4);
    try testing.expectEqual(.output, c.snapshot(4).phase);
}
test "child terminal events do not finish parent; cancellation is not success" {
    const c = try core();
    defer testing.allocator.destroy(c);
    _ = try c.apply(e(.turn_started, "a", "1", "1", 1), 1);
    var child = e(.turn_started, "a", "1", "2", 2);
    child.task_id = "child";
    _ = try c.apply(child, 2);
    try testing.expectEqual(@as(usize, 2), c.snapshot(2).active_tasks);
    child.kind = .turn_completed;
    child.event_id = "3";
    child.timestamp_ns = 3;
    _ = try c.apply(child, 3);
    try testing.expectEqual(@as(usize, 1), c.snapshot(3).active_tasks);
    _ = try c.apply(e(.turn_cancelled, "a", "1", "4", 4), 4);
    try testing.expectEqual(.idle, c.snapshot(4).phase);
}
test "invalid input is transactional and unknown tasks require starts" {
    const c = try core();
    defer testing.allocator.destroy(c);
    try testing.expectError(error.MissingTurnStart, c.apply(e(.thinking, "a", "1", "1", 1), 1));
    try testing.expectEqual(@as(u64, 0), c.revision);
    var invalid = e(.turn_started, "a", "1", "1", 1);
    invalid.schema_version = 99;
    try testing.expectError(error.UnsupportedVersion, c.apply(invalid, 1));
    _ = try c.apply(e(.turn_started, "a", "1", "1", 1), 1);
    try testing.expectError(error.TurnStillActive, c.apply(e(.turn_started, "a", "2", "2", 2), 2));
    try testing.expectEqual(@as(u64, 1), c.revision);
}
test "simulation deduplicates writes and restores original without per-key capability" {
    var dev: devices.Simulated = .{};
    var lease: devices.Lease = .{};
    const original = dev.light;
    try testing.expect(try lease.apply(dev.driver(), (themes.Theme{}).signal(.thinking)));
    try testing.expect(!try lease.apply(dev.driver(), (themes.Theme{}).signal(.thinking)));
    try testing.expectEqual(@as(u64, 1), dev.writes);
    try testing.expect(!dev.driver().capabilities().per_key);
    _ = try lease.apply(dev.driver(), null);
    try testing.expectEqual(original, dev.light);
}
test "failed writes and identity mismatch retain recovery capture" {
    var dev: devices.Simulated = .{};
    var lease: devices.Lease = .{};
    dev.fail_write = true;
    try testing.expectError(error.ReadbackMismatch, lease.apply(dev.driver(), (themes.Theme{}).signal(.output)));
    try testing.expect(lease.original != null);
    try testing.expect(lease.acknowledged == null);
    dev.fail_write = false;
    dev.firmware = "changed";
    try testing.expectError(error.IdentityMismatch, lease.apply(dev.driver(), null));
    try testing.expect(lease.original != null);
}
test "theme validation blocks malformed hex brightness version duration" {
    var t: themes.Theme = .{};
    try t.validate();
    t.signals.output.color = "#ZZZZZZ";
    try testing.expectError(error.InvalidColor, t.validate());
    t = .{};
    t.signals.output.brightness = 101;
    try testing.expectError(error.InvalidBrightness, t.validate());
    t = .{};
    t.schema_version = 99;
    try testing.expectError(error.UnsupportedVersion, t.validate());
    t = .{};
    t.completion_hold_ms = 0;
    try testing.expectError(error.InvalidDuration, t.validate());
}
test "read-only report codec rejects corruption and bounds length" {
    const protocol = @import("protocol.zig");
    try testing.expectError(error.InvalidLength, protocol.readRequest(.read_lighting, 57, 0, 0, 0));
    var report = try protocol.readRequest(.read_lighting, 17, 0, 0, 0x42);
    report[0] = 0xaa;
    try protocol.validateResponse(report, .read_lighting);
    report[10] ^= 1;
    try testing.expectError(error.InvalidReport, protocol.validateResponse(report, .read_lighting));
}
test "Codex adapter discards content and never infers thinking" {
    const c = @import("codex.zig");
    const v = try std.json.parseFromSlice(std.json.Value, testing.allocator, "{\"hook_event_name\":\"UserPromptSubmit\",\"session_id\":\"s\",\"turn_id\":\"t\",\"prompt\":\"SECRET\"}", .{});
    defer v.deinit();
    const event = (try c.hook(v.value, "id", 1)).?;
    try testing.expectEqual(.turn_started, event.kind);
    try testing.expectEqual(@as(?Kind, null), c.streamKind("response.created"));
    try testing.expectEqual(@as(?Kind, .thinking), c.streamKind("response.reasoning_summary_text.delta"));
    try testing.expectEqual(@as(?Kind, .output), c.streamKind("response.output_text.delta"));
    const bytes = try std.json.Stringify.valueAlloc(testing.allocator, event, .{});
    defer testing.allocator.free(bytes);
    try testing.expect(std.mem.indexOf(u8, bytes, "SECRET") == null);
}

test "ambiguous permission without tool ID is never cleared by unrelated tools" {
    const c = try core();
    defer testing.allocator.destroy(c);
    _ = try c.apply(e(.turn_started, "s", "t", "start", 1), 1);
    var tool = e(.tool_started, "s", "t", "tool", 2);
    tool.request_id = "call-1";
    tool.tool_name = "Bash";
    _ = try c.apply(tool, 2);
    var permission = e(.attention, "s", "t", "approval", 3);
    permission.request_id = "@uncorrelated";
    permission.tool_name = "Bash";
    _ = try c.apply(permission, 3);
    try testing.expectEqual(.attention, c.snapshot(3).phase);
    tool.kind = .tool_finished;
    tool.event_id = "finished";
    tool.timestamp_ns = 4;
    _ = try c.apply(tool, 4);
    try testing.expectEqual(.working, c.snapshot(4).phase);
    permission.event_id = "ambiguous";
    permission.timestamp_ns = 5;
    permission.tool_name = "another-tool";
    _ = try c.apply(permission, 5);
    tool.event_id = "unrelated";
    tool.timestamp_ns = 6;
    _ = try c.apply(tool, 6);
    try testing.expectEqual(.attention, c.snapshot(6).phase);
}

test "model descriptions require firmware-specific evidence and unique physical LEDs" {
    var model: devices.Model = .{ .schema_version = 1, .id = "test", .name = "Test", .protocol = .nuphy_io_s4, .usb = .{ .vendor_id = 1, .product_id = 2, .usage_page = 1, .usage = 0, .report_bytes = 64 }, .capabilities = .{}, .verification = .recognized, .evidence = &.{} };
    try model.validate();
    model.usb.interface_number = -2;
    try testing.expectError(error.InvalidModel, model.validate());
    model.usb.interface_number = -1;
    model.capabilities.solid_main = true;
    try testing.expectError(error.UnverifiedCapability, model.validate());
    model.verification = .verified;
    try testing.expectError(error.MissingEvidence, model.validate());
    model.verification = .experimental;
    model.capabilities.per_key = true;
    model.capabilities.max_frames_per_second = 20;
    try testing.expectError(error.MissingLayout, model.validate());
    model.layout = .{ .key_count = 2, .led_count = 2, .leds = &.{ .{ .id = "a", .index = 0, .x = 0, .y = 0 }, .{ .id = "b", .index = 0, .x = 1, .y = 0 } } };
    try testing.expectError(error.DuplicateLed, model.validate());
}

test "error priority reserved task identities and hex syntax are explicit" {
    const c = try core();
    defer testing.allocator.destroy(c);
    _ = try c.apply(e(.turn_started, "s", "t", "1", 1), 1);
    _ = try c.apply(e(.turn_failed, "s", "t", "2", 2), 2);
    try testing.expectEqual(.@"error", c.snapshot(2).phase);
    _ = try c.apply(e(.turn_started, "s", "next", "3", 3), 3);
    try testing.expectEqual(.working, c.snapshot(3).phase);
    var child = e(.turn_started, "s", "next", "4", 4);
    child.task_id = "@root";
    try testing.expectError(error.ReservedIdentifier, c.apply(child, 4));
    try testing.expectError(error.InvalidColor, themes.Color.parse("#0x00ff"));
    try testing.expectError(error.InvalidColor, themes.Color.parse("#+00000"));
}

test "late lifecycle events cannot roll back a newer turn or hide source loss" {
    const c = try core();
    defer testing.allocator.destroy(c);
    _ = try c.apply(e(.turn_started, "s", "t", "1", 1), 1);
    _ = try c.apply(e(.output, "s", "t", "2", 5), 5);
    try testing.expectEqual(.stale, try c.apply(e(.source_lost, "s", "t", "late", 3), 6));
    _ = try c.apply(e(.turn_completed, "s", "t", "3", 10), 10);
    try testing.expectEqual(.stale, try c.apply(e(.turn_started, "s", "old-replay", "4", 7), 11));
    _ = try c.apply(e(.turn_started, "s", "next", "5", 12), 12);
    var permission = e(.attention, "s", "next", "6", 13);
    permission.request_id = "approval";
    _ = try c.apply(permission, 13);
    _ = try c.apply(e(.source_lost, "s", "next", "7", 14), 14);
    try testing.expectEqual(.unknown, c.snapshot(14).phase);
}

test "theme v2 keeps main and side independent while v1 serialization stays compatible" {
    const a = testing.allocator;
    const old = try themes.parse(a, "{\"schema_version\":1,\"signals\":{}}");
    defer old.deinit();
    const old_json = try std.json.Stringify.valueAlloc(a, old.value, .{});
    defer a.free(old_json);
    try testing.expect(std.mem.indexOf(u8, old_json, "side") == null);
    try testing.expect(old.value.sideSignal(.thinking) == null);
    var theme: themes.Theme = .{ .schema_version = 2, .side = .{ .enabled = true, .mode = .independent } };
    theme.side.?.signals.thinking.color = "#C084FC";
    try theme.validate();
    try testing.expectEqualStrings("#06B6D4", theme.signal(.thinking).?.color);
    try testing.expectEqualStrings("#C084FC", theme.sideSignal(.thinking).?.color);
    theme.side.?.mode = .follow_main;
    try testing.expectEqualStrings(theme.signal(.thinking).?.color, theme.sideSignal(.thinking).?.color);
    try testing.expect(theme.sideSignal(.idle) == null);
    try testing.expect(theme.sideSignal(.unknown) == null);
    theme.side.?.enabled = false;
    try testing.expect(theme.sideSignal(.thinking) == null);
    theme.schema_version = 1;
    try testing.expectError(error.SideRequiresThemeV2, theme.validate());
    try testing.expectError(error.SideRequiresThemeV2, themes.parse(a, "{\"schema_version\":1,\"side\":null}"));
    theme.schema_version = 2;
    theme.side.?.signals.output.color = "#bad";
    try testing.expectError(error.InvalidColor, theme.validate());
}

test "side writes require explicit capability and implementation" {
    var device: devices.Simulated = .{};
    const before = device.light;
    try testing.expectError(error.UnsupportedCapability, device.driver().setZoneSolid(.side, before));
    var invalid = before;
    invalid.brightness = 101;
    try testing.expectError(error.InvalidBrightness, device.driver().setSolid(invalid));
    try testing.expectEqual(@as(u64, 0), device.writes);
}

test "confirmed working activity resumes source without inventing reasoning or clearing requests" {
    const c = try core();
    defer testing.allocator.destroy(c);
    _ = try c.apply(e(.turn_started, "s", "t", "1", 1), 1);
    var wait = e(.attention, "s", "t", "2", 2);
    wait.request_id = "request";
    _ = try c.apply(wait, 2);
    _ = try c.apply(e(.source_lost, "s", "t", "3", 3), 3);
    try testing.expectEqual(.unknown, c.snapshot(3).phase);
    _ = try c.apply(e(.working, "s", "t", "4", 4), 4);
    try testing.expectEqual(.attention, c.snapshot(4).phase);
    var done = e(.tool_finished, "s", "t", "5", 5);
    done.request_id = "request";
    _ = try c.apply(done, 5);
    try testing.expectEqual(.working, c.snapshot(5).phase);
}
test "long running reader recycles ended sessions and rejects retired history" {
    const c = try core();
    defer testing.allocator.destroy(c);
    for (0..80) |i| {
        var buffer: [20]u8 = undefined;
        const id = try std.fmt.bufPrint(&buffer, "session-{d}", .{i});
        const ts: u64 = @intCast(i * 2 + 1);
        _ = try c.apply(e(.turn_started, id, "t", "start", ts), ts);
        _ = try c.apply(e(.turn_completed, id, "t", "end", ts + 1), ts + 1);
    }
    try testing.expectEqual(@as(usize, 64), c.snapshot(1000).tracked_sessions);
    try testing.expectEqual(.stale, try c.apply(e(.turn_started, "session-0", "t", "delayed", 1), 1000));
    try testing.expectEqual(@as(usize, 0), c.snapshot(1000).active_tasks);
}

fn checkEvent(kind: Kind, id: []const u8, ts: u64) Event {
    var v = e(kind, "check", "run", id, ts);
    v.schema_version = 2;
    v.provider = "keyflux.check";
    v.check_type = .@"test";
    return v;
}
test "verification is explicit and cannot be completed by ordinary AI completion" {
    const c = try core();
    defer testing.allocator.destroy(c);
    _ = try c.apply(checkEvent(.check_started, "start", 1), 1);
    try testing.expectEqual(.checking, c.snapshot(1).phase);
    var ordinary = checkEvent(.turn_completed, "wrong", 2);
    ordinary.check_type = null;
    try testing.expectError(error.InvalidCheckEvent, c.apply(ordinary, 2));
    _ = try c.apply(checkEvent(.check_passed, "pass", 3), 3);
    try testing.expectEqual(.verified, c.snapshot(3).phase);
    try testing.expectEqual(.stale, try c.apply(checkEvent(.check_failed, "late", 4), 4));
    try testing.expectEqual(.idle, c.snapshot(3 + 6 * std.time.ns_per_s).phase);
}
test "check failure persists until exact terminal task acknowledgement without hiding approvals" {
    const c = try core();
    defer testing.allocator.destroy(c);
    _ = try c.apply(checkEvent(.check_started, "start", 1), 1);
    _ = try c.apply(checkEvent(.check_failed, "fail", 2), 2);
    try testing.expectEqual(.check_failed, c.snapshot(100).phase);
    _ = try c.apply(e(.turn_started, "ai", "turn", "start", 3), 3);
    var wait = e(.attention, "ai", "turn", "wait", 4);
    wait.request_id = "question";
    wait.schema_version = 2;
    wait.attention_kind = .input;
    _ = try c.apply(wait, 4);
    try testing.expectEqual(.attention, c.snapshot(4).phase);
    try testing.expectError(error.TaskStillActive, c.acknowledge("codex", "ai", "turn"));
    try testing.expectError(error.UnknownTask, c.acknowledge("keyflux.check", "check", "wrong"));
    try c.acknowledge("keyflux.check", "check", "run");
    try testing.expectEqual(.attention, c.snapshot(5).phase);
    var resolved = e(.tool_finished, "ai", "turn", "answer", 6);
    resolved.request_id = "question";
    _ = try c.apply(resolved, 6);
    try testing.expectEqual(.working, c.snapshot(6).phase);
}
test "check heartbeat expiry is unavailable not a guessed failure or completion" {
    const c = try core();
    defer testing.allocator.destroy(c);
    _ = try c.apply(checkEvent(.check_started, "start", 1), 1);
    try testing.expectEqual(.unknown, c.snapshot(31 * std.time.ns_per_s).phase);
    var heartbeat = checkEvent(.working, "heartbeat", 32 * std.time.ns_per_s);
    heartbeat.check_type = null;
    _ = try c.apply(heartbeat, heartbeat.timestamp_ns);
    try testing.expectEqual(.checking, c.snapshot(heartbeat.timestamp_ns).phase);
    _ = try c.apply(checkEvent(.check_cancelled, "cancel", 33 * std.time.ns_per_s), 33 * std.time.ns_per_s);
    try testing.expectEqual(.idle, c.snapshot(34 * std.time.ns_per_s).phase);
}
test "parallel check success never hides another running task; task views retain identities" {
    const c = try core();
    defer testing.allocator.destroy(c);
    _ = try c.apply(e(.turn_started, "ai", "turn", "start", 1), 1);
    _ = try c.apply(checkEvent(.check_started, "start", 2), 2);
    _ = try c.apply(checkEvent(.check_passed, "pass", 3), 3);
    try testing.expectEqual(.working, c.snapshot(3).phase);
    const tasks = try c.list(testing.allocator, 3);
    defer testing.allocator.free(tasks);
    try testing.expectEqual(@as(usize, 2), tasks.len);
    try testing.expectEqualStrings("ai", tasks[0].session_id);
    try testing.expectEqual(.verified, tasks[1].phase);
    try testing.expect(tasks[1].ended);
}
test "new event fields require explicit event v2 and matching check type" {
    var v = checkEvent(.check_started, "start", 1);
    v.schema_version = 1;
    try testing.expectError(error.EventRequiresV2, v.validate());
    v.schema_version = 2;
    v.check_type = null;
    try testing.expectError(error.InvalidCheckEvent, v.validate());
    const c = try core();
    defer testing.allocator.destroy(c);
    _ = try c.apply(checkEvent(.check_started, "start", 1), 1);
    v = checkEvent(.check_passed, "done", 2);
    v.check_type = .build;
    try testing.expectError(error.InvalidCheckEvent, c.apply(v, 2));
    try testing.expectEqual(.checking, c.snapshot(2).phase);
}
test "theme v3 action contract validates speeds and preserves older export fields" {
    var t: themes.Theme = .{ .schema_version = 3, .actions = .{} };
    t.actions.?.attention = .{ .effect = .blink, .speed = 2 };
    try t.validate();
    try testing.expectEqual(.blink, t.action(.attention).effect);
    t.actions.?.attention.speed = 0;
    try testing.expectError(error.InvalidSpeed, t.validate());
    t.schema_version = 2;
    try testing.expectError(error.ActionsRequireThemeV3, t.validate());
    const bytes = try std.json.Stringify.valueAlloc(testing.allocator, themes.Theme{}, .{});
    defer testing.allocator.free(bytes);
    try testing.expect(std.mem.indexOf(u8, bytes, "checking") == null);
    try testing.expect(std.mem.indexOf(u8, bytes, "actions") == null);
}

test "old contracts reject new fields instead of silently changing semantics" {
    const allocator = testing.allocator;
    try testing.expectError(error.EventRequiresV2, @import("event.zig").parse(allocator, "{\"schema_version\":1,\"provider\":\"a\",\"session_id\":\"s\",\"turn_id\":\"t\",\"event_id\":\"e\",\"timestamp_ns\":1,\"kind\":\"turn_started\",\"attention_kind\":null}"));
    try testing.expectError(error.ActionsRequireThemeV3, themes.parse(allocator, "{\"schema_version\":2,\"actions\":null}"));
    try testing.expectError(error.SignalsRequireThemeV3, themes.parse(allocator, "{\"schema_version\":1,\"signals\":{\"checking\":{\"color\":\"#112233\",\"brightness\":50}}}"));
}

test "a terminal child does not replace the remaining root phase" {
    const c = try core();
    defer testing.allocator.destroy(c);
    _ = try c.apply(e(.turn_started, "ai", "turn", "start", 1), 1);
    _ = try c.apply(e(.output, "ai", "turn", "root-output", 2), 2);
    var child = e(.turn_started, "ai", "turn", "child-start", 3);
    child.task_id = "child";
    _ = try c.apply(child, 3);
    child.kind = .thinking;
    child.event_id = "child-thinking";
    child.timestamp_ns = 4;
    _ = try c.apply(child, 4);
    child.kind = .turn_completed;
    child.event_id = "child-done";
    child.timestamp_ns = 5;
    _ = try c.apply(child, 5);
    try testing.expectEqual(.output, c.snapshot(5).phase);
    try testing.expectEqual(@as(usize, 1), c.snapshot(5).active_tasks);
}
