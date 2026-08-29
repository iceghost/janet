const std = @import("std");
const janet = @import("janet");

comptime {
    @export(&pop, .{ .name = "janet_array_pop" });
}

fn pop(array_ext: *janet.Array.Extern) callconv(.c) janet.Value {
    const array = array_ext.cast();
    return array.pop();
}
