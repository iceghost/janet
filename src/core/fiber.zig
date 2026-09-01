const janet = @import("janet");

comptime {
    @export(&status, .{ .name = "janet_fiber_status" });
    @export(&current, .{ .name = "janet_current_fiber" });
    @export(&root, .{ .name = "janet_root_fiber" });
    @export(&push, .{ .name = "janet_fiber_push" });
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

fn push(fiber: *janet.value.Fiber, value: janet.Value) callconv(.c) void {
    fiber.stack.push(janet.Runtime.default(), value) catch janet.oom();
}
