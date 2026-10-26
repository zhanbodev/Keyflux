const std = @import("std");
const Phase = @import("event.zig").Phase;
pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,
    pub fn parse(hex: []const u8) !Color {
        if (hex.len != 7 or hex[0] != '#') return error.InvalidColor;
        for (hex[1..]) |c| if (!((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F'))) return error.InvalidColor;
        const n = std.fmt.parseInt(u24, hex[1..], 16) catch return error.InvalidColor;
        return .{ .r = @intCast(n >> 16), .g = @intCast((n >> 8) & 255), .b = @intCast(n & 255) };
    }
};
pub const Signal = struct { color: []const u8, brightness: u8 };
pub const Signals = struct {
    working: Signal = .{ .color = "#3B82F6", .brightness = 50 },
    thinking: Signal = .{ .color = "#06B6D4", .brightness = 50 },
    output: Signal = .{ .color = "#8B5CF6", .brightness = 50 },
    tool: Signal = .{ .color = "#3B82F6", .brightness = 50 },
    attention: Signal = .{ .color = "#F97316", .brightness = 50 },
    complete: Signal = .{ .color = "#22C55E", .brightness = 50 },
    @"error": Signal = .{ .color = "#EF4444", .brightness = 50 },
};
pub const Theme = struct {
    schema_version: u8 = 1,
    name: []const u8 = "Keyflux",
    completion_hold_ms: u32 = 5000,
    signals: Signals = .{},
    pub fn validate(self: Theme) !void {
        if (self.schema_version != 1) return error.UnsupportedVersion;
        if (self.name.len == 0 or self.name.len > 64) return error.InvalidThemeName;
        if (self.completion_hold_ms < 1000 or self.completion_hold_ms > 60000) return error.InvalidDuration;
        inline for (@typeInfo(Signals).@"struct".field_names) |name| {
            const s = @field(self.signals, name);
            _ = try Color.parse(s.color);
            if (s.brightness > 100) return error.InvalidBrightness;
        }
    }
    pub fn signal(self: Theme, phase: Phase) ?Signal {
        return switch (phase) {
            .idle, .unknown => null,
            inline else => |p| @field(self.signals, @tagName(p)),
        };
    }
};
pub fn parse(a: std.mem.Allocator, data: []const u8) !std.json.Parsed(Theme) {
    if (data.len > 16384) return error.PayloadTooLarge;
    const value = try std.json.parseFromSlice(Theme, a, data, .{ .allocate = .alloc_always });
    errdefer value.deinit();
    try value.value.validate();
    return value;
}
