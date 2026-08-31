const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;

const janet = @import("janet");

pub const State = struct {
    gpa: Allocator,
    /// Arena lifetime tied to one GC cycle
    arena_per_gc: std.heap.ArenaAllocator.State,
    c: *C,

    /// Global state shared by all Janet VM instances
    pub const Shared = struct {
        gpa: Allocator,
    };

    /// Partially specified
    pub const C = extern struct {
        zig: *State,

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

        pub fn init_zig(
            self: *State.C,
            shared: *State.Shared,
        ) Allocator.Error!void {
            const s = try shared.gpa.create(State);
            s.* = .{
                .gpa = shared.gpa,
                .arena_per_gc = .init,
                .c = self,
            };
            self.zig = s;
        }

        pub fn deinit_zig(self: *State.C) void {
            self.zig.gpa.destroy(self.zig);
        }
    };

    pub fn get() *State {
        const c_state = @extern(*C, .{ .name = "janet_vm", .is_thread_local = true });
        return c_state.zig;
    }
};

/// Initialized in `main`
pub var state_shared: State.Shared = undefined;
