const std = @import("std");

const janet = @import("janet");
const alignment_size = janet.gc.alignment_size;

comptime {
    @export(&malloc, .{ .name = "janet_malloc" });
    @export(&calloc, .{ .name = "janet_calloc" });
    @export(&realloc, .{ .name = "janet_realloc" });
    @export(&free, .{ .name = "janet_free" });
    @export(&smalloc, .{ .name = "janet_smalloc" });
    @export(&scalloc, .{ .name = "janet_scalloc" });
    @export(&srealloc, .{ .name = "janet_srealloc" });
    @export(&sfree, .{ .name = "janet_sfree" });
    @export(&sfreeall, .{ .name = "janet_sfreeall" });
}

/// Get the allocator initialized from main
///
/// We cannot use the threadlocal state because janet_malloc might be called
/// during thread initialization, in which the threadlocal state is not
/// initialized yet.
fn allocator() std.mem.Allocator {
    return janet.runtime.state_shared.gpa;
}

fn malloc(size: usize) callconv(.c) ?[*]align(alignment_size) u8 {
    const memory = janet.gc.alloc(allocator(), size) catch return null;
    return memory.ptr;
}

fn calloc(count: usize, element_size: usize) callconv(.c) ?[*]align(alignment_size) u8 {
    const size = std.math.mul(usize, count, element_size) catch return null;
    const memory = janet.gc.alloc(allocator(), size) catch return null;
    @memset(memory, 0);
    return memory.ptr;
}

fn realloc(pointer: ?[*]align(alignment_size) u8, new_size: usize) callconv(.c) ?[*]align(alignment_size) u8 {
    if (pointer == null) return malloc(new_size);
    if (new_size == 0) {
        free(pointer);
        return null;
    }

    const memory = janet.gc.realloc(allocator(), pointer.?, new_size) catch return null;
    return memory.ptr;
}

fn free(pointer: ?[*]align(alignment_size) u8) callconv(.c) void {
    janet.gc.free(allocator(), pointer orelse return);
}

fn smalloc(size: usize) callconv(.c) [*]align(alignment_size) u8 {
    return smalloc_error(size) catch janet.oom();
}

fn smalloc_error(size: usize) std.mem.Allocator.Error![*]align(alignment_size) u8 {
    const state = janet.State.get();
    var arena = state.arena_per_gc.promote(state.gpa);
    defer state.arena_per_gc = arena.state;

    const memory = try janet.gc.alloc(arena.allocator(), size);
    return memory.ptr;
}

fn scalloc(count: usize, element_size: usize) callconv(.c) [*]align(alignment_size) u8 {
    const size = std.math.mul(usize, count, element_size) catch janet.oom();
    const memory = smalloc(size);
    @memset(memory[0..size], 0);
    return memory;
}

fn srealloc(pointer: ?[*]align(alignment_size) u8, new_size: usize) callconv(.c) [*]align(alignment_size) u8 {
    const p = pointer orelse return smalloc(new_size);
    const state = janet.State.get();
    var arena = state.arena_per_gc.promote(state.gpa);
    defer state.arena_per_gc = arena.state;

    const memory = janet.gc.realloc(arena.allocator(), p, new_size) catch janet.oom();
    return memory.ptr;
}

fn sfree(pointer: ?[*]align(alignment_size) u8) callconv(.c) void {
    const memory = pointer orelse return;
    const state = janet.State.get();
    var arena = state.arena_per_gc.promote(state.gpa);
    defer state.arena_per_gc = arena.state;

    janet.gc.free(arena.allocator(), memory);
}

fn sfreeall() callconv(.c) void {
    const state = janet.State.get();
    var arena = state.arena_per_gc.promote(state.gpa);
    defer state.arena_per_gc = arena.state;

    _ = arena.reset(.free_all);
}
