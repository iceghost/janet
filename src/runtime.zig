const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;

const janet = @import("janet");

pub const State = struct {
    gpa: Allocator,
};

/// Partially specified
pub const CState = extern struct {
    /// In this Zig port, Janet VM user field is used to store Zig state
    userdata: *State,

    blocks: ?*janet.gc.Object,
    blocks_weak: ?*janet.gc.Object,
    blocks_count: usize,
    gc_interval: usize,
    gc_next_collection: usize,
    gc_suspend: c_int,
    gc_mark_phase: c_int,

    roots: ?[*]janet.Value,
    root_count: usize,
    root_capacity: usize,
};

pub const c_state = @extern(*CState, .{
    .name = "janet_vm",
    .is_thread_local = true,
});
