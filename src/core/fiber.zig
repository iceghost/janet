const janet = @import("janet");
const x = @import("x");

comptime {
    @export(&status, .{ .name = "janet_fiber_status" });
    @export(&current, .{ .name = "janet_current_fiber" });
    @export(&root, .{ .name = "janet_root_fiber" });
    @export(&set_capacity, .{ .name = "janet_fiber_setcapacity" });
    @export(&push, .{ .name = "janet_fiber_push" });
    @export(&push2, .{ .name = "janet_fiber_push2" });
    @export(&push3, .{ .name = "janet_fiber_push3" });
    @export(&pushn, .{ .name = "janet_fiber_pushn" });
    @export(&funcframe, .{ .name = "janet_fiber_funcframe" });
}

fn status(fiber: *janet.value.Fiber) callconv(.c) c_uint {
    return @intFromEnum(fiber.flags.status);
}

fn current() callconv(.c) ?*janet.value.Fiber {
    return janet.Runtime.default().c.fiber;
}

fn root() callconv(.c) ?*janet.value.Fiber {
    return janet.Runtime.default().c.fiber_root;
}

fn set_capacity(fiber: *janet.value.Fiber, capacity: i32) callconv(.c) void {
    fiber.stack.reserve_total_precise(janet.Runtime.default(), @intCast(capacity)) catch janet.oom();
}

fn push(fiber: *janet.value.Fiber, value: janet.Value) callconv(.c) void {
    fiber.stack.push(janet.Runtime.default(), value) catch janet.oom();
}

fn push2(fiber: *janet.value.Fiber, x1: janet.Value, x2: janet.Value) callconv(.c) void {
    fiber.stack.push2(janet.Runtime.default(), x1, x2) catch janet.oom();
}

fn push3(fiber: *janet.value.Fiber, x1: janet.Value, x2: janet.Value, x3: janet.Value) callconv(.c) void {
    fiber.stack.push3(janet.Runtime.default(), x1, x2, x3) catch janet.oom();
}

fn pushn(fiber: *janet.value.Fiber, values: ?[*]const janet.Value, count: i32) callconv(.c) void {
    fiber.stack.pushn(janet.Runtime.default(), x.c_slice(values, count)) catch janet.oom();
}

fn funcframe(fiber: *janet.value.Fiber, func: *janet.value.Function) callconv(.c) c_int {
    _ = fiber.stack.push_funcframe(janet.Runtime.default(), func) catch |err| switch (err) {
        error.ArityMismatch => return 1,
        error.OutOfMemory => janet.oom(),
    };
    return 0;
}
