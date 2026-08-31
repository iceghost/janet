const janet = @import("janet");
const x = @import("x");

const String = janet.value.String;

comptime {
    @export(&begin, .{ .name = "janet_string_begin" });
    @export(&end, .{ .name = "janet_string_end" });
    @export(&default, .{ .name = "janet_string" });
}

fn begin(size: i32) callconv(.c) String.Extern.Pointer {
    const head, _ = String.begin(.get(), @intCast(size)) catch janet.oom();
    return .wrap(head);
}

fn end(string: String.Extern.Pointer) callconv(.c) String.Extern.Pointer {
    string.cast_head().end();
    return string;
}

fn default(bytes_ptr: ?[*]const u8, size: i32) callconv(.c) String.Extern.Pointer {
    return .wrap(String.from_bytes(.get(), x.c_slice(bytes_ptr, size)) catch janet.oom());
}
