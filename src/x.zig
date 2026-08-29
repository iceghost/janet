const std = @import("std");
const assert = std.debug.assert;
const meta = std.meta;
const Io = std.Io;

pub const bit_set = @import("x/bit_set.zig");

pub const testing = struct {
    pub var exe_path: [:0]const u8 = undefined;
    pub var dir_fixtures: Io.Dir = undefined;
};

pub fn mem_chop_head(m: anytype, comptime Head: type) struct {
    *align(meta.alignment(@TypeOf(m))) Head,
    []align(@alignOf(Head)) u8,
} {
    const head_size = @sizeOf(Head);
    assert(m.len >= head_size);

    const head: *align(meta.alignment(@TypeOf(m))) Head = @ptrCast(m.ptr);
    const tail_pointer: [*]align(@alignOf(Head)) u8 = @alignCast(m.ptr + head_size);
    return .{ head, tail_pointer[0 .. m.len - head_size] };
}

pub fn mem_recover_head(comptime Head: type, m: [*]align(@alignOf(Head)) u8) *Head {
    const head_pointer = m - @sizeOf(Head);
    return @ptrCast(head_pointer);
}

test "chop and recover memory head" {
    const Head = extern struct {
        size: usize,
    };
    var storage: [32]u8 align(16) = undefined;
    const memory: []align(16) u8 = &storage;

    const head, const tail = mem_chop_head(memory, Head);
    head.size = tail.len;

    try std.testing.expectEqual(@as(usize, 24), tail.len);
    try std.testing.expectEqual(head, mem_recover_head(Head, tail));
    try std.testing.expectEqual(tail.len, mem_recover_head(Head, tail).size);
}
