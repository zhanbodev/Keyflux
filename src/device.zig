const std = @import("std");
const theme = @import("theme.zig");
pub const Capabilities = struct {
    solid_main: bool = false,
    solid_side: bool = false,
    per_key: bool = false,
    readback: bool = false,
    restore: bool = false,
    max_frames_per_second: u16 = 0,
};
// Frozen serialized model-v1 capabilities. Runtime driver capabilities may
// grow independently; side metadata needs an explicitly versioned model format.
pub const ModelCapabilitiesV1 = struct {
    solid_main: bool = false,
    per_key: bool = false,
    readback: bool = false,
    restore: bool = false,
    max_frames_per_second: u16 = 0,
};
pub const Identity = struct { model_id: []const u8, firmware: []const u8, profile: []const u8 };
pub const Zone = enum { main, side };
pub const Lighting = struct { color: theme.Color, brightness: u8 };
pub const Capture = struct {
    identity: Identity,
    main: Lighting,
    // Source-level variants are compiled and reviewed, never supplied as HID
    // commands by model files. null preserves the simulation capture contract.
    native: ?union(enum) {
        nuphy_s4_main_v1: struct { fingerprint: [64]u8, state: [17]u8 },
    } = null,
};

/// Drivers are compiled into the registry; callers never receive raw HID access.
pub const KeyboardDriver = struct {
    context: *anyopaque,
    vtable: *const VTable,
    pub const VTable = struct {
        probe: *const fn (*anyopaque) anyerror!Identity,
        capabilities: *const fn (*anyopaque) Capabilities,
        capture: *const fn (*anyopaque) anyerror!Capture,
        setSolid: *const fn (*anyopaque, Lighting) anyerror!void,
        restore: *const fn (*anyopaque, Capture) anyerror!void,
        setSideSolid: ?*const fn (*anyopaque, Lighting) anyerror!void = null,
    };
    pub fn probe(self: KeyboardDriver) !Identity {
        return self.vtable.probe(self.context);
    }
    pub fn capabilities(self: KeyboardDriver) Capabilities {
        return self.vtable.capabilities(self.context);
    }
    pub fn capture(self: KeyboardDriver) !Capture {
        return self.vtable.capture(self.context);
    }
    pub fn setSolid(self: KeyboardDriver, value: Lighting) !void {
        if (value.brightness > 100) return error.InvalidBrightness;
        if (!self.capabilities().solid_main) return error.UnsupportedCapability;
        try self.vtable.setSolid(self.context, value);
    }
    pub fn setZoneSolid(self: KeyboardDriver, zone: Zone, value: Lighting) !void {
        if (value.brightness > 100) return error.InvalidBrightness;
        if (zone == .main) return self.setSolid(value);
        if (!self.capabilities().solid_side or !self.capabilities().restore) return error.UnsupportedCapability;
        const setter = self.vtable.setSideSolid orelse return error.UnsupportedCapability;
        try setter(self.context, value);
    }
    pub fn restore(self: KeyboardDriver, original: Capture) !void {
        if (!self.capabilities().restore) return error.UnsupportedCapability;
        try self.vtable.restore(self.context, original);
    }
};

pub const Simulated = struct {
    connected: bool = true,
    firmware: []const u8 = "sim-1",
    profile: []const u8 = "mac",
    light: Lighting = .{ .color = .{ .r = 32, .g = 32, .b = 32 }, .brightness = 35 },
    writes: u64 = 0,
    fail_write: bool = false,
    pub fn driver(self: *Simulated) KeyboardDriver {
        return .{ .context = self, .vtable = &vtable };
    }
    fn cast(p: *anyopaque) *Simulated {
        return @ptrCast(@alignCast(p));
    }
    fn probe(p: *anyopaque) !Identity {
        const self = cast(p);
        if (!self.connected) return error.DeviceDisconnected;
        return .{ .model_id = "keyflux-simulated", .firmware = self.firmware, .profile = self.profile };
    }
    fn caps(_: *anyopaque) Capabilities {
        return .{ .solid_main = true, .readback = true, .restore = true };
    }
    fn capture(p: *anyopaque) !Capture {
        return .{ .identity = try probe(p), .main = cast(p).light };
    }
    fn solid(p: *anyopaque, value: Lighting) !void {
        const self = cast(p);
        _ = try probe(p);
        if (self.fail_write) return error.ReadbackMismatch;
        self.light = value;
        self.writes += 1;
    }
    fn restore(p: *anyopaque, original: Capture) !void {
        const identity = try probe(p);
        if (!std.mem.eql(u8, identity.firmware, original.identity.firmware) or !std.mem.eql(u8, identity.profile, original.identity.profile) or !std.mem.eql(u8, identity.model_id, original.identity.model_id)) return error.IdentityMismatch;
        try solid(p, original.main);
    }
    const vtable: KeyboardDriver.VTable = .{ .probe = probe, .capabilities = caps, .capture = capture, .setSolid = solid, .restore = restore };
};

pub const Lease = struct {
    original: ?Capture = null,
    acknowledged: ?Lighting = null,
    pub fn apply(self: *Lease, driver: KeyboardDriver, signal: ?theme.Signal) !bool {
        if (signal == null) {
            if (self.original) |original| {
                try driver.restore(original);
                self.original = null;
                self.acknowledged = null;
                return true;
            }
            return false;
        }
        const s = signal.?;
        const light: Lighting = .{ .color = try theme.Color.parse(s.color), .brightness = s.brightness };
        if (self.acknowledged) |last| if (std.meta.eql(last, light)) return false;
        if (self.original == null) self.original = try driver.capture();
        // Durable journal must be committed by the runtime BEFORE this call.
        try driver.setSolid(light);
        self.acknowledged = light;
        return true;
    }
};

pub const Model = struct {
    schema_version: u8,
    id: []const u8,
    name: []const u8,
    protocol: enum { nuphy_io_s4 },
    usb: struct { vendor_id: u16, product_id: u16, usage_page: u16, usage: u16, report_bytes: u16, interface_number: i16 = -1 },
    firmware: struct { family: []const u8 = "unknown", versions: []const []const u8 = &.{} } = .{},
    verified_on: []const Verification = &.{},
    layout: ?Layout = null,
    capabilities: ModelCapabilitiesV1,
    verification: enum { recognized, experimental, verified },
    evidence: []const []const u8,
    pub const Verification = struct {
        platform: enum { macos, windows },
        architecture: enum { aarch64, x86_64 },
        firmware: []const u8,
        profile: enum { mac, win },
        transport: enum { usb },
        zone: enum { main },
        evidence: []const []const u8,
    };
    pub const Layout = struct {
        key_count: u16,
        led_count: u16,
        leds: []const Led,
        pub const Led = struct { id: []const u8, index: u16, x: f32, y: f32 };
    };
    pub fn validate(self: Model) !void {
        if (self.schema_version != 1) return error.UnsupportedVersion;
        try @import("event.zig").validId(self.id);
        if (self.name.len == 0 or self.name.len > 128 or self.usb.vendor_id == 0 or self.usb.product_id == 0) return error.InvalidModel;
        if (self.usb.report_bytes != 64) return error.UnsupportedReportSize;
        if (self.usb.interface_number < -1) return error.InvalidModel;
        if (self.capabilities.per_key and (!self.capabilities.solid_main or self.capabilities.max_frames_per_second == 0)) return error.InvalidCapabilities;
        if (self.verification == .recognized and (self.capabilities.solid_main or self.capabilities.restore or self.capabilities.per_key)) return error.UnverifiedCapability;
        try @import("event.zig").validId(self.firmware.family);
        for (self.firmware.versions) |version| try @import("event.zig").validId(version);
        if (self.verification == .verified and (self.evidence.len == 0 or self.verified_on.len == 0 or self.firmware.versions.len == 0)) return error.MissingEvidence;
        for (self.verified_on) |v| {
            if (v.evidence.len == 0) return error.MissingEvidence;
            var listed = false;
            for (self.firmware.versions) |version| {
                if (std.mem.eql(u8, version, v.firmware)) listed = true;
            }
            if (!listed) return error.UnlistedFirmware;
        }
        if (self.capabilities.per_key and self.layout == null) return error.MissingLayout;
        if (self.layout) |layout| {
            if (layout.key_count == 0 or layout.key_count != layout.leds.len or layout.leds.len > 256 or layout.led_count < layout.key_count or layout.led_count > 1024) return error.InvalidLayout;
            for (layout.leds, 0..) |led, i| {
                try @import("event.zig").validId(led.id);
                if (led.index >= layout.led_count or !std.math.isFinite(led.x) or !std.math.isFinite(led.y) or led.x < 0 or led.y < 0) return error.InvalidLayout;
                for (layout.leds[0..i]) |previous| {
                    if (previous.index == led.index or std.mem.eql(u8, previous.id, led.id)) return error.DuplicateLed;
                }
            }
        }
    }
};
