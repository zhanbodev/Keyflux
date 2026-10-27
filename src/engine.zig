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
const Pending = struct { id: Id = .{}, tool_name: Id = .{}, waiting: bool = false };
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
            if (e.kind != .turn_started or e.task_id != null) return error.MissingTurnStart;
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
        if (e.kind == .turn_started and e.task_id == null) {
            if (next.started != 0 and e.timestamp_ns <= next.watermark) return .stale;
            if (next.turn.eq(e.turn_id)) return .duplicate;
            if (next.started != 0 and !next.ended) return error.TurnStillActive;
            next = .{};
            next.provider.set(e.provider);
            next.session.set(e.session_id);
            next.turn.set(e.turn_id);
            next.started = e.timestamp_ns;
        } else {
            if (!next.turn.eq(e.turn_id) or e.timestamp_ns < next.started or next.ended) return .stale;
        }
        if (e.kind == .source_lost) {
            if (e.timestamp_ns < next.watermark) return .stale;
            next.lost = true;
        } else if (e.kind == .source_resumed) {
            if (e.timestamp_ns < next.watermark) return .stale;
            // Reconnection alone cannot prove the previous phase is still active.
            next.lost = true;
        } else if (e.kind == .session_ended or e.kind == .turn_completed or e.kind == .turn_cancelled or e.kind == .turn_failed) {
            if (e.task_id == null) {
                if (e.timestamp_ns < next.watermark) return .stale;
                next.ended = true;
                next.lost = false;
                for (&next.lanes) |*lane| if (lane.*) |*v| {
                    v.terminal = true;
                    v.requests = @splat(null);
                };
                if (e.kind == .turn_completed) self.completed_at = now;
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
                if (e.kind != .turn_started) return error.UnknownTask;
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
                .turn_started, .working => l.phase = .working,
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
        if ((e.kind == .turn_started and e.task_id == null) or e.kind == .turn_cancelled or e.kind == .session_ended) self.completed_at = null;
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

    pub fn snapshot(self: *const Engine, now: u64) Snapshot {
        var result: Snapshot = .{ .phase = .idle, .active_tasks = 0, .tracked_sessions = 0, .revision = self.revision };
        var attention = false;
        var failed = false;
        var lost = false;
        var newest: u64 = 0;
        for (self.sessions) |s| if (s) |v| {
            result.tracked_sessions += 1;
            if (v.lost and !v.ended) lost = true;
            for (v.lanes) |l| if (l) |lane| {
                if (lane.phase == .@"error") failed = true;
                if (lane.terminal) continue;
                result.active_tasks += 1;
                var tool = false;
                for (lane.requests) |p| if (p) |req| {
                    attention = attention or (req.waiting and !v.lost);
                    tool = true;
                };
                if (lane.updated >= newest and !v.lost) {
                    newest = lane.updated;
                    result.phase = if (tool) .tool else lane.phase;
                }
            };
        };
        if (attention) result.phase = .attention else if (failed) result.phase = .@"error" else if (lost) result.phase = .unknown else if (result.active_tasks == 0) {
            result.phase = .idle;
            if (self.completed_at) |t| {
                if (now >= t and now - t < self.completion_hold_ns) result.phase = .complete;
            }
        }
        return result;
    }
};
