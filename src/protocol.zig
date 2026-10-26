//! Validation-only S4 packet codec. No device write operation is exposed.
const std = @import("std");
pub const Report = [64]u8;
pub const Command = enum(u8) { identity = 0xa1, read_lighting = 0xd5 };
pub fn readRequest(command: Command, length: u8, address: u16, handle: u8, key: u8) !Report {
    if (length > 56) return error.InvalidLength;
    var r: Report = @splat(0);
    r[0] = 0x55;
    r[1] = @backingInt(command);
    r[4] = length ^ key;
    r[5] = @as(u8, @truncate(address)) ^ key;
    r[6] = @as(u8, @truncate(address >> 8)) ^ key;
    r[7] = handle ^ key;
    r[3] = checksum(r);
    return r;
}
pub fn checksum(r: Report) u8 {
    var n: u8 = 0;
    for (r[4..]) |b| n +%= b;
    return n;
}
pub fn validateResponse(r: Report, command: Command) !void {
    if (r[0] != 0xaa or r[1] != @backingInt(command) or r[3] != checksum(r)) return error.InvalidReport;
}

pub const Gate = struct {
    schema_version: u8 = 1,
    model_id: []const u8,
    firmware: []const u8,
    platform: []const u8,
    main_solid_verified: bool,
    restore_verified: bool,
    profile_isolation_verified: bool,
    persistence_understood: bool,
    safe_write_path_verified: bool,
    reasoning_event_verified: bool,
    output_event_verified: bool,
    session_correlation_verified: bool,
    live_codex_desktop_verified: bool,
    end_to_end_p95_ms: ?u32,
    evidence_files: []const []const u8,
    pub fn ready(self: Gate) bool {
        return self.schema_version == 1 and self.model_id.len > 0 and self.firmware.len > 0 and self.platform.len > 0 and self.main_solid_verified and self.restore_verified and self.profile_isolation_verified and self.persistence_understood and self.safe_write_path_verified and self.reasoning_event_verified and self.output_event_verified and self.session_correlation_verified and self.live_codex_desktop_verified and self.end_to_end_p95_ms != null and self.end_to_end_p95_ms.? <= 500 and self.evidence_files.len > 0;
    }
};
