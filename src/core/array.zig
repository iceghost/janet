const janet = @import("janet");
const x = @import("x");

comptime {
    @export(&create, .{ .name = "janet_array" });
    @export(&create_weak, .{ .name = "janet_array_weak" });
    @export(&n, .{ .name = "janet_array_n" });
    @export(&deinit, .{ .name = "janet_array_deinit" });
    @export(&ensure, .{ .name = "janet_array_ensure" });
    @export(&set_count, .{ .name = "janet_array_setcount" });
    @export(&push, .{ .name = "janet_array_push" });
    @export(&pop, .{ .name = "janet_array_pop" });
    @export(&peek, .{ .name = "janet_array_peek" });
    @export(&trim, .{ .name = "janet_array_trim" });
}

fn create(capacity: i32) callconv(.c) *janet.Array.Extern {
    return create_typed(capacity, .array) catch janet.oom();
}

fn create_weak(capacity: i32) callconv(.c) *janet.Array.Extern {
    return create_typed(capacity, .array_weak) catch janet.oom();
}

fn create_typed(capacity: i32, object_type: janet.gc.ObjectType) !*janet.Array.Extern {
    const handle, const array = try janet.Array.create_deferred(.default());
    errdefer handle.destroy();
    try array.ensure(.default(), @intCast(capacity), 1);
    handle.finish(object_type);
    return .wrap(array);
}

fn n(elements: ?[*]const janet.Value, count: i32) callconv(.c) *janet.Array.Extern {
    const array = janet.Array.from_slice(.default(), x.c_slice(elements, count)) catch janet.oom();
    return .wrap(array);
}

fn deinit(array_ext: *janet.Array.Extern) callconv(.c) void {
    array_ext.cast().deinit(.default());
}

fn ensure(array_ext: *janet.Array.Extern, capacity: i32, growth: i32) callconv(.c) void {
    array_ext.cast().ensure(.default(), @intCast(capacity), @intCast(growth)) catch janet.oom();
}

fn set_count(array_ext: *janet.Array.Extern, count: i32) callconv(.c) void {
    array_ext.cast().set_count(.default(), @intCast(count)) catch janet.oom();
}

fn push(array_ext: *janet.Array.Extern, value: janet.Value) callconv(.c) void {
    array_ext.cast().push(.default(), value) catch janet.oom();
}

fn pop(array_ext: *janet.Array.Extern) callconv(.c) janet.Value {
    return array_ext.cast().pop();
}

fn peek(array_ext: *janet.Array.Extern) callconv(.c) janet.Value {
    return array_ext.cast().peek();
}

fn trim(array_ext: *janet.Array.Extern) callconv(.c) void {
    array_ext.cast().trim(.default()) catch janet.oom();
}
