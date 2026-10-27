const std = @import("std");

pub const Phase = enum { idle, working, thinking, output, tool, attention, complete, @"error", unknown };
pub const Kind = enum { turn_started, working, thinking, output, tool_started, tool_finished, attention, attention_resolved, turn_completed, turn_cancelled, turn_failed, source_lost, source_resumed, session_ended };

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

    pub fn validate(self: Event) !void {
        if (self.schema_version != 1) return error.UnsupportedVersion;
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
    return parsed;
}
