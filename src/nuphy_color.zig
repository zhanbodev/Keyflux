// SPDX-License-Identifier: MIT
// Color arithmetic adapted from NuPhy Lab's HIDBridge.swift (MIT).
// Copyright (c) 2026 NuPhy Lab contributors. See licenses/NuPhyLab-MIT.txt.
// Pinned reference and Kick75-specific validation: docs/hardware/kick75.md.
const std = @import("std");

/// Candidate byte-HSV model, enabled ONLY for the pinned Kick75 firmware.
/// Every hardware acknowledgement must still exactly match the predicted D5 RGB.
pub fn readback(rgb: [3]u8) [3]u8 {
    const r: i32 = rgb[0];
    const g: i32 = rgb[1];
    const b: i32 = rgb[2];
    const high = @max(r, g, b);
    const low = @min(r, g, b);
    const delta = high - low;
    const value = @divTrunc((@divTrunc(high * 200, 255)) * 255 + 100, 200);
    if (delta == 0) return @splat(@intCast(value));
    const saturation: i32 = @intFromFloat(@as(f32, @floatFromInt(delta)) / @as(f32, @floatFromInt(high)) * 255 + 0.5);
    var hue: f32 = if (high == r)
        @as(f32, @floatFromInt(g - b)) / @as(f32, @floatFromInt(delta)) * 43
    else if (high == g)
        (@as(f32, @floatFromInt(b - r)) / @as(f32, @floatFromInt(delta)) + 2) * 43
    else
        (@as(f32, @floatFromInt(r - g)) / @as(f32, @floatFromInt(delta)) + 4) * 43;
    if (hue < 0) hue += 255;
    const h = @as(i32, @intFromFloat(hue + 0.5)) & 255;
    const region = @divTrunc(h, 43);
    const remainder = (h - region * 43) * 6;
    const p = @divTrunc((255 - saturation) * value + 127, 255);
    const q = @divTrunc((255 - @divTrunc(saturation * remainder, 255)) * value + 127, 255);
    const t = @divTrunc((255 - @divTrunc(saturation * (255 - remainder), 255)) * value + 127, 255);
    const result: [3]i32 = switch (region) {
        0 => .{ value, t, p },
        1 => .{ q, value, p },
        2 => .{ p, value, t },
        3 => .{ p, q, value },
        4 => .{ t, p, value },
        else => .{ value, p, q },
    };
    return .{ @intCast(result[0]), @intCast(result[1]), @intCast(result[2]) };
}

/// Do not feed a quantized D5 color straight back into D6: it may drift.
/// Search a bounded neighborhood for an input that predicts the EXACT saved RGB.
pub fn encodeExact(target: [3]u8) ![3]u8 {
    if (std.mem.eql(u8, &readback(target), &target)) return target;
    for ([_]u16{ 4, 8, 16 }) |radius| {
        const lower: [3]u16 = .{ @as(u16, target[0]) -| radius, @as(u16, target[1]) -| radius, @as(u16, target[2]) -| radius };
        const upper: [3]u16 = .{ @min(255, @as(u16, target[0]) + radius), @min(255, @as(u16, target[1]) + radius), @min(255, @as(u16, target[2]) + radius) };
        for (lower[0]..upper[0] + 1) |r| {
            for (lower[1]..upper[1] + 1) |g| {
                for (lower[2]..upper[2] + 1) |b| {
                    const candidate: [3]u8 = .{ @intCast(r), @intCast(g), @intCast(b) };
                    if (std.mem.eql(u8, &readback(candidate), &target)) return candidate;
                }
            }
        }
    }
    return error.RestoreColorUnrepresentable;
}
