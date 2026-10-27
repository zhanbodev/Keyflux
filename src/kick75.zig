const std = @import("std");
const p = @import("platform.zig");
const protocol = @import("protocol.zig");
const colors = @import("nuphy_color.zig");
const devices = @import("device.zig");
pub const Probe = struct {
    schema_version: u8 = 1,
    model_id: []const u8 = "nuphy-kick75-io",
    fingerprint: [64]u8,
    firmware: [8]u8,
    geometry: [8]u8,
    profile: u8,
    led_count: u8,
    state: [17]u8,
    input_bytes: u16,
    output_bytes: u16,
    read_only: bool = true,
};
pub const ReportShape = struct { input: u16 = 0, output: u16 = 0 };
/// Public recovery metadata; never exports the saved capture or USB identity.
pub const RecoveryStatus = struct {
    required: bool = false,
    pending: bool = false,
    compatible: bool = false,
    code: ?[]const u8 = null,
};
pub fn recoveryStatus(journal: ?Journal, current: ?Probe) RecoveryStatus {
    const saved = journal orelse return .{};
    var result: RecoveryStatus = .{ .required = true, .pending = saved.pending };
    if (current) |info| {
        saved.validate(info) catch |err| {
            result.code = @errorName(err);
            return result;
        };
        result.compatible = true;
    }
    return result;
}
pub const Journal = struct {
    schema_version: u8 = 1,
    format: []const u8 = "kick75-s4-main-v1",
    original: Probe,
    expected: [17]u8,
    pending: bool = false,
    pub fn guardSolid(self: Journal, current: Probe) !void {
        try self.validate(current);
        if (self.pending) return error.RecoveryRequired;
        if (!std.mem.eql(u8, self.expected[0..9], current.state[0..9])) return error.ConcurrentDeviceChange;
    }
    pub fn validate(self: Journal, current: Probe) !void {
        if (self.schema_version != 1 or !std.mem.eql(u8, self.format, "kick75-s4-main-v1")) return error.InvalidRecoveryRecord;
        try writable(self.original);
        try writable(current);
        if (!std.mem.eql(u8, &self.original.fingerprint, &current.fingerprint) or
            !std.mem.eql(u8, self.original.firmware[0..6], current.firmware[0..6]) or
            self.original.profile != current.profile) return error.RecoveryIdentityMismatch;
        try recoverable(self.original.state);
    }
};

/// This is deliberately narrower than USB recognition. New firmware/profile
/// combinations need their own protocol and recovery evidence before writes.
pub fn writable(info: Probe) !void {
    if (info.schema_version != 1 or !std.mem.eql(u8, info.model_id, "nuphy-kick75-io")) return error.IdentityMismatch;
    if (!std.mem.eql(u8, info.firmware[0..6], &.{ 18, 0, 4, 170, 6, 0 }) or
        !std.mem.eql(u8, info.geometry[0..5], &.{ 0, 8, 4, 6, 15 }) or
        info.led_count != 85 or info.input_bytes != 64 or info.output_bytes != 64)
        return error.UnverifiedFirmwareOrGeometry;
    if (info.profile != 0) return error.UnverifiedProfile;
}
pub fn recoverable(state: [17]u8) !void {
    try validStateFields(state);
    // Initial capture must remain representable under either observed path.
    // Unknown reconnect/cache behavior must not make the saved RGB impossible.
    _ = try colors.encodeExact(state[6..9].*);
}
fn validStateFields(state: [17]u8) !void {
    if (state[0] == 0 or (state[0] > 22 and state[0] != 255) or state[1] > 100 or state[2] > 4 or state[4] > 1 or state[5] != 0)
        return error.UnsupportedOriginalEffect;
}
pub fn solidState(original: [17]u8, rgb: @import("theme.zig").Color, brightness: u8) ![17]u8 {
    if (brightness > 100) return error.InvalidBrightness;
    var result = original;
    result[0] = 3; // Main STATIC_MODE; side STATIC_MODE is a different value (2).
    result[1] = brightness;
    result[4] = 0; // Single RGB color, disable the multi-color flag.
    result[5] = 0;
    result[6..9].* = colors.readback(.{ rgb.r, rgb.g, rgb.b });
    return result;
}
pub fn reportShape(bytes: []const u8) !ReportShape {
    var size: u32 = 0;
    var count: u32 = 0;
    var shape: ReportShape = .{};
    var i: usize = 0;
    while (i < bytes.len) {
        const tag = bytes[i];
        i += 1;
        if (tag == 0xfe) return error.UnsupportedHidDescriptor;
        const length: usize = switch (tag & 3) {
            3 => 4,
            else => tag & 3,
        };
        if (length > bytes.len - i) return error.InvalidHidDescriptor;
        var value: u32 = 0;
        for (bytes[i..][0..length], 0..) |b, shift| value |= @as(u32, b) << @as(u5, @intCast(shift * 8));
        i += length;
        switch (tag & 0xfc) {
            0x74 => size = value,
            0x94 => count = value,
            0x84, 0xa4, 0xb4 => return error.UnsupportedHidDescriptor,
            0x80, 0x90 => {
                const bits = @as(u64, size) * count;
                if (bits > 8192 or bits % 8 != 0) return error.InvalidHidDescriptor;
                const total = @as(u64, if ((tag & 0xfc) == 0x80) shape.input else shape.output) + bits / 8;
                if (total > 1024) return error.InvalidHidDescriptor;
                if ((tag & 0xfc) == 0x80) shape.input = @intCast(total) else shape.output = @intCast(total);
            },
            else => {},
        }
    }
    if (shape.input != 64 or shape.output != 64) return error.UnsupportedHidDescriptor;
    return shape;
}
pub fn decode(raw: protocol.Report, command: u8, length: u8, address: u16, profile: u8, key: u8) ![56]u8 {
    if (length > 56 or raw[0] != 0xaa or raw[1] != command or raw[2] != 0 or raw[3] != protocol.checksum(raw)) return error.InvalidReport;
    const route = [4]u8{ length, @truncate(address), @truncate(address >> 8), profile };
    var plain = true;
    var masked = true;
    for (route, raw[4..8]) |want, got| {
        plain = plain and want == got;
        masked = masked and want == (got ^ key);
    }
    if (!plain and !masked) return error.RouteMismatch;
    var result: [56]u8 = @splat(0);
    for (0..length) |i| result[i] = raw[8 + i] ^ key;
    return result;
}
pub fn frame(command: u8, length: u8, address: u16, profile: u8, key: u8, payload: []const u8) !protocol.Report {
    if (length > 56 or (payload.len != 0 and payload.len != length)) return error.InvalidLength;
    switch (command) {
        0xa0, 0xa1 => if (length != 8 or address != 0 or profile != 0 or payload.len != 0) return error.ForbiddenCommand,
        0xd1 => if (length != 1 or address != 0 or profile != 0 or payload.len != 0) return error.ForbiddenCommand,
        0xd5 => if (length != 17 or address != 0 or profile > 1 or payload.len != 0) return error.ForbiddenCommand,
        0xd6 => if (length != 9 or address != 0 or profile > 1 or payload.len != 9) return error.ForbiddenCommand,
        else => return error.ForbiddenCommand,
    }
    var result: protocol.Report = @splat(0);
    result[0] = 0x55;
    result[1] = command;
    result[4] = length ^ key;
    result[5] = @as(u8, @truncate(address)) ^ key;
    result[6] = @as(u8, @truncate(address >> 8)) ^ key;
    result[7] = profile ^ key;
    for (payload, 0..) |v, i| result[8 + i] = v ^ key;
    result[3] = protocol.checksum(result);
    return result;
}
pub const Keyboard = struct {
    key: u8 = 0,
    info: Probe = undefined,
    version: [32]u8 = undefined,
    version_len: usize = 0,
    pub fn exchange(self: *Keyboard, command: u8, length: u8, address: u16, profile: u8, payload: []const u8) ![56]u8 {
        const request = try frame(command, length, address, profile, self.key, payload);
        var reply: protocol.Report = undefined;
        try exchangeError(p.kf_kick_exchange(&request, &reply, self.key));
        return decode(reply, command, length, address, profile, self.key);
    }
    pub fn connect(self: *Keyboard) !void {
        var identity: [1024]u8 = undefined;
        const n = p.kf_kick_open(&identity, identity.len);
        if (n < 0) return switch (n) {
            -2 => error.DeviceBusy,
            -3 => error.DeviceNotFound,
            -4 => error.MultipleDevices,
            -5 => error.UnsupportedPlatform,
            -6 => error.MissingDeviceIdentity,
            else => error.HidOpenFailed,
        };
        errdefer p.kf_kick_close();
        var descriptor: [2048]u8 = undefined;
        const d = p.kf_kick_descriptor(&descriptor, descriptor.len);
        if (d <= 0) return error.InvalidHidDescriptor;
        const shape = try reportShape(descriptor[0..@intCast(d)]);
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(identity[0..@intCast(n)], &digest, .{});
        const request = try frame(0xa1, 8, 0, 0, 0, &.{});
        var reply: protocol.Report = undefined;
        try exchangeError(p.kf_kick_exchange(&request, &reply, 0));
        self.key = reply[11] ^ 0xaa;
        const firmware = try decode(reply, 0xa1, 8, 0, 0, self.key);
        const geometry = try self.exchange(0xa0, 8, 0, 0, &.{});
        if (geometry[0] > 1) return error.UnsupportedProfile;
        const count = try self.exchange(0xd1, 1, 0, 0, &.{});
        const state = try self.exchange(0xd5, 17, 0, geometry[0], &.{});
        self.info = .{ .fingerprint = std.fmt.bytesToHex(digest, .lower), .firmware = firmware[0..8].*, .geometry = geometry[0..8].*, .profile = geometry[0], .led_count = count[0], .state = state[0..17].*, .input_bytes = shape.input, .output_bytes = shape.output };
        self.version_len = (try std.fmt.bufPrint(&self.version, "{d}.{d}.{d}.{d}", .{ firmware[2], firmware[1], firmware[0], @as(u16, firmware[4]) | (@as(u16, firmware[5]) << 8) })).len;
    }
    pub fn close(_: *Keyboard) void {
        p.kf_kick_close();
    }
    pub fn readState(self: *Keyboard) ![17]u8 {
        const geometry = try self.exchange(0xa0, 8, 0, 0, &.{});
        if (geometry[0] != self.info.profile) return error.ProfileChanged;
        const state = try self.exchange(0xd5, 17, 0, self.info.profile, &.{});
        return state[0..17].*;
    }
    pub fn setMain(self: *Keyboard, expected: [9]u8, input: [9]u8) ![17]u8 {
        return writeMain(self, expected, input);
    }
    pub fn restoreMain(self: *Keyboard, expected: [9]u8) ![17]u8 {
        return restoreExact(self, expected);
    }
    pub fn delay(_: *Keyboard, ms: u32) void {
        p.kf_sleep_ms(ms);
    }
    pub fn writeData(self: *Keyboard, data: [9]u8) !void {
        _ = try self.exchange(0xd6, 9, 0, self.info.profile, &data);
    }
    pub fn driver(self: *Keyboard) devices.KeyboardDriver {
        return .{ .context = self, .vtable = &vtable };
    }
    fn cast(context: *anyopaque) *Keyboard {
        return @ptrCast(@alignCast(context));
    }
    fn probe(context: *anyopaque) !devices.Identity {
        const self = cast(context);
        _ = try self.readState();
        return .{ .model_id = self.info.model_id, .firmware = self.version[0..self.version_len], .profile = if (self.info.profile == 0) "mac" else "win" };
    }
    fn caps(context: *anyopaque) devices.Capabilities {
        writable(cast(context).info) catch return .{};
        return .{ .solid_main = true, .readback = true, .restore = true };
    }
    fn capture(context: *anyopaque) !devices.Capture {
        const self = cast(context);
        _ = try probe(context);
        const state = try self.readState();
        try recoverable(state);
        self.info.state = state;
        return captured(self.info);
    }
    fn solid(context: *anyopaque, value: devices.Lighting) !void {
        const self = cast(context);
        const current = try self.readState();
        if (!std.mem.eql(u8, &current, &self.info.state)) return error.ConcurrentDeviceChange;
        const target = try solidState(current, value.color, value.brightness);
        var input = target[0..9].*;
        input[6..9].* = .{ value.color.r, value.color.g, value.color.b };
        _ = try writeSolid(self, target[0..9].*, input);
    }
    fn restore(context: *anyopaque, original: devices.Capture) !void {
        const self = cast(context);
        const identity = try probe(context);
        const main = try validateCapture(original, self.info, identity);
        _ = try self.restoreMain(main);
    }
    const vtable: devices.KeyboardDriver.VTable = .{ .probe = probe, .capabilities = caps, .capture = capture, .setSolid = solid, .restore = restore };
};
pub fn captured(info: Probe) !devices.Capture {
    try writable(info);
    try validStateFields(info.state);
    return .{ .identity = .{ .model_id = info.model_id, .firmware = "4.0.18.6", .profile = "mac" }, .main = .{ .color = .{ .r = info.state[6], .g = info.state[7], .b = info.state[8] }, .brightness = info.state[1] }, .native = .{ .nuphy_s4_main_v1 = .{ .fingerprint = info.fingerprint, .state = info.state } } };
}
pub fn validateCapture(original: devices.Capture, current: Probe, identity: devices.Identity) ![9]u8 {
    try writable(current);
    if (!std.mem.eql(u8, original.identity.model_id, identity.model_id) or
        !std.mem.eql(u8, original.identity.firmware, identity.firmware) or
        !std.mem.eql(u8, original.identity.profile, identity.profile)) return error.IdentityMismatch;
    const native = original.native orelse return error.MissingNativeCapture;
    const raw = native.nuphy_s4_main_v1;
    if (!std.mem.eql(u8, &raw.fingerprint, &current.fingerprint)) return error.IdentityMismatch;
    try validStateFields(raw.state);
    return raw.state[0..9].*;
}
pub fn writeMain(device: anytype, expected: [9]u8, input: [9]u8) ![17]u8 {
    return writeChecked(device, expected, input, false);
}
pub fn writeSolid(device: anytype, expected: [9]u8, input: [9]u8) ![17]u8 {
    if (expected[0] != 3 or expected[4] != 0 or !std.mem.eql(u8, expected[0..6], input[0..6]) or
        !std.mem.eql(u8, expected[6..9], &colors.readback(input[6..9].*))) return error.InvalidSolidTarget;
    return writeChecked(device, expected, input, true);
}
pub fn solidMatches(expected: [17]u8, input: [9]u8, observed: [17]u8) bool {
    return std.mem.eql(u8, &expected, &observed) or
        (std.mem.eql(u8, &input, observed[0..9]) and std.mem.eql(u8, expected[9..17], observed[9..17]));
}
fn writeChecked(device: anytype, expected: [9]u8, input: [9]u8, accept_direct: bool) ![17]u8 {
    try writable(device.info);
    const before = try device.readState();
    // Manual-only; persistence/flash behavior remains unverified.
    device.delay(1000);
    const latest = try device.readState();
    if (!std.mem.eql(u8, &before, &latest)) return error.ConcurrentDeviceChange;
    try device.writeData(input);
    device.delay(150);
    const after = try device.readState();
    if (!std.mem.eql(u8, before[9..17], after[9..17])) return error.SideStateChanged;
    if (!std.mem.eql(u8, &expected, after[0..9]) and !(accept_direct and std.mem.eql(u8, &input, after[0..9]))) return error.ReadbackMismatch;
    return after;
}
pub fn restoreExact(device: anytype, expected: [9]u8) ![17]u8 {
    const before = try device.readState();
    return writeMain(device, expected, expected) catch |err| {
        if (err != error.ReadbackMismatch) return err;
        const observed = try device.readState();
        var projected = expected;
        projected[6..9].* = colors.readback(expected[6..9].*);
        // A second, DIFFERENT payload is allowed only after a successful ACK
        // and exact evidence of the known HSV transform. Never retry timeouts,
        // unexpected changes or an already ambiguous setter.
        if (!std.mem.eql(u8, &projected, observed[0..9]) or
            !std.mem.eql(u8, before[9..17], observed[9..17])) return err;
        var inverse = expected;
        inverse[6..9].* = try colors.encodeExact(expected[6..9].*);
        if (std.mem.eql(u8, &inverse, &expected)) return err;
        return writeMain(device, expected, inverse);
    };
}
fn exchangeError(result: c_int) !void {
    if (result == 0) return;
    return switch (result) {
        -7 => error.ForbiddenCommand,
        -8 => error.HidWriteFailed,
        -9 => error.DeviceDisconnected,
        -10 => error.HidTimeout,
        else => error.HidUnavailable,
    };
}
