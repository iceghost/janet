const std = @import("std");
const janet = @import("janet");

comptime {
    @export(&pop, .{ .name = "janet_array_pop" });
}

fn pop(array: *janet.Array) callconv(.c) janet.Value {
    if (array.count > 0) {
        defer array.count -= 1;
        return array.data[@as(u32, @intCast(array.count)) - 1];
    } else {
        return .nil;
    }
}
