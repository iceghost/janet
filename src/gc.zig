const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const x = @import("x");

pub const alignment: mem.Alignment = .of(std.c.max_align_t);
pub const alignment_size = alignment.toByteUnits();

pub const ObjectType = enum(u8) {
    none,
    string,
    symbol,
    array,
    tuple,
    table,
    @"struct",
    fiber,
    buffer,
    function,
    abstract,
    funcenv,
    funcdef,
    threaded_abstract,
    table_weakk,
    table_weakv,
    table_weakkv,
    array_weak,
};

pub const Head = extern struct {
    flags: Flags,
    data: extern union {
        next: ?*Head,
        refcount: std.atomic.Value(i32),
    },

    pub const Flags = packed struct(u32) {
        type: ObjectType,
        reachable: bool = false,
        disabled: bool = false,
        unused: u6 = 0,
        payload: packed union(u16) {
            unused: u16,
        } = .{ .unused = 0 },
    };
};

const AllocationHead = extern struct {
    size: usize align(alignment_size),

    pub fn allocation(self: *AllocationHead) []align(alignment_size) u8 {
        const m: [*]align(alignment_size) u8 = @ptrCast(self);
        return m[0 .. @sizeOf(AllocationHead) + self.size];
    }
};

pub fn alloc(gpa: Allocator, size: usize) Allocator.Error![]align(alignment_size) u8 {
    const allocation_new = blk: {
        const size_new = std.math.add(usize, @sizeOf(AllocationHead), size) catch return error.OutOfMemory;
        break :blk try gpa.alignedAlloc(u8, alignment, size_new);
    };
    const head, const m = x.mem_chop_head(allocation_new, AllocationHead);
    head.* = .{ .size = size };
    return m;
}

pub fn realloc(gpa: Allocator, m: [*]align(alignment_size) u8, size: usize) Allocator.Error![]align(alignment_size) u8 {
    const allocation_new = blk: {
        const size_new = std.math.add(usize, @sizeOf(AllocationHead), size) catch return error.OutOfMemory;
        const head = x.mem_recover_head(AllocationHead, m);
        break :blk try gpa.realloc(head.allocation(), size_new);
    };
    const head_new, const m_new = x.mem_chop_head(allocation_new, AllocationHead);
    head_new.* = .{ .size = size };
    return m_new;
}

pub fn free(gpa: Allocator, m: [*]align(alignment_size) u8) void {
    const head = x.mem_recover_head(AllocationHead, m);
    gpa.free(head.allocation());
}

test "sized allocation lifecycle" {
    const gpa = std.testing.allocator;

    var memory = try alloc(gpa, 8);
    try std.testing.expectEqual(@as(usize, 8), memory.len);
    try std.testing.expectEqual(@as(usize, 0), @intFromPtr(memory.ptr) % alignment_size);
    @memset(memory, 0xA5);

    memory = try realloc(gpa, memory.ptr, 16);
    try std.testing.expectEqual(@as(usize, 16), memory.len);
    try std.testing.expectEqualSlices(u8, &([_]u8{0xA5} ** 8), memory[0..8]);

    free(gpa, memory.ptr);
}
