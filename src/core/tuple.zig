const janet = @import("janet");
const x = @import("x");

const Tuple = janet.value.Tuple;

comptime {
    @export(&begin, .{ .name = "janet_tuple_begin" });
    @export(&end, .{ .name = "janet_tuple_end" });
    @export(&n, .{ .name = "janet_tuple_n" });
}

fn begin(count: i32) callconv(.c) Tuple.Extern.Pointer {
    return .wrap(Tuple.begin(.default(), @intCast(count)) catch janet.oom());
}

fn end(tuple: Tuple.Extern.Pointer) callconv(.c) Tuple.Extern.Pointer {
    tuple.cast_head().end();
    return tuple;
}

fn n(values_ptr: ?[*]const janet.Value, count: i32) callconv(.c) Tuple.Extern.Pointer {
    const values: []const janet.Value = x.c_slice(values_ptr, count);
    return .wrap(Tuple.from_slice(.default(), values) catch janet.oom());
}
