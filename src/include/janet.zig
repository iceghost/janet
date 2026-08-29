const std = @import("std");
const allocator = std.heap.smp_allocator;

const janet = @import("janet");
const alignment_size = janet.gc.alignment_size;

comptime {
    @export(&malloc, .{ .name = "janet_malloc" });
    @export(&calloc, .{ .name = "janet_calloc" });
    @export(&realloc, .{ .name = "janet_realloc" });
    @export(&free, .{ .name = "janet_free" });
}

fn malloc(size: usize) callconv(.c) ?[*]align(alignment_size) u8 {
    const memory = janet.gc.alloc(allocator, size) catch return null;
    return memory.ptr;
}

fn calloc(count: usize, element_size: usize) callconv(.c) ?[*]align(alignment_size) u8 {
    const size = std.math.mul(usize, count, element_size) catch return null;
    const memory = janet.gc.alloc(allocator, size) catch return null;
    @memset(memory, 0);
    return memory.ptr;
}

fn realloc(pointer: ?[*]align(alignment_size) u8, new_size: usize) callconv(.c) ?[*]align(alignment_size) u8 {
    if (pointer == null) return malloc(new_size);
    if (new_size == 0) {
        free(pointer);
        return null;
    }

    const memory = janet.gc.realloc(allocator, pointer.?, new_size) catch return null;
    return memory.ptr;
}

fn free(pointer: ?[*]align(alignment_size) u8) callconv(.c) void {
    janet.gc.free(allocator, pointer orelse return);
}
