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
    @export(&funcframe_tail, .{ .name = "janet_fiber_funcframe_tail" });
    @export(&cframe, .{ .name = "janet_fiber_cframe" });
    @export(&popframe, .{ .name = "janet_fiber_popframe" });
    @export(&env_detach, .{ .name = "janet_env_detach" });
    @export(&env_valid, .{ .name = "janet_env_valid" });
    @export(&env_maybe_detach, .{ .name = "janet_env_maybe_detach" });
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

fn funcframe_tail(fiber: *janet.value.Fiber, func: *janet.value.Function) callconv(.c) c_int {
    _ = fiber.stack.push_funcframe_tail(janet.Runtime.default(), func) catch |err| switch (err) {
        error.ArityMismatch => return 1,
        error.OutOfMemory => janet.oom(),
    };
    return 0;
}

fn cframe(fiber: *janet.value.Fiber, cfunc: janet.value.CFunction) callconv(.c) void {
    _ = fiber.stack.push_cframe(janet.Runtime.default(), cfunc) catch janet.oom();
}

fn popframe(fiber: *janet.value.Fiber) callconv(.c) void {
    fiber.stack.pop_frame(janet.Runtime.default()) catch janet.oom();
}

fn env_detach(env: ?*janet.value.FunctionEnvironment) callconv(.c) void {
    const e = env orelse return;
    e.detach(janet.Runtime.default()) catch janet.oom();
}

fn env_valid(env: *janet.value.FunctionEnvironment) callconv(.c) c_int {
    if (env.valid()) return 1;
    env.invalidate();
    return 0;
}

fn env_maybe_detach(env: *janet.value.FunctionEnvironment) callconv(.c) void {
    env.detach_maybe(janet.Runtime.default()) catch janet.oom();
}
