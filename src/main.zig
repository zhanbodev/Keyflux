const std = @import("std");
const p = @import("platform.zig");
const events = @import("event.zig");
const engine = @import("engine.zig");
const themes = @import("theme.zig");
const devices = @import("device.zig");
const codex = @import("codex.zig");
const otlp = @import("otlp.zig");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const max_request = 512 * 1024;
const usage =
    \\Keyflux 0.1.0-dev — internal validation build
    \\  keyflux diagnose                       Read-only NuPhy HID inventory
    \\  keyflux serve [--simulate] [--otlp-port 4318]
    \\  keyflux emit [event.json]               AgentEvent v1 → running core
    \\  keyflux hook                           Codex hook JSON on stdin (always non-blocking semantics)
    \\  keyflux status | stop | theme-get
    \\  keyflux theme-set theme.json | preview thinking | reset
    \\  keyflux replay events.jsonl            Offline deterministic state replay
    \\  keyflux validate-event|validate-theme|validate-model file.json
    \\  keyflux gate evidence.json             Exit 2 until every release gate passes
    \\  keyflux setup-codex /absolute/keyflux   Print reviewable hook and OTel fragments
    \\  --state-dir PATH                       Isolated runtime data / IPC namespace
    \\No real hardware writes are enabled. Simulation is explicitly labeled.
    \\
;

fn output(a: Allocator, v: anytype) !void {
    const bytes = try std.json.Stringify.valueAlloc(a, v, .{});
    p.kf_print(bytes.ptr, bytes.len, 0);
    p.kf_print("\n", 1, 0);
}
fn encoded(a: Allocator, v: anytype) ![]const u8 {
    return std.json.Stringify.valueAlloc(a, v, .{});
}
fn readState(a: Allocator, name: [:0]const u8, limit: usize) !?[]const u8 {
    const buffer = try a.alloc(u8, limit + 1);
    const n = p.kf_read_file(name, buffer.ptr, buffer.len);
    if (n == -2) return null;
    if (n < 0) return error.StateReadFailed;
    return buffer[0..@intCast(n)];
}
fn writeState(a: Allocator, name: [:0]const u8, value: anytype) !void {
    const bytes = try encoded(a, value);
    if (p.kf_write_file(name, bytes.ptr, bytes.len) != 0) return error.StateWriteFailed;
}
fn input(init: std.process.Init, file: ?[]const u8) ![]const u8 {
    const a = init.arena.allocator();
    if (file) |path| return std.Io.Dir.cwd().readFileAlloc(init.io, path, a, .limited(max_request));
    const buffer = try a.alloc(u8, max_request);
    const n = p.kf_stdin(buffer.ptr, buffer.len);
    if (n < 0) return error.PayloadTooLarge;
    return buffer[0..@intCast(n)];
}
fn request(a: Allocator, bytes: []const u8) ![]const u8 {
    const buffer = try a.alloc(u8, 65536);
    const n = p.kf_request(bytes.ptr, bytes.len, buffer.ptr, buffer.len);
    if (n <= 0) return error.DaemonUnavailable;
    return buffer[0..@intCast(n)];
}
fn unique(a: Allocator) ![]const u8 {
    var random: [16]u8 = undefined;
    if (p.kf_random(&random, random.len) != 0) return error.RandomUnavailable;
    return std.fmt.allocPrint(a, "{s}", .{std.fmt.bytesToHex(random, .lower)});
}

const Recovery = struct { schema_version: u8, backend: enum { simulated }, original: devices.Capture };
const Evidence = struct { records: u64 = 0, reasoning: u64 = 0, output: u64 = 0, correlated: u64 = 0, rejected: u64 = 0, applied: u64 = 0, max_arrival_delay_ms: u64 = 0 };
const Runtime = struct {
    core: engine.Engine = .{},
    simulated: bool = false,
    device: devices.Simulated = .{},
    lease: devices.Lease = .{},
    theme: themes.Theme = .{},
    // Theme strings are owned by a dedicated arena, replaced after validation.
    theme_arena: std.heap.ArenaAllocator,
    evidence: Evidence = .{},
    token: []const u8 = "",
    stopping: bool = false,
    device_error: ?[]const u8 = null,
    preview_phase: ?events.Phase = null,
    preview_color: [7]u8 = "#000000".*,
    preview_brightness: u8 = 0,
    preview_override: bool = false,
    preview_until: u64 = 0,

    fn loadTheme(self: *Runtime, bytes: []const u8) !void {
        var next = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        errdefer next.deinit();
        const parsed = try themes.parse(next.allocator(), bytes);
        const theme = parsed.value;
        self.theme_arena.deinit();
        self.theme_arena = next;
        self.theme = theme;
        self.core.completion_hold_ns = @as(u64, theme.completion_hold_ms) * std.time.ns_per_ms;
    }
    fn sync(self: *Runtime, a: Allocator, now: u64) !void {
        if (!self.simulated or self.device_error != null) return;
        const phase = if (self.preview_phase != null and now < self.preview_until) self.preview_phase.? else self.core.snapshot(now).phase;
        if (self.preview_phase != null and now >= self.preview_until) self.preview_phase = null;
        const signal = if (self.preview_phase != null and self.preview_override) themes.Signal{ .color = &self.preview_color, .brightness = self.preview_brightness } else self.theme.signal(phase);
        if (signal != null and self.lease.original == null) {
            const original = try self.device.driver().capture();
            try writeState(a, "recovery.json", Recovery{ .schema_version = 1, .backend = .simulated, .original = original });
            self.lease.original = original;
        }
        if (try self.lease.apply(self.device.driver(), signal)) {
            try writeState(a, "simulated-device.json", self.device.light);
            if (self.lease.original == null and p.kf_remove_file("recovery.json") != 0) return error.RecoveryRemoveFailed;
        }
    }
    const Status = struct {
        schema_version: u8 = 1,
        version: []const u8 = "0.1.0-dev",
        state: engine.Snapshot,
        backend: []const u8,
        main_write_enabled: bool,
        release_ready: bool = false,
        acknowledged: ?devices.Lighting,
        device_error: ?[]const u8,
        evidence: Evidence,
        preview: ?events.Phase,
        process_metrics: struct { available: bool, cpu_time_ns: u64, resident_bytes: u64, monotonic_ns: u64 },
    };
    fn snapshot(self: *Runtime, now: u64) Status {
        var stats: [3]u64 = @splat(0);
        const available = p.kf_process_stats(&stats) == 0;
        return .{ .schema_version = 1, .version = "0.1.0-dev", .state = self.core.snapshot(now), .backend = if (self.simulated) "simulated" else "read-only", .main_write_enabled = self.simulated, .release_ready = false, .acknowledged = self.lease.acknowledged, .device_error = self.device_error, .evidence = self.evidence, .preview = self.preview_phase, .process_metrics = .{ .available = available, .cpu_time_ns = stats[0], .resident_bytes = stats[1], .monotonic_ns = stats[2] } };
    }
    fn handle(self: *Runtime, a: Allocator, bytes: []const u8, now: u64) ![]const u8 {
        const parsed = try std.json.parseFromSlice(Value, a, bytes, .{ .max_value_len = max_request });
        const value = parsed.value;
        const op = codex.string(codex.field(value, "op")) orelse return error.MissingOperation;
        if (eq(op, "status")) return encoded(a, .{ .ok = true, .result = self.snapshot(now) });
        if (eq(op, "stop")) {
            self.stopping = true;
            return encoded(a, .{ .ok = true });
        }
        if (eq(op, "emit")) {
            const body = codex.field(value, "event") orelse return error.MissingEvent;
            const raw = try encoded(a, body);
            const e = try events.parse(a, raw);
            const result = try self.core.apply(e.value, now);
            try self.sync(a, now);
            return encoded(a, .{ .ok = true, .result = result, .state = self.core.snapshot(now) });
        }
        if (eq(op, "hook")) {
            // CLI already filtered content; this path correlates SessionEnd and
            // PermissionRequest formats missing a tool-use identifier.
            const body = codex.field(value, "event") orelse return error.MissingEvent;
            var e = (try events.parse(a, try encoded(a, body))).value;
            if (eq(e.turn_id, "@current")) e.turn_id = self.core.currentTurn("codex", e.session_id) orelse return encoded(a, .{ .ok = true, .ignored = true });
            const result = try self.core.apply(e, now);
            try self.sync(a, now);
            return encoded(a, .{ .ok = true, .result = result });
        }
        if (eq(op, "theme-get")) return encoded(a, .{ .ok = true, .theme = self.theme });
        if (eq(op, "theme-set")) {
            const body = codex.field(value, "theme") orelse return error.MissingTheme;
            const raw = try encoded(a, body);
            const validated = try themes.parse(a, raw);
            // Persist before replacing the active configuration.
            try writeState(a, "theme.json", validated.value);
            try self.loadTheme(raw);
            try self.sync(a, now);
            return encoded(a, .{ .ok = true });
        }
        if (eq(op, "preview")) {
            const name = codex.string(codex.field(value, "phase")) orelse return error.MissingPhase;
            const phase = std.meta.stringToEnum(events.Phase, name) orelse return error.InvalidPhase;
            if (!self.simulated) return error.HardwareGateNotPassed;
            self.preview_override = false;
            if (codex.field(value, "signal")) |raw| {
                const signal = (try std.json.parseFromSlice(themes.Signal, a, try encoded(a, raw), .{})).value;
                _ = try themes.Color.parse(signal.color);
                if (signal.brightness > 100) return error.InvalidBrightness;
                @memcpy(&self.preview_color, signal.color);
                self.preview_brightness = signal.brightness;
                self.preview_override = true;
            }
            self.preview_phase = phase;
            self.preview_until = now + 3 * std.time.ns_per_s;
            try self.sync(a, now);
            return encoded(a, .{ .ok = true, .simulated = true, .duration_ms = @as(u32, 3000) });
        }
        if (eq(op, "reset")) {
            self.preview_phase = null;
            self.core = .{};
            self.core.completion_hold_ns = @as(u64, self.theme.completion_hold_ms) * std.time.ns_per_ms;
            self.device_error = null;
            try self.sync(a, now);
            return encoded(a, .{ .ok = true });
        }
        return error.UnknownOperation;
    }
    fn ingest(self: *Runtime, a: Allocator, batch: otlp.Batch, now: u64) void {
        self.evidence.records += batch.total;
        for (batch.records.items) |record| {
            const kind = codex.streamKind(record.kind) orelse continue;
            if (kind == .thinking) self.evidence.reasoning += 1 else self.evidence.output += 1;
            const turn = record.turn_id orelse self.core.currentTurn("codex", record.session_id) orelse {
                self.evidence.rejected += 1;
                continue;
            };
            if (record.timestamp_ns == 0 or record.session_id.len == 0) {
                self.evidence.rejected += 1;
                continue;
            }
            self.evidence.correlated += 1;
            if (now >= record.timestamp_ns) self.evidence.max_arrival_delay_ms = @max(self.evidence.max_arrival_delay_ms, (now - record.timestamp_ns) / std.time.ns_per_ms);
            const id = std.fmt.allocPrint(a, "otlp-{d}-{s}", .{ record.timestamp_ns, record.kind }) catch continue;
            const e: events.Event = .{ .schema_version = 1, .provider = "codex", .session_id = record.session_id, .turn_id = turn, .event_id = id, .timestamp_ns = record.timestamp_ns, .kind = kind };
            const result = self.core.apply(e, now) catch {
                self.evidence.rejected += 1;
                continue;
            };
            if (result == .applied) self.evidence.applied += 1;
        }
    }
    fn http(self: *Runtime, a: Allocator, bytes: []const u8, now: u64) ![]const u8 {
        const split = std.mem.indexOf(u8, bytes, "\r\n\r\n") orelse return httpResponse(a, 400, "{}");
        if (split > 8192) return httpResponse(a, 413, "{}");
        const header = bytes[0..split];
        var lines = std.mem.splitSequence(u8, header, "\r\n");
        if (!eq(lines.next() orelse "", "POST /v1/logs HTTP/1.1")) return httpResponse(a, 404, "{}");
        var authorization: ?[]const u8 = null;
        var content_type: ?[]const u8 = null;
        var length: ?usize = null;
        while (lines.next()) |line| {
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse return httpResponse(a, 400, "{}");
            const key = line[0..colon];
            const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
            if (std.ascii.eqlIgnoreCase(key, "authorization")) {
                if (authorization != null) return httpResponse(a, 400, "{}");
                authorization = value;
            }
            if (std.ascii.eqlIgnoreCase(key, "origin") or std.ascii.eqlIgnoreCase(key, "transfer-encoding") or std.ascii.eqlIgnoreCase(key, "content-encoding")) return httpResponse(a, 400, "{}");
            if (std.ascii.eqlIgnoreCase(key, "content-type")) content_type = value;
            if (std.ascii.eqlIgnoreCase(key, "content-length")) {
                if (length != null) return httpResponse(a, 400, "{}");
                length = std.fmt.parseInt(usize, value, 10) catch return httpResponse(a, 400, "{}");
            }
        }
        const auth = authorization orelse return httpResponse(a, 401, "{}");
        if (!std.mem.startsWith(u8, auth, "Bearer ") or auth.len != self.token.len + 7) return httpResponse(a, 401, "{}");
        var diff: u8 = 0;
        for (auth[7..], self.token) |x, y| diff |= x ^ y;
        if (diff != 0) return httpResponse(a, 401, "{}");
        const body = bytes[split + 4 ..];
        if (body.len > max_request) return httpResponse(a, 413, "{}");
        if (length == null or length.? != body.len) return httpResponse(a, 400, "{}");
        const ct = content_type orelse return httpResponse(a, 415, "{}");
        const json_body = eq(ct, "application/json");
        const batch = if (json_body) otlp.json(a, body) catch return httpResponse(a, 400, "{}") else if (eq(ct, "application/x-protobuf")) otlp.protobuf(a, body) catch return httpResponse(a, 400, "{}") else return httpResponse(a, 415, "{}");
        self.ingest(a, batch, now);
        try self.sync(a, now);
        return if (json_body) httpResponse(a, 200, "{}") else httpResponseType(a, 200, "", "application/x-protobuf");
    }
};
fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
fn httpResponse(a: Allocator, status: u16, body: []const u8) ![]const u8 {
    return httpResponseType(a, status, body, "application/json");
}
fn httpResponseType(a: Allocator, status: u16, body: []const u8, content_type: []const u8) ![]const u8 {
    const label: []const u8 = switch (status) {
        200 => "OK",
        401 => "Unauthorized",
        404 => "Not Found",
        413 => "Content Too Large",
        415 => "Unsupported Media Type",
        else => "Bad Request",
    };
    return std.fmt.allocPrint(a, "HTTP/1.1 {d} {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ status, label, content_type, body.len, body });
}

fn serve(a: Allocator, simulated: bool, port: u16) !void {
    if (p.kf_listen(port) != 0) return error.DaemonAlreadyRunningOrBindFailed;
    defer p.kf_shutdown();
    const runtime = try a.create(Runtime);
    runtime.* = .{ .simulated = simulated, .theme_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator) };
    defer runtime.theme_arena.deinit();
    if (try readState(a, "theme.json", 16384)) |bytes| try runtime.loadTheme(bytes);
    if (simulated) {
        if (try readState(a, "simulated-device.json", 4096)) |bytes| runtime.device.light = (try std.json.parseFromSlice(devices.Lighting, a, bytes, .{})).value;
        if (try readState(a, "recovery.json", 8192)) |bytes| {
            const recovery = (try std.json.parseFromSlice(Recovery, a, bytes, .{})).value;
            if (recovery.schema_version != 1) return error.UnsupportedRecoveryVersion;
            try runtime.device.driver().restore(recovery.original);
            try writeState(a, "simulated-device.json", runtime.device.light);
            if (p.kf_remove_file("recovery.json") != 0) return error.RecoveryRemoveFailed;
        }
    }
    if (port != 0) {
        const existing = try readState(a, "otlp-token", 128);
        runtime.token = existing orelse try unique(a);
        if (runtime.token.len != 32) return error.InvalidToken;
        if (existing == null and p.kf_write_file("otlp-token", runtime.token.ptr, runtime.token.len) != 0) return error.StateWriteFailed;
    }
    try output(a, .{ .ready = true, .version = "0.1.0-dev", .backend = if (simulated) "simulated" else "read-only", .otlp_port = port, .release_ready = false });
    const buffer = try a.alloc(u8, max_request + 8193);
    while (!runtime.stopping) {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const scratch = arena.allocator();
        var http: c_int = 0;
        const n = p.kf_next(buffer.ptr, buffer.len, &http);
        defer p.kf_close_client();
        const now = p.kf_now_ns();
        if (n == -2) break;
        if (n > 0) {
            const bytes = buffer[0..@intCast(n)];
            const response = if (http != 0) runtime.http(scratch, bytes, now) catch |err| try httpResponse(scratch, 400, try encoded(scratch, .{ .ok = false, .code = @errorName(err) })) else runtime.handle(scratch, bytes, now) catch |err| try encoded(scratch, .{ .ok = false, .code = @errorName(err) });
            _ = p.kf_reply(response.ptr, response.len);
            if (http == 0) _ = p.kf_reply("\n", 1);
        }
        runtime.sync(scratch, now) catch |err| {
            runtime.device_error = @errorName(err);
        };
    }
    if (simulated) {
        _ = try runtime.lease.apply(runtime.device.driver(), null);
        try writeState(a, "simulated-device.json", runtime.device.light);
        if (p.kf_remove_file("recovery.json") != 0) return error.RecoveryRemoveFailed;
    }
}

pub fn main(init: std.process.Init) void {
    run(init) catch |err| {
        const a = init.arena.allocator();
        output(a, .{ .ok = false, .code = @errorName(err) }) catch {};
        p.kf_exit(1);
    };
}
fn run(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    var positional: std.ArrayList([]const u8) = .empty;
    var directory: ?[:0]const u8 = null;
    var simulate = false;
    var port: u16 = 0;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (eq(args[i], "--state-dir")) {
            i += 1;
            if (i == args.len) return error.MissingArgument;
            directory = args[i];
        } else if (eq(args[i], "--simulate")) simulate = true else if (eq(args[i], "--otlp-port")) {
            i += 1;
            if (i == args.len) return error.MissingArgument;
            port = try std.fmt.parseInt(u16, args[i], 10);
            if (port == 0) return error.InvalidPort;
        } else try positional.append(a, args[i]);
    }
    if (positional.items.len == 0 or eq(positional.items[0], "help") or eq(positional.items[0], "--help")) {
        p.kf_print(usage.ptr, usage.len, 0);
        return;
    }
    const command = positional.items[0];
    const file: ?[]const u8 = if (positional.items.len > 1) positional.items[1] else null;
    if (eq(command, "version")) {
        try output(a, .{ .version = "0.1.0-dev", .zig = "0.17.0" });
        return;
    }
    if (eq(command, "diagnose")) {
        const buffer = try a.alloc(u8, 65536);
        const n = p.kf_hid_diagnose(buffer.ptr, buffer.len);
        if (n < 0) return error.HidEnumerationFailed;
        p.kf_print(buffer.ptr, @intCast(n), 0);
        return;
    }
    if (std.mem.startsWith(u8, command, "validate-")) {
        const bytes = try input(init, file);
        if (eq(command, "validate-event")) {
            const v = try events.parse(a, bytes);
            v.deinit();
        } else if (eq(command, "validate-theme")) {
            const v = try themes.parse(a, bytes);
            v.deinit();
        } else if (eq(command, "validate-model")) {
            const v = try std.json.parseFromSlice(devices.Model, a, bytes, .{});
            defer v.deinit();
            try v.value.validate();
        } else return error.UnknownCommand;
        try output(a, .{ .ok = true });
        return;
    }
    if (eq(command, "gate")) {
        const v = try std.json.parseFromSlice(@import("protocol.zig").Gate, a, try input(init, file), .{});
        const ready = v.value.ready();
        try output(a, .{ .release_ready = ready, .evidence_is_self_reported = true });
        if (!ready) p.kf_exit(2);
        return;
    }
    if (eq(command, "replay")) {
        const core = try a.create(engine.Engine);
        core.* = .{};
        var lines = std.mem.splitScalar(u8, try input(init, file), '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            const e = try events.parse(a, line);
            const result = try core.apply(e.value, e.value.timestamp_ns);
            try output(a, .{ .result = result, .state = core.snapshot(e.value.timestamp_ns) });
        }
        return;
    }
    if (eq(command, "setup-codex")) {
        try setup(a, file orelse return error.MissingExecutablePath);
        return;
    }
    if (eq(command, "hook")) {
        if (p.kf_init(if (directory) |s| s.ptr else null) == 0) hookClient(init, directory) catch {};
        p.kf_print("{}\n", 3, 0);
        return;
    }
    if (p.kf_init(if (directory) |s| s.ptr else null) != 0) return error.StateDirectoryUnavailable;
    if (eq(command, "serve")) {
        try serve(a, simulate, port);
        return;
    }
    if (eq(command, "emit")) {
        const raw = try input(init, file);
        const e = try events.parse(a, raw);
        const response = try request(a, try encoded(a, .{ .op = "emit", .event = e.value }));
        p.kf_print(response.ptr, response.len, 0);
        try checkResponse(a, response);
        return;
    }
    const payload = if (eq(command, "theme-set")) blk: {
        const v = try themes.parse(a, try input(init, file));
        break :blk try encoded(a, .{ .op = command, .theme = v.value });
    } else if (eq(command, "preview")) blk: {
        const phase = file orelse return error.MissingPhase;
        if (positional.items.len > 2) {
            const signal_input = positional.items[2];
            const raw = try input(init, if (eq(signal_input, "--signal-stdin")) null else signal_input);
            const signal = try std.json.parseFromSlice(themes.Signal, a, raw, .{});
            break :blk try encoded(a, .{ .op = command, .phase = phase, .signal = signal.value });
        }
        break :blk try encoded(a, .{ .op = command, .phase = phase });
    } else if (eq(command, "status") or eq(command, "stop") or eq(command, "theme-get") or eq(command, "reset")) try encoded(a, .{ .op = command }) else return error.UnknownCommand;
    const response = try request(a, payload);
    p.kf_print(response.ptr, response.len, 0);
    try checkResponse(a, response);
}
fn checkResponse(a: Allocator, bytes: []const u8) !void {
    const v = try std.json.parseFromSlice(Value, a, bytes, .{});
    const ok = codex.field(v.value, "ok") orelse return error.InvalidResponse;
    if (ok != .bool or !ok.bool) return error.OperationRejected;
}
fn hookClient(init: std.process.Init, directory: ?[:0]const u8) !void {
    const a = init.arena.allocator();
    const v = try std.json.parseFromSlice(Value, a, try input(init, null), .{});
    const e = (try codex.hook(v.value, try unique(a), p.kf_now_ns())) orelse return;
    _ = directory;
    _ = try request(a, try encoded(a, .{ .op = "hook", .event = e }));
}
fn setup(a: Allocator, path: []const u8) !void {
    // A reviewable fragment is intentionally separate from an installer. Never
    // overwrite existing OTel routing or hook trust to make the probe work.
    if (!std.fs.path.isAbsolute(path)) return error.ExecutablePathMustBeAbsolute;
    const quoted = try std.fmt.allocPrint(a, "\"{s}\" hook", .{path});
    if (std.mem.indexOfAny(u8, path, "\"`$\n\r") != null) return error.UnsafeExecutablePath;
    const Hook = struct { type: []const u8 = "command", command: []const u8 };
    const Entry = struct { hooks: [1]Hook };
    const entry = Entry{ .hooks = .{.{ .command = quoted }} };
    try output(a, .{
        .schema_version = @as(u8, 1),
        .applied = false,
        .hooks = .{ .UserPromptSubmit = .{entry}, .PreToolUse = .{entry}, .PostToolUse = .{entry}, .PermissionRequest = .{entry}, .SubagentStart = .{entry}, .SubagentStop = .{entry}, .Stop = .{entry}, .Interrupt = .{entry}, .SessionEnd = .{entry} },
        .otel = .{ .endpoint = "http://127.0.0.1:4318/v1/logs", .protocol = "binary", .log_user_prompt = false, .authorization = "Bearer <read otlp-token from Keyflux state directory>" },
        .notes = "Merge only after review; preserve existing hooks/exporter. Codex hook trust and restart are required. Probe real field names, correlation and export delay before release.",
    });
}
