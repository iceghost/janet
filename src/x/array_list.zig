const std = @import("std");
const assert = std.debug.assert;
const mem = std.mem;
const Allocator = mem.Allocator;

const x = @import("x");

pub fn Thin(comptime T: type) type {
    return extern struct {
        const Self = @This();

        /// This field is nullable until C vector.h is gone / fully owned by this struct
        base: ?[*]align(alignment_size) T,

        const alignment: mem.Alignment = .of(Head);
        const alignment_size = alignment.toByteUnits();

        pub const empty: Self = .{ .base = null };

        pub const Head = extern struct {
            capacity: u32 align(8),
            count: u32,

            fn allocation(self: *Head) []align(alignment_size) u8 {
                const size = @sizeOf(Head) + @as(usize, self.capacity) * @sizeOf(T);
                const memory: [*]align(alignment_size) u8 = @ptrCast(self);
                return memory[0..size];
            }
        };

        pub fn deinit(self: *Self, gpa: Allocator) void {
            if (self.base == null) return;
            gpa.free(self.head().allocation());
            self.* = .empty;
        }

        fn head(self: Self) *Head {
            return x.mem_recover_head(Head, self.base.?);
        }

        pub fn items(self: Self) []align(alignment_size) T {
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
            const new_memory = try realloc(gpa, old_memory, .{
                .count = @sizeOf(Head) + @as(usize, h.count) * @sizeOf(T),
                .total_new = new_size,
            });

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

/// Does not support allocator. Implement your own allocating/resize functions
/// in the containing data structure.
pub fn Fat(comptime T: type) type {
    return extern struct {
        const Self = @This();

        len: u32,
        capacity: u32,
        ptr: [*]T,

        pub const empty: Self = .{ .ptr = &.{}, .len = 0, .capacity = 0 };

        pub fn slice(self: *Self) []const T {
            return self.ptr[0..self.len];
        }

        pub fn append(self: *Self, item: T) void {
            assert(self.len < self.capacity);
            self.ptr[self.len] = item;
            self.len += 1;
        }

        pub fn append_slice(self: *Self, items: []const T) void {
            assert(items.len <= self.capacity - self.len);
            @memcpy(self.ptr[self.len..][0..items.len], items);
            self.len += @intCast(items.len);
        }

        pub fn pop(self: *Self) T {
            assert(self.len > 0);
            self.len -= 1;
            return self.ptr[self.len];
        }

        pub fn add_many_as_array(self: *Self, comptime n: usize) *[n]T {
            assert(n <= self.capacity - self.len);
            const start = self.len;
            self.len += n;
            return self.ptr[start..][0..n];
        }
    };
}

test "Fat adds many as array" {
    var storage: [3]u32 = undefined;
    var list: Fat(u32) = .{ .ptr = &storage, .len = 0, .capacity = storage.len };

    list.add_many_as_array(3).* = .{ 10, 20, 30 };

    try std.testing.expectEqualSlices(u32, &.{ 10, 20, 30 }, list.slice());
    try std.testing.expectEqual(30, list.pop());
}

test "Fat appends a slice" {
    var storage: [3]u32 = undefined;
    var list: Fat(u32) = .{ .ptr = &storage, .len = 0, .capacity = storage.len };

    list.append(10);
    list.append_slice(&.{ 20, 30 });

    try std.testing.expectEqualSlices(u32, &.{ 10, 20, 30 }, list.slice());
}

/// Returns a capacity larger than minimum that grows super-linearly.
pub fn grow_capacity(comptime T: type, minimum: u32) u32 {
    if (@sizeOf(T) == 0) return std.math.maxInt(u32);
    const init_capacity: comptime_int = @max(1, std.atomic.cache_line / @sizeOf(T));
    return minimum +| (minimum / 2 + init_capacity);
}

pub fn add_or_oom(num: u32, increment: usize) Allocator.Error!u32 {
    const result, const overflow = @addWithOverflow(num, increment);
    if (overflow != 0 or result > std.math.maxInt(u32)) {
        @branchHint(.unlikely);
        return error.OutOfMemory;
    }
    return @intCast(result);
}

/// `Allocator.realloc` but optimized for array list with known initialized items.
///
/// This will avoid unnecessary copying uninitialized bytes.
pub fn realloc(gpa: Allocator, allocation: anytype, options: struct {
    count: usize,
    total_new: usize,
}) Allocator.Error!@TypeOf(allocation) {
    assert(options.count <= allocation.len);
    assert(allocation.len <= options.total_new);

    if (gpa.remap(allocation, options.total_new)) |allocation_new| {
        @branchHint(.likely);
        return allocation_new;
    }

    const slice_info = @typeInfo(@TypeOf(allocation)).pointer;
    comptime assert(slice_info.size == .slice);
    const T = slice_info.child;
    const alignment = comptime mem.Alignment.fromByteUnits(slice_info.alignment orelse @alignOf(T));
    const allocation_new = try gpa.alignedAlloc(T, alignment, options.total_new);
    @memcpy(allocation_new[0..options.count], allocation[0..options.count]);
    gpa.free(allocation);
    return allocation_new;
}

test realloc {
    const gpa = std.testing.allocator;
    var allocation = try gpa.alloc(u32, 4);
    allocation[0..2].* = .{ 10, 20 };

    allocation = try realloc(gpa, allocation, .{ .count = 2, .total_new = 8 });
    defer gpa.free(allocation);

    try std.testing.expectEqual(8, allocation.len);
    try std.testing.expectEqualSlices(u32, &.{ 10, 20 }, allocation[0..2]);
}
