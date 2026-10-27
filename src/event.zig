const std = @import("std");

pub const CheckType = enum { @"test", build };
pub const Phase = enum { idle, working, thinking, output, tool, attention, complete, checking, verified, check_failed, @"error", unknown };
pub const Kind = enum { turn_started, working, thinking, output, tool_started, tool_finished, attention, attention_resolved, turn_completed, turn_cancelled, turn_failed, source_lost, source_resumed, session_ended, check_started, check_passed, check_failed, check_cancelled };

/// Borrowed strings: valid only for the duration of Engine.apply(). No content fields.
pub const Event = struct {
    schema_version: u8,
    provider: []const u8,
    session_id: []const u8,
    turn_id: []const u8,
    event_id: []const u8,
    timestamp_ns: u64,
    kind: Kind,
    task_id: ?[]const u8 = null,
    request_id: ?[]const u8 = null,
    tool_name: ?[]const u8 = null,

    label: ?[]const u8 = null,
    check_type: ?CheckType = null,
    attention_kind: ?enum { approval, input } = null,

    pub fn jsonStringify(self: Event, writer: anytype) !void {
        if (self.schema_version == 1) {
            try writer.write(.{ .schema_version = self.schema_version, .provider = self.provider, .session_id = self.session_id, .turn_id = self.turn_id, .event_id = self.event_id, .timestamp_ns = self.timestamp_ns, .kind = self.kind, .task_id = self.task_id, .request_id = self.request_id, .tool_name = self.tool_name });
        } else {
            try writer.write(.{ .schema_version = self.schema_version, .provider = self.provider, .session_id = self.session_id, .turn_id = self.turn_id, .event_id = self.event_id, .timestamp_ns = self.timestamp_ns, .kind = self.kind, .task_id = self.task_id, .request_id = self.request_id, .tool_name = self.tool_name, .check_type = self.check_type, .attention_kind = self.attention_kind, .label = self.label });
        }
    }
    pub fn validate(self: Event) !void {
        if (self.schema_version != 1 and self.schema_version != 2) return error.UnsupportedVersion;
        const check = self.kind == .check_started or self.kind == .check_passed or self.kind == .check_failed or self.kind == .check_cancelled;
        if (self.schema_version == 1 and (check or self.check_type != null or self.attention_kind != null or self.label != null)) return error.EventRequiresV2;
        if (self.label) |label| {
            try validId(label);
            if (label.len > 64 or (self.kind != .turn_started and self.kind != .check_started)) return error.InvalidTaskLabel;
        }
        if (check and (self.check_type == null or self.task_id != null)) return error.InvalidCheckEvent;
        if (!check and self.check_type != null) return error.InvalidCheckEvent;
        if (self.attention_kind != null and self.kind != .attention) return error.InvalidAttentionKind;
        for ([_][]const u8{ self.provider, self.session_id, self.turn_id, self.event_id }) |id| try validId(id);
        if (self.task_id) |id| {
            try validId(id);
            if (id[0] == '@') return error.ReservedIdentifier;
        }
        if (self.request_id) |id| try validId(id);
        if (self.tool_name) |id| try validId(id);
        if (self.timestamp_ns == 0) return error.InvalidTimestamp;
        if ((self.kind == .tool_started or self.kind == .tool_finished or self.kind == .attention or self.kind == .attention_resolved) and self.request_id == null) return error.MissingRequestId;
    }
};

pub fn validId(id: []const u8) !void {
    if (id.len == 0 or id.len > 192) return error.InvalidIdentifier;
    for (id) |c| if (c < 0x21 or c > 0x7e) return error.InvalidIdentifier;
}

pub fn parse(a: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(Event) {
    if (bytes.len > 16 * 1024) return error.PayloadTooLarge;
    const parsed = try std.json.parseFromSlice(Event, a, bytes, .{});
    errdefer parsed.deinit();
    try parsed.value.validate();
    if (parsed.value.schema_version == 1) {
        const raw = try std.json.parseFromSlice(std.json.Value, a, bytes, .{});
        defer raw.deinit();
        for ([_][]const u8{ "check_type", "attention_kind", "label" }) |field| if (raw.value.object.contains(field)) return error.EventRequiresV2;
    }
    return parsed;
}
