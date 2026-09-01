const janet = @import("janet");

comptime {
    @export(&status, .{ .name = "janet_fiber_status" });
    @export(&current, .{ .name = "janet_current_fiber" });
    @export(&root, .{ .name = "janet_root_fiber" });
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
