const std = @import("std");

const janet = @import("janet");

comptime {
    @export(&n, .{ .name = "janet_tuple_n" });
}

fn n(values_ptr: ?[*]const janet.Value, count: i32) callconv(.c) [*]const janet.Value {
    const ucount: u32 = @intCast(count);
    const values = if (values_ptr) |ptr| ptr[0..ucount] else blk: {
        std.debug.assert(ucount == 0);
        break :blk &.{};
    };

    const tuple = janet.value.Tuple.create_from_slice(.get(), values) catch janet.oom();
    return @ptrCast(&tuple.data);
}
