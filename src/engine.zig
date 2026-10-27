const std = @import("std");
const event = @import("event.zig");
pub const Phase = event.Phase;
const Id = struct {
    data: [192]u8 = undefined,
    len: usize = 0,
    fn set(self: *Id, text: []const u8) void {
        @memcpy(self.data[0..text.len], text);
        self.len = text.len;
    }
    fn slice(self: *const Id) []const u8 {
        return self.data[0..self.len];
    }
    fn eq(self: *const Id, text: []const u8) bool {
        return std.mem.eql(u8, self.slice(), text);
    }
};
const Pending = struct { id: Id = .{}, tool_name: Id = .{}, waiting: bool = false, attention_kind: @FieldType(event.Event, "attention_kind") = null };
const Lane = struct {
    id: Id = .{},
    phase: Phase = .working,
    updated: u64 = 0,
    terminal: bool = false,
    requests: [8]?Pending = @splat(null),
};
const Session = struct {
    provider: Id = .{},
    session: Id = .{},
    turn: Id = .{},
    started: u64 = 0,
    watermark: u64 = 0,
    ended: bool = false,
    lost: bool = false,
    acknowledged: bool = false,
    check_type: @FieldType(event.Event, "check_type") = null,
    cancelled: bool = false,
    label: Id = .{},
    lanes: [8]?Lane = @splat(null),
};
pub const Snapshot = struct { phase: Phase, active_tasks: usize, tracked_sessions: usize, revision: u64 };
pub const Result = enum { applied, duplicate, stale };

/// Bounded session table. The latest turn is retained as a tombstone so delayed
/// phase messages cannot resurrect completed work. Capacity errors are explicit.
pub const Engine = struct {
    sessions: [64]?Session = @splat(null),
    seen: [256]?Id = @splat(null),
    seen_index: usize = 0,
    revision: u64 = 0,
    completed_at: ?u64 = null,
    retired_before: u64 = 0,
    completion_hold_ns: u64 = 5 * std.time.ns_per_s,

    pub fn apply(self: *Engine, e: event.Event, now: u64) !Result {
        try e.validate();
        if (e.timestamp_ns > now and e.timestamp_ns - now > 10 * std.time.ns_per_s) return error.FutureEvent;
        // IDs are scoped to provider, session and turn; a duplicate cannot affect
        // a different session. The digest is not a stored conversation identifier.
        var digest: [64]u8 = undefined;
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        for ([_][]const u8{ e.provider, e.session_id, e.turn_id, e.event_id }) |part| {
            hash.update(part);
            hash.update(&.{0});
        }
        const hex = std.fmt.bytesToHex(hash.finalResult(), .lower);
        @memcpy(&digest, &hex);
        for (self.seen) |item| if (item) |id| {
            if (id.eq(&digest)) return .duplicate;
        };

        var slot: ?*?Session = null;
        var empty: ?*?Session = null;
        for (&self.sessions) |*s| {
            if (s.*) |*v| {
                if (v.provider.eq(e.provider) and v.session.eq(e.session_id)) {
                    slot = s;
                    break;
                }
            } else if (empty == null) {
                empty = s;
            }
        }
        if (slot == null) {
            if ((e.kind != .turn_started and e.kind != .check_started) or e.task_id != null) return error.MissingTurnStart;
            if (e.timestamp_ns <= self.retired_before) return .stale;
            if (empty == null) {
                var oldest: u64 = std.math.maxInt(u64);
                for (&self.sessions) |*s| if (s.*) |v| {
                    if (v.ended and v.watermark < oldest) {
                        oldest = v.watermark;
                        empty = s;
                    }
                };
                if (empty != null) self.retired_before = @max(self.retired_before, oldest);
            }
            slot = empty orelse return error.SessionCapacity;
            slot.?.* = null;
        }
        // Apply transactionally: invalid/capacity-limited events leave no changes.
        var next = slot.?.* orelse Session{};
        if ((e.kind == .turn_started or e.kind == .check_started) and e.task_id == null) {
            if (next.started != 0 and e.timestamp_ns <= next.watermark) return .stale;
            if (next.turn.eq(e.turn_id)) return .duplicate;
            if (next.started != 0 and !next.ended) return error.TurnStillActive;
            next = .{};
            next.provider.set(e.provider);
            next.session.set(e.session_id);
            next.turn.set(e.turn_id);
            next.started = e.timestamp_ns;
            next.check_type = e.check_type;
            if (e.label) |label| next.label.set(label);
        } else {
            if (!next.turn.eq(e.turn_id) or e.timestamp_ns < next.started or next.ended) return .stale;
        }
        if ((e.kind == .check_passed or e.kind == .check_failed or e.kind == .check_cancelled) and (next.check_type == null or next.check_type != e.check_type)) return error.InvalidCheckEvent;
        if (next.check_type != null and (e.kind == .turn_completed or e.kind == .turn_failed)) return error.InvalidCheckEvent;
        if (e.kind == .source_lost) {
            if (e.timestamp_ns < next.watermark) return .stale;
            next.lost = true;
        } else if (e.kind == .source_resumed) {
            if (e.timestamp_ns < next.watermark) return .stale;
            // Reconnection alone cannot prove the previous phase is still active.
            next.lost = true;
        } else if (e.kind == .session_ended or e.kind == .turn_completed or e.kind == .turn_cancelled or e.kind == .turn_failed or e.kind == .check_passed or e.kind == .check_failed or e.kind == .check_cancelled) {
            if (e.task_id == null) {
                if (e.timestamp_ns < next.watermark) return .stale;
                next.ended = true;
                next.cancelled = e.kind == .turn_cancelled or e.kind == .check_cancelled or e.kind == .session_ended;
                next.lost = false;
                for (&next.lanes) |*lane| if (lane.*) |*v| {
                    v.terminal = true;
                    v.requests = @splat(null);
                };
                if (e.kind == .turn_completed or e.kind == .check_passed) self.completed_at = now;
                if (e.kind == .check_passed or e.kind == .check_failed) {
                    next.lanes[0].?.phase = if (e.kind == .check_passed) .verified else .check_failed;
                    next.lanes[0].?.updated = e.timestamp_ns;
                }
                if (e.kind == .turn_failed) {
                    next.lanes[0].?.phase = .@"error";
                    next.lanes[0].?.updated = e.timestamp_ns;
                }
            } else {
                const lane = findLane(&next, e.task_id.?) orelse return error.UnknownTask;
                if (e.timestamp_ns < lane.updated) return .stale;
                lane.terminal = true;
                lane.requests = @splat(null);
                if (e.kind == .turn_failed) lane.phase = .@"error";
            }
        } else {
            const task = e.task_id orelse "@root";
            var lane = findLane(&next, task);
            if (lane == null) {
                if (e.kind != .turn_started and e.kind != .check_started) return error.UnknownTask;
                for (&next.lanes) |*l| if (l.* == null) {
                    l.* = Lane{};
                    lane = &l.*.?;
                    lane.?.id.set(task);
                    break;
                };
                if (lane == null) return error.TaskCapacity;
            }
            const l = lane.?;
            if (l.terminal or e.timestamp_ns < l.updated) return .stale;
            switch (e.kind) {
                .turn_started, .check_started, .working => l.phase = if (next.check_type != null) .checking else .working,
                .thinking => l.phase = .thinking,
                .output => l.phase = .output,
                .tool_started, .attention => {
                    var request_id = e.request_id.?;
                    if (e.kind == .attention and std.mem.eql(u8, request_id, "@uncorrelated")) {
                        if (e.tool_name) |name| {
                            var matching: ?*Pending = null;
                            var count: usize = 0;
                            for (&l.requests) |*p| if (p.*) |*v| {
                                if (v.tool_name.eq(name)) {
                                    matching = v;
                                    count += 1;
                                }
                            };
                            if (count == 1) request_id = matching.?.id.slice();
                        }
                    }
                    var request: ?*?Pending = null;
                    for (&l.requests) |*p| {
                        if (p.*) |*v| {
                            if (v.id.eq(request_id)) {
                                request = p;
                                break;
                            }
                        }
                    }
                    if (request == null) for (&l.requests) |*p| if (p.* == null) {
                        request = p;
                        break;
                    };
                    const p = request orelse return error.RequestCapacity;
                    if (p.* == null) {
                        p.* = Pending{};
                        p.*.?.id.set(request_id);
                    }
                    if (e.tool_name) |name| p.*.?.tool_name.set(name);
                    p.*.?.waiting = e.kind == .attention;
                    p.*.?.attention_kind = e.attention_kind;
                    if (e.kind == .tool_started) l.phase = .tool;
                },
                .tool_finished, .attention_resolved => {
                    var found = false;
                    for (&l.requests) |*p| if (p.*) |*v| {
                        if (v.id.eq(e.request_id.?)) {
                            found = true;
                            if (e.kind == .tool_finished) p.* = null else v.waiting = false;
                            break;
                        }
                    };
                    if (!found) return .stale;
                    l.phase = .working;
                },
                else => unreachable,
            }
            l.updated = e.timestamp_ns;
            next.lost = false;
        }
        if (((e.kind == .turn_started or e.kind == .check_started) and e.task_id == null) or e.kind == .turn_cancelled or e.kind == .check_cancelled or e.kind == .session_ended) self.completed_at = null;
        next.watermark = @max(next.watermark, e.timestamp_ns);
        slot.?.* = next;
        var id: Id = .{};
        id.set(&digest);
        self.seen[self.seen_index] = id;
        self.seen_index = (self.seen_index + 1) % self.seen.len;
        self.revision += 1;
        return .applied;
    }

    fn findLane(s: *Session, task: []const u8) ?*Lane {
        for (&s.lanes) |*l| if (l.*) |*v| {
            if (v.id.eq(task)) return v;
        };
        return null;
    }

    pub fn currentTurn(self: *const Engine, provider: []const u8, session: []const u8) ?[]const u8 {
        for (&self.sessions) |*s| if (s.*) |*v| {
            if (v.provider.eq(provider) and v.session.eq(session) and !v.ended) return v.turn.slice();
        };
        return null;
    }

    pub const SessionView = struct {
        label: ?[]const u8,
        provider: []const u8,
        session_id: []const u8,
        turn_id: []const u8,
        phase: Phase,
        ended: bool,
        cancelled: bool,
        acknowledged: bool,
        updated_ns: u64,
        active_tasks: usize = 0,
        pending_approvals: usize = 0,
        pending_inputs: usize = 0,
        pending_other: usize = 0,
        check_type: @FieldType(event.Event, "check_type"),
    };
    fn view(s: *const Session, now: u64) SessionView {
        var v: SessionView = .{ .label = if (s.label.len > 0) s.label.slice() else null, .provider = s.provider.slice(), .session_id = s.session.slice(), .turn_id = s.turn.slice(), .phase = .working, .ended = s.ended, .cancelled = s.cancelled, .acknowledged = s.acknowledged, .updated_ns = s.watermark, .check_type = s.check_type };
        var newest: u64 = 0;
        var failure: ?Phase = null;
        for (s.lanes) |l| if (l) |lane| {
            if (!lane.terminal) v.active_tasks += 1;
            for (lane.requests) |p| if (p) |req| {
                if (req.waiting) {
                    if (req.attention_kind == .approval) v.pending_approvals += 1 else if (req.attention_kind == .input) v.pending_inputs += 1 else v.pending_other += 1;
                }
            };
            if ((!lane.terminal or s.ended) and lane.updated >= newest) {
                newest = lane.updated;
                v.phase = lane.phase;
            }
            if (lane.phase == .@"error" or lane.phase == .check_failed) {
                failure = lane.phase;
            }
        };
        if (failure) |phase| v.phase = phase;
        if (s.lost or (s.check_type != null and !s.ended and now > s.watermark and now - s.watermark > 30 * std.time.ns_per_s)) v.phase = .unknown else if (v.pending_approvals + v.pending_inputs + v.pending_other > 0) v.phase = .attention else if (!s.ended and failure == null) {
            for (s.lanes) |l| if (l) |lane| {
                for (lane.requests) |p| if (p != null) {
                    v.phase = .tool;
                };
            };
        } else if (s.cancelled) v.phase = .idle else if (v.phase != .@"error" and v.phase != .verified and v.phase != .check_failed) v.phase = .complete;
        return v;
    }
    pub fn list(self: *const Engine, a: std.mem.Allocator, now: u64) ![]SessionView {
        var list_: std.ArrayList(SessionView) = .empty;
        for (&self.sessions) |*slot| if (slot.*) |*s| {
            try list_.append(a, view(s, now));
        };
        return list_.toOwnedSlice(a);
    }
    pub fn acknowledge(self: *Engine, provider: []const u8, session: []const u8, turn: []const u8) !void {
        for (&self.sessions) |*slot| if (slot.*) |*s| {
            if (s.provider.eq(provider) and s.session.eq(session) and s.turn.eq(turn)) {
                if (!s.ended) return error.TaskStillActive;
                s.acknowledged = true;
                self.revision += 1;
                return;
            }
        };
        return error.UnknownTask;
    }
    pub fn snapshot(self: *const Engine, now: u64) Snapshot {
        var result: Snapshot = .{ .phase = .idle, .active_tasks = 0, .tracked_sessions = 0, .revision = self.revision };
        var attention = false;
        var failed: ?Phase = null;
        var lost = false;
        var newest: u64 = 0;
        var terminal: Phase = .complete;
        var last_terminal: u64 = 0;
        for (&self.sessions) |*slot| if (slot.*) |*s| {
            const v = view(s, now);
            result.tracked_sessions += 1;
            result.active_tasks += v.active_tasks;
            attention = attention or v.phase == .attention;
            if (!v.acknowledged and (v.phase == .@"error" or v.phase == .check_failed)) failed = v.phase;
            if (!v.ended and v.phase == .unknown) lost = true;
            if (!v.ended and v.phase != .unknown and v.updated_ns >= newest) {
                newest = v.updated_ns;
                result.phase = v.phase;
            }
            if (v.ended and !v.cancelled and !v.acknowledged and v.updated_ns >= last_terminal) {
                last_terminal = v.updated_ns;
                terminal = v.phase;
            }
        };
        if (attention) result.phase = .attention else if (failed) |phase| result.phase = phase else if (lost) result.phase = .unknown else if (result.active_tasks == 0) {
            result.phase = .idle;
            if (self.completed_at) |t| if (last_terminal > 0 and now >= t and now - t < self.completion_hold_ns) {
                result.phase = if (terminal == .verified) .verified else .complete;
            };
        }
        return result;
    }
};
