const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;

pub const State = struct {
    gpa: Allocator,
};

/// Partially specified
pub const CState = extern struct {
    /// In this Zig port, Janet VM user field is used to store Zig state
    userdata: *State,
};

const c_state = @extern(*CState, .{
    .name = "janet_vm",
    .is_thread_local = true,
});
