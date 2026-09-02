const std = @import("std");
const assert = std.debug.assert;
const meta = std.meta;
const Io = std.Io;

pub const bit_set = @import("x/bit_set.zig");
pub const array_list = @import("x/array_list.zig");

test {
    _ = bit_set;
    _ = array_list;
}

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

pub fn mem_recover_head(comptime Head: type, m_ptr: *align(@alignOf(Head)) anyopaque) *Head {
    const m: [*]align(@alignOf(Head)) u8 = @ptrCast(m_ptr);
    const head_pointer = m - @sizeOf(Head);
    return @ptrCast(head_pointer);
}

fn CopyPtrAttrs(
    comptime source: type,
    comptime size: std.builtin.Type.Pointer.Size,
    comptime child: type,
) type {
    const ptr = @typeInfo(source).pointer;
    return @Pointer(size, .{
        .@"const" = ptr.is_const,
        .@"volatile" = ptr.is_volatile,
        .@"allowzero" = ptr.is_allowzero,
        .@"align" = ptr.alignment orelse a: {
            const want = @alignOf(ptr.child);
            break :a if (@alignOf(child) == want) null else want;
        },
        .@"addrspace" = ptr.address_space,
    }, child, null);
}

fn BytesAsSliceReturnType(comptime T: type, comptime bytesType: type) type {
    return CopyPtrAttrs(bytesType, .slice, T);
}

/// Reinterpret bytes as a slice while preserving the input pointer when empty.
///
/// This is different in `std.mem.bytesAsSlice` in that it preserves the pointer on empty slice.
pub fn bytes_as_slice(comptime T: type, bytes: anytype) BytesAsSliceReturnType(T, @TypeOf(bytes)) {
    assert(@sizeOf(T) != 0);
    const cast_target = CopyPtrAttrs(@TypeOf(bytes), .many, T);
    return @as(cast_target, @ptrCast(bytes))[0..@divExact(bytes.len, @sizeOf(T))];
}

test bytes_as_slice {
    var storage: [16]u8 align(8) = undefined;

    const values = bytes_as_slice(u64, storage[0..]);
    try std.testing.expectEqual(@as(usize, 2), values.len);
    try std.testing.expectEqual(@intFromPtr(storage[0..].ptr), @intFromPtr(values.ptr));

    const bytes_empty = storage[16..16];
    const values_empty = bytes_as_slice(u64, bytes_empty);
    try std.testing.expectEqual(@as(usize, 0), values_empty.len);
    try std.testing.expectEqual(@intFromPtr(bytes_empty.ptr), @intFromPtr(values_empty.ptr));
}

pub fn CSlice(comptime MaybePointer: type) type {
    const Pointer = @typeInfo(MaybePointer).optional.child;
    const info = @typeInfo(Pointer).pointer;
    assert(info.size == .many);
    // TODO: figure how to do sentinel
    assert(info.sentinel() == null);
    return @Pointer(.slice, .{
        .@"const" = info.is_const,
        .@"volatile" = info.is_volatile,
        .@"allowzero" = info.is_allowzero,
        .@"addrspace" = info.address_space,
        .@"align" = info.alignment,
    }, info.child, null);
}

/// Construct a Zig slice from C nullable ptr and len pair
pub fn c_slice(ptr: anytype, len: i32) CSlice(@TypeOf(ptr)) {
    const ulen: u32 = @intCast(len);
    if (ptr == null) {
        assert(ulen == 0);
        return &.{};
    } else {
        return ptr.?[0..ulen];
    }
}

test c_slice {
    try std.testing.expect(CSlice(?[*]align(16) const volatile u8) == []align(16) const volatile u8);

    {
        var values = [_]u16{ 1, 2, 3 };
        const slice = c_slice(@as(?[*]u16, &values), 3);
        try std.testing.expectEqualSlices(u16, &values, slice);
    }

    const empty = c_slice(@as(?[*]const u16, null), 0);
    try std.testing.expectEqual(@as(usize, 0), empty.len);

    // {
    //     var values = [_:0]u16{ 1, 2, 3 };
    //     const slice = c_slice(@as(?[*:0]u16, &values), 3);
    //     try std.testing.expectEqualSlices(u16, &values, slice);
    // }
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
    try std.testing.expectEqual(head, mem_recover_head(Head, tail.ptr));
    try std.testing.expectEqual(tail.len, mem_recover_head(Head, tail.ptr).size);
}
