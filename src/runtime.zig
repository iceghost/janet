const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;

const janet = @import("janet");

const Runtime = @This();

gpa: Allocator,
/// Arena lifetime tied to one GC cycle
arena_per_gc: std.heap.ArenaAllocator.State,
c: *C,

symbol_pool: janet.value.String.Pool,
symbol_generator: janet.value.String.Generator,

panic_msg: janet.Value = .nil,

/// Global state shared by all Janet VM instances
pub const Shared = struct {
    gpa: Allocator,
};

/// Partially specified
pub const C = extern struct {
    zig: *Runtime,

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

    fiber: ?*janet.value.Fiber,
    fiber_root: ?*janet.value.Fiber,

    pub fn init_zig(self: *Runtime.C) Allocator.Error!void {
        const shared = &janet.Runtime.state_shared;
        const s = try shared.gpa.create(Runtime);
        s.* = .{
            .gpa = shared.gpa,
            .arena_per_gc = .init,
            .c = self,
            .symbol_pool = .empty,
            .symbol_generator = .init,
        };
        self.zig = s;
    }

    pub fn deinit_zig(self: *Runtime.C) void {
        self.zig.gpa.destroy(self.zig);
    }
};

pub fn default() *Runtime {
    const c_state = @extern(*C, .{ .name = "janet_vm", .is_thread_local = true });
    return c_state.zig;
}

/// Initialized in `main`
pub var state_shared: Runtime.Shared = undefined;

pub const Signal = enum(c_int) {
    ok,
    @"error",
    debug,
    yield,
    user0,
    user1,
    user2,
    user3,
    user4,
    user5,
    user6,
    user7,
    interrupt,
    event,
};

pub const Error = Allocator.Error || error{
    JanetPanic,
};

extern fn janet_signalv(sig: Signal, v: janet.Value) callconv(.c) noreturn;
pub fn signal(rt: *Runtime, sig: Signal, v: janet.Value) noreturn {
    _ = rt;
    janet_signalv(sig, v);
}

pub fn oom(rt: *Runtime) noreturn {
    _ = rt; // autofix
    @panic("out of memory");
}

pub fn panic(rt: *Runtime, comptime fmt: []const u8, args: anytype) error{JanetPanic} {
    const msg = std.fmt.allocPrint(rt.gpa, fmt, args) catch rt.oom();
    defer rt.gpa.free(msg);
    rt.panic_msg = janet.Value.string(rt, msg) catch rt.oom();
    return error.JanetPanic;
}
