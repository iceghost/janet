const janet = @import("janet");
const x = @import("x");

comptime {
    @export(&n, .{ .name = "janet_tuple_n" });
}

fn n(values_ptr: ?[*]const janet.Value, count: i32) callconv(.c) [*]const janet.Value {
    const values: []const janet.Value = x.c_slice(values_ptr, count);
    const tuple = janet.value.Tuple.create_from_slice(.get(), values) catch janet.oom();
    return @ptrCast(&tuple.data);
}
