const std = @import("std");
const k = @import("kick75.zig");
const colors = @import("nuphy_color.zig");
const protocol = @import("protocol.zig");
const expect = std.testing.expect;
const expectError = std.testing.expectError;
const eql = std.testing.expectEqualSlices;

pub fn fixture() k.Probe {
    return .{ .fingerprint = @splat('a'), .firmware = .{ 18, 0, 4, 170, 6, 0, 240, 240 }, .geometry = .{ 0, 8, 4, 6, 15, 130, 240, 240 }, .profile = 0, .led_count = 85, .state = .{ 2, 60, 2, 0, 1, 0, 153, 153, 153, 0, 60, 2, 1, 0, 255, 0, 0 }, .input_bytes = 64, .output_bytes = 64 };
}

test "Kick75 validates HID shape and command boundaries" {
    const shape = try k.reportShape(&.{ 0x75, 8, 0x95, 64, 0x81, 2, 0x91, 2 });
    try expect(shape.input == 64 and shape.output == 64);
    try expectError(error.UnsupportedHidDescriptor, k.reportShape(&.{ 0x85, 1 }));
    try expectError(error.InvalidHidDescriptor, k.reportShape(&.{ 0x77, 8 }));
    try expectError(error.InvalidHidDescriptor, k.reportShape(&.{ 0x75, 7, 0x95, 1, 0x81, 2 }));
    try expectError(error.UnsupportedHidDescriptor, k.reportShape(&.{ 0x75, 8, 0x95, 63, 0x81, 2, 0x91, 2 }));
    try expectError(error.ForbiddenCommand, k.frame(0xee, 1, 0, 0, 240, &.{1}));
    try expectError(error.ForbiddenCommand, k.frame(0xd6, 9, 9, 0, 240, &@as([9]u8, @splat(0))));
    try expectError(error.ForbiddenCommand, k.frame(0xd6, 17, 0, 0, 240, &@as([17]u8, @splat(0))));
    try expectError(error.ForbiddenCommand, k.frame(0xd6, 9, 0, 2, 240, &@as([9]u8, @splat(0))));
}

test "Kick75 encrypted and plain reply routes require checksum and profile" {
    var raw = try k.frame(0xd6, 9, 0, 0, 240, fixture().state[0..9]);
    raw[0] = 0xaa;
    const data = try k.decode(raw, 0xd6, 9, 0, 0, 240);
    try eql(u8, fixture().state[0..9], data[0..9]);
    raw[4..8].* = .{ 9, 0, 0, 0 };
    raw[3] = protocol.checksum(raw);
    _ = try k.decode(raw, 0xd6, 9, 0, 0, 240);
    try expectError(error.RouteMismatch, k.decode(raw, 0xd6, 9, 0, 1, 240));
    raw[10] ^= 1;
    try expectError(error.InvalidReport, k.decode(raw, 0xd6, 9, 0, 0, 240));
}

test "Kick75 firmware gate and durable recovery bind original identity" {
    const original = fixture();
    var journal = k.Journal{ .original = original, .expected = original.state };
    try journal.validate(original);
    var other = original;
    other.fingerprint[0] = 'b';
    try expectError(error.RecoveryIdentityMismatch, journal.validate(other));
    other = original;
    other.firmware[0] += 1;
    try expectError(error.UnverifiedFirmwareOrGeometry, journal.validate(other));
    other = original;
    other.profile = 1;
    try expectError(error.UnverifiedProfile, journal.validate(other));
    journal.schema_version = 2;
    try expectError(error.InvalidRecoveryRecord, journal.validate(original));
    var custom = original.state;
    custom[0] = 0;
    try expectError(error.UnsupportedOriginalEffect, k.recoverable(custom));
}

test "Kick75 solid state retains side fields and predicts color quantization" {
    const original = fixture().state;
    const solid = try k.solidState(original, .{ .r = 128, .g = 0, .b = 255 }, 15);
    try eql(u8, original[9..], solid[9..]);
    try eql(u8, &.{ 3, 15, 2, 0, 0, 0, 132, 0, 255 }, solid[0..9]);
    try expectError(error.InvalidBrightness, k.solidState(original, .{ .r = 0, .g = 0, .b = 0 }, 101));
}

test "byte HSV inverse recovers exact saved RGB without cumulative drift" {
    const requests = [_][3]u8{ .{ 255, 0, 0 }, .{ 0, 255, 255 }, .{ 128, 0, 255 }, .{ 59, 130, 246 }, .{ 6, 182, 212 }, .{ 139, 92, 246 }, .{ 64, 0, 14 }, .{ 153, 153, 153 } };
    for (requests) |input| {
        const saved = colors.readback(input);
        const encoded = try colors.encodeExact(saved);
        try eql(u8, &saved, &colors.readback(encoded));
    }
    try eql(u8, &.{ 132, 0, 255 }, &colors.readback(.{ 128, 0, 255 }));
    try eql(u8, &.{ 153, 153, 153 }, &colors.readback(.{ 153, 153, 153 }));
    try expectError(error.RestoreColorUnrepresentable, colors.encodeExact(.{ 2, 2, 2 }));
}

const Mock = struct {
    info: k.Probe = fixture(),
    state: [17]u8 = fixture().state,
    writes: usize = 0,
    reads: usize = 0,
    delay_ms: u32 = 0,
    fail_write: bool = false,
    side_changed: bool = false,
    bad_readback: bool = false,
    mutate_before_write: bool = false,
    direct: bool = false,
    rgb_error: bool = false,
    pub fn readState(self: *@This()) ![17]u8 {
        self.reads += 1;
        if (self.mutate_before_write and self.reads == 2) self.state[1] += 1;
        return self.state;
    }
    pub fn delay(self: *@This(), ms: u32) void {
        self.delay_ms += ms;
    }
    pub fn writeData(self: *@This(), input: [9]u8) !void {
        self.writes += 1;
        if (self.fail_write) return error.DeviceDisconnected;
        self.state[0..9].* = input;
        if (!self.direct) self.state[6..9].* = colors.readback(input[6..9].*);
        if (self.rgb_error) self.state[6] += 1;
        if (self.side_changed) self.state[10] += 1;
        if (self.bad_readback) self.state[1] += 1;
    }
};

test "mock HID verifies one main write, rate limit, readback and side isolation" {
    var device: Mock = .{};
    const target = try k.solidState(device.state, .{ .r = 128, .g = 0, .b = 255 }, 15);
    var wire = target[0..9].*;
    wire[6..9].* = .{ 128, 0, 255 };
    const result = try k.writeMain(&device, target[0..9].*, wire);
    try eql(u8, &target, &result);
    try expect(device.writes == 1 and device.reads == 3 and device.delay_ms == 1150);
    const restore = fixture().state;
    _ = try k.writeMain(&device, restore[0..9].*, restore[0..9].*);
    try eql(u8, &restore, &device.state);
}

test "mock HID refuses concurrent changes and never retries ambiguous writes" {
    const main = fixture().state[0..9].*;
    var device: Mock = .{ .mutate_before_write = true };
    try expectError(error.ConcurrentDeviceChange, k.writeMain(&device, main, main));
    try expect(device.writes == 0);
    device = .{ .fail_write = true };
    try expectError(error.DeviceDisconnected, k.writeMain(&device, main, main));
    try expect(device.writes == 1);
    device = .{ .side_changed = true };
    try expectError(error.SideStateChanged, k.writeMain(&device, main, main));
    device = .{ .bad_readback = true };
    try expectError(error.ReadbackMismatch, k.writeMain(&device, main, main));
    device = .{};
    device.info.firmware[0] = 99;
    try expectError(error.UnverifiedFirmwareOrGeometry, k.writeMain(&device, main, main));
    try expect(device.writes == 0);
}

test "native capture preserves the factory effect and cannot restore another device" {
    const info = fixture();
    const capture = try k.captured(info);
    try expect(capture.native != null);
    const main = try k.validateCapture(capture, info, capture.identity);
    try eql(u8, info.state[0..9], &main);
    try expect(main[0] == 2 and main[4] == 1); // Not reduced to static RGB.
    var other = info;
    other.fingerprint[0] = 'b';
    try expectError(error.IdentityMismatch, k.validateCapture(capture, other, capture.identity));
    var incomplete = capture;
    incomplete.native = null;
    try expectError(error.MissingNativeCapture, k.validateCapture(incomplete, info, capture.identity));
    var identity = capture.identity;
    identity.firmware = "unknown";
    try expectError(error.IdentityMismatch, k.validateCapture(capture, info, identity));
}

test "pending hardware transaction requires explicit restore before another color" {
    const info = fixture();
    var journal = k.Journal{ .original = info, .expected = info.state };
    try journal.guardSolid(info);
    journal.pending = true;
    try expectError(error.RecoveryRequired, journal.guardSolid(info));
    journal.pending = false;
    journal.expected[1] += 1;
    try expectError(error.ConcurrentDeviceChange, journal.guardSolid(info));
}

test "native recovery capture survives JSON serialization without losing mode bytes" {
    const a = std.testing.allocator;
    const original = try k.captured(fixture());
    const bytes = try std.json.Stringify.valueAlloc(a, original, .{});
    defer a.free(bytes);
    const parsed = try std.json.parseFromSlice(@import("device.zig").Capture, a, bytes, .{});
    defer parsed.deinit();
    const restored = try k.validateCapture(parsed.value, fixture(), original.identity);
    try eql(u8, fixture().state[0..9], &restored);
}

test "solid acknowledgements accept exactly the observed direct or HSV forms" {
    const target = try k.solidState(fixture().state, .{ .r = 128, .g = 0, .b = 255 }, 15);
    var wire = target[0..9].*;
    wire[6..9].* = .{ 128, 0, 255 };
    var direct: Mock = .{ .direct = true };
    const raw = try k.writeSolid(&direct, target[0..9].*, wire);
    try expect(raw[6] == 128);
    try expect(k.solidMatches(target, wire, raw));
    var hsv: Mock = .{};
    const quantized = try k.writeSolid(&hsv, target[0..9].*, wire);
    try expect(quantized[6] == 132);
    try expect(k.solidMatches(target, wire, quantized));
    var corrupt: Mock = .{ .direct = true, .rgb_error = true };
    try expectError(error.ReadbackMismatch, k.writeSolid(&corrupt, target[0..9].*, wire));
    var wrong = raw;
    wrong[7] = 1;
    try expect(!k.solidMatches(target, wire, wrong));
}

test "exact restore selects a different encoder only with proven HSV readback" {
    var saved = fixture().state[0..9].*;
    saved[6..9].* = .{ 64, 0, 17 }; // Sending this RGB directly through HSV drifts.
    var hsv: Mock = .{};
    const recovered = try k.restoreExact(&hsv, saved);
    try eql(u8, &saved, recovered[0..9]);
    try expect(hsv.writes == 2);
    var direct: Mock = .{ .direct = true };
    const passthrough = try k.restoreExact(&direct, saved);
    try eql(u8, &saved, passthrough[0..9]);
    try expect(direct.writes == 1);
    var failed: Mock = .{ .fail_write = true };
    try expectError(error.DeviceDisconnected, k.restoreExact(&failed, saved));
    try expect(failed.writes == 1);
    var unexpected: Mock = .{ .bad_readback = true };
    try expectError(error.ReadbackMismatch, k.restoreExact(&unexpected, saved));
    try expect(unexpected.writes == 1);
}
