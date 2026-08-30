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

    var state: janet.runtime.State = .{
        .gpa = std.heap.smp_allocator,
        .c_state = janet.runtime.c_state(),
    };
    const tuple = janet.value.Tuple.create_from_slice(&state, values) catch janet.oom();
    return @ptrCast(&tuple.data);
}
