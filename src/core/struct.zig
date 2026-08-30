const janet = @import("janet");

const Struct = janet.value.Struct;

comptime {
    @export(&begin, .{ .name = "janet_struct_begin" });
}

fn begin(count: i32) callconv(.c) Struct.Extern.Pointer {
    return .wrap(Struct.begin(.get(), @intCast(count)) catch janet.oom());
}
