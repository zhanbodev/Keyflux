//! OTLP/HTTP JSON and protobuf logs, parsed without retaining body/content.
const std = @import("std");
const codex = @import("codex.zig");
pub const Record = struct {
    name: []const u8 = "",
    kind: []const u8 = "",
    session_id: []const u8 = "",
    turn_id: ?[]const u8 = null,
    timestamp_ns: u64 = 0,
};
pub const Batch = struct { records: std.ArrayList(Record) = .empty, total: usize = 0 };
fn assign(r: *Record, key: []const u8, value: []const u8) !void {
    const eq = std.mem.eql;
    const allowed = eq(u8, key, "event.name") or eq(u8, key, "event_name") or eq(u8, key, "event.kind") or eq(u8, key, "event_kind") or eq(u8, key, "kind") or eq(u8, key, "conversation.id") or eq(u8, key, "conversation_id") or eq(u8, key, "session_id") or eq(u8, key, "turn_id");
    if (!allowed) return;
    if (value.len > 192) return error.InvalidAttribute;
    if (eq(u8, key, "event.name") or eq(u8, key, "event_name")) r.name = value else if (eq(u8, key, "event.kind") or eq(u8, key, "event_kind") or eq(u8, key, "kind")) r.kind = value else if (eq(u8, key, "turn_id")) r.turn_id = value else r.session_id = value;
}
fn append(a: std.mem.Allocator, batch: *Batch, r: Record) !void {
    batch.total += 1;
    if (batch.total > 2048) return error.TooManyRecords;
    if (std.mem.eql(u8, r.name, "codex.sse_event") or std.mem.eql(u8, r.name, "codex.websocket_event")) try batch.records.append(a, r);
}

const Value = std.json.Value;
fn jsonAttributes(r: *Record, v: ?Value) !void {
    const attrs = v orelse return;
    if (attrs != .array) return error.InvalidOtlp;
    for (attrs.array.items) |attr| {
        const key = codex.string(codex.field(attr, "key")) orelse continue;
        const value = codex.field(attr, "value") orelse continue;
        const text = codex.string(codex.field(value, "stringValue")) orelse continue;
        try assign(r, key, text);
    }
}
fn array(v: ?Value) ![]Value {
    const x = v orelse return &.{};
    return if (x == .array) x.array.items else error.InvalidOtlp;
}
pub fn json(a: std.mem.Allocator, bytes: []const u8) !Batch {
    const p = try std.json.parseFromSlice(Value, a, bytes, .{ .max_value_len = 512 * 1024 });
    // The caller's per-request arena owns both parsed strings and the result.
    var batch: Batch = .{};
    for (try array(codex.field(p.value, "resourceLogs"))) |resource| {
        var base: Record = .{};
        if (codex.field(resource, "resource")) |v| try jsonAttributes(&base, codex.field(v, "attributes"));
        for (try array(codex.field(resource, "scopeLogs"))) |scope| {
            for (try array(codex.field(scope, "logRecords"))) |record| {
                var r = base;
                try jsonAttributes(&r, codex.field(record, "attributes"));
                if (codex.string(codex.field(record, "eventName"))) |name| r.name = name;
                if (codex.string(codex.field(record, "timeUnixNano"))) |t| r.timestamp_ns = std.fmt.parseInt(u64, t, 10) catch return error.InvalidTimestamp;
                try append(a, &batch, r);
            }
        }
    }
    return batch;
}

const Field = struct { number: u32, wire: u3, bytes: []const u8 = "", integer: u64 = 0 };
const Decoder = struct {
    bytes: []const u8,
    pos: usize = 0,
    fn varint(self: *Decoder) !u64 {
        var n: u64 = 0;
        for (0..10) |i| {
            if (self.pos == self.bytes.len) return error.TruncatedProtobuf;
            const b = self.bytes[self.pos];
            self.pos += 1;
            if (i == 9 and b > 1) return error.InvalidProtobuf;
            n |= @as(u64, b & 127) << @as(u6, @intCast(i * 7));
            if (b < 128) return n;
        }
        return error.InvalidProtobuf;
    }
    fn take(self: *Decoder, n: usize) ![]const u8 {
        if (n > self.bytes.len - self.pos) return error.TruncatedProtobuf;
        const out = self.bytes[self.pos..][0..n];
        self.pos += n;
        return out;
    }
    fn next(self: *Decoder) !?Field {
        if (self.pos == self.bytes.len) return null;
        const tag = try self.varint();
        if (tag >> 3 == 0 or tag >> 3 > 0x1fffffff) return error.InvalidProtobuf;
        var f: Field = .{ .number = @intCast(tag >> 3), .wire = @truncate(tag) };
        switch (f.wire) {
            0 => f.integer = try self.varint(),
            1 => f.integer = std.mem.readInt(u64, (try self.take(8))[0..8], .little),
            2 => {
                const n = try self.varint();
                if (n > self.bytes.len) return error.TruncatedProtobuf;
                f.bytes = try self.take(@intCast(n));
            },
            5 => _ = try self.take(4),
            else => return error.InvalidProtobuf,
        }
        return f;
    }
};
fn protoAttribute(r: *Record, bytes: []const u8) !void {
    var d: Decoder = .{ .bytes = bytes };
    var key: []const u8 = "";
    var text: []const u8 = "";
    while (try d.next()) |f| {
        if (f.wire != 2) continue;
        if (f.number == 1) key = f.bytes;
        if (f.number == 2) {
            var value: Decoder = .{ .bytes = f.bytes };
            while (try value.next()) |v| if (v.number == 1 and v.wire == 2) {
                text = v.bytes;
            };
        }
    }
    try assign(r, key, text);
}
pub fn protobuf(a: std.mem.Allocator, bytes: []const u8) !Batch {
    var batch: Batch = .{};
    var request: Decoder = .{ .bytes = bytes };
    while (try request.next()) |resource_field| {
        if (resource_field.number != 1 or resource_field.wire != 2) continue;
        var resource: Decoder = .{ .bytes = resource_field.bytes };
        var base: Record = .{};
        // Protobuf field order is not guaranteed: read resource metadata first.
        while (try resource.next()) |f| if (f.number == 1 and f.wire == 2) {
            var metadata: Decoder = .{ .bytes = f.bytes };
            while (try metadata.next()) |attr| if (attr.number == 1 and attr.wire == 2) {
                try protoAttribute(&base, attr.bytes);
            };
        };
        resource.pos = 0;
        while (try resource.next()) |f| {
            if (f.number != 2 or f.wire != 2) continue;
            var scope: Decoder = .{ .bytes = f.bytes };
            while (try scope.next()) |log| {
                if (log.number != 2 or log.wire != 2) continue;
                var r = base;
                var record: Decoder = .{ .bytes = log.bytes };
                while (try record.next()) |v| {
                    if (v.number == 1 and v.wire == 1) r.timestamp_ns = v.integer;
                    if (v.number == 6 and v.wire == 2) try protoAttribute(&r, v.bytes);
                    if (v.number == 12 and v.wire == 2) r.name = v.bytes;
                }
                try append(a, &batch, r);
            }
        }
    }
    return batch;
}

test "protobuf rejects malformed lengths, overflowing varints and invalid tags" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.TruncatedProtobuf, protobuf(a, &.{ 0x0a, 0x7f }));
    try std.testing.expectError(error.InvalidProtobuf, protobuf(a, &.{0}));
    try std.testing.expectError(error.InvalidProtobuf, protobuf(a, &.{ 255, 255, 255, 255, 255, 255, 255, 255, 255, 2 }));
}
