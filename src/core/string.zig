const janet = @import("janet");

const String = janet.value.String;

comptime {
    @export(&begin, .{ .name = "janet_string_begin" });
    @export(&end, .{ .name = "janet_string_end" });
}

fn begin(size: i32) callconv(.c) String.Extern.Pointer {
    return .wrap(String.begin(.get(), @intCast(size)) catch janet.oom());
}

fn end(string: String.Extern.Pointer) callconv(.c) String.Extern.Pointer {
    string.cast_head().end();
    return string;
}
