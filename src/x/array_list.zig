const std = @import("std");
const assert = std.debug.assert;
const mem = std.mem;
const Allocator = mem.Allocator;

const x = @import("x");

pub fn Thin(comptime T: type) type {
    const alignment: mem.Alignment = .of([2]u32);
    const alignment_size = alignment.toByteUnits();

    return extern struct {
        const Self = @This();

        /// This field is nullable until C vector.h is gone / fully owned by this struct
        base: ?[*]align(alignment_size) T,

        pub const empty: Self = .{ .base = null };

        pub const Head = extern struct {
            capacity: u32,
            count: u32,

            fn allocation(self: *Head) []align(alignment_size) u8 {
                const size = @sizeOf(Head) + @as(usize, self.capacity) * @sizeOf(T);
                const memory: [*]align(alignment_size) u8 = @ptrCast(self);
                return memory[0..size];
            }
        };

        fn deinit(self: *Self, gpa: Allocator) void {
            if (self.base == null) return;
            gpa.free(self.head().allocation());
            self.* = .empty;
        }

        fn head(self: Self) *Head {
            return x.mem_recover_head(Head, @ptrCast(self.base.?));
        }

        pub fn items(self: *Self) []align(alignment_size) T {
            if (self.base) |b| {
                const h = self.head();
                return b[0..h.count];
            } else {
                return &.{};
            }
        }

        pub fn reserve_total_precise(self: *Self, gpa: Allocator, total: u32) Allocator.Error!void {
            if (self.base == null) {
                if (total == 0) return;
                const size = @sizeOf(Head) + @as(usize, total) * @sizeOf(T);
                const memory = try gpa.alignedAlloc(u8, alignment, size);
                const h, const elems = x.mem_chop_head(memory, Head);
                h.* = .{
                    .capacity = total,
                    .count = 0,
                };
                self.base = @ptrCast(elems.ptr);
                return;
            }

            const h = self.head();
            if (total <= h.capacity) return;

            const new_size = @sizeOf(Head) + @as(usize, total) * @sizeOf(T);
            const old_memory = h.allocation();
            const new_memory = if (gpa.remap(old_memory, new_size)) |memory|
                memory
            else blk: {
                const memory = try gpa.alignedAlloc(u8, alignment, new_size);
                const used_size = @sizeOf(Head) + @as(usize, h.count) * @sizeOf(T);
                @memcpy(memory[0..used_size], old_memory[0..used_size]);
                gpa.free(old_memory);
                break :blk memory;
            };

            const new_head, const elems = x.mem_chop_head(new_memory, Head);
            new_head.capacity = total;
            self.base = @ptrCast(elems.ptr);
        }

        pub fn append(self: Self, item: T) void {
            const h = self.head();
            self.base.?[h.count] = item;
            h.count += 1;
        }

        pub fn pop(self: Self) T {
            const h = self.head();
            assert(h.count > 0);
            h.count -= 1;
            return self.base.?[h.count];
        }
    };
}

test "Thin appends and pops items" {
    const List = Thin(u32);
    var list: List = .empty;
    defer list.deinit(std.testing.allocator);

    try list.reserve_total_precise(std.testing.allocator, 2);
    list.append(10);
    list.append(20);

    try std.testing.expectEqualSlices(u32, &.{ 10, 20 }, list.items());
    try std.testing.expectEqual(20, list.pop());
    try std.testing.expectEqual(10, list.pop());
}

test "Thin reserves exact capacity and preserves items" {
    const List = Thin(u32);
    const initial_capacity = 2;
    var list: List = .empty;
    defer list.deinit(std.testing.allocator);

    try list.reserve_total_precise(std.testing.allocator, initial_capacity);
    list.append(10);
    list.append(20);

    try list.reserve_total_precise(std.testing.allocator, initial_capacity);
    try list.reserve_total_precise(std.testing.allocator, 5);
    list.append(30);

    try std.testing.expectEqual(30, list.pop());
    try std.testing.expectEqual(20, list.pop());
    try std.testing.expectEqual(10, list.pop());
}
