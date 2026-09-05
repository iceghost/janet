const std = @import("std");

const janet = @import("janet");
const Buffer = janet.value.Buffer;
const String = janet.value.String;
const Value = janet.Value;

comptime {
    @export(&description, .{ .name = "janet_description" });
    @export(&to_string, .{ .name = "janet_to_string" });
    @export(&formatc, .{ .name = "janet_formatc" });
    @export(&formatb, .{ .name = "janet_formatb" });
}

fn description(value: Value) callconv(.c) String.Extern.Pointer {
    const rt = janet.Runtime.default();
    return .wrap(janet.value.print_description(rt, value) catch janet.oom());
}

fn to_string(value: Value) callconv(.c) String.Extern.Pointer {
    const rt = janet.Runtime.default();
    return .wrap(janet.value.print(rt, value) catch janet.oom());
}

fn formatc(format: [*:0]const u8, ...) callconv(.c) String.Extern.Pointer {
    const rt = janet.Runtime.default();
    const fmt = std.mem.span(format);
    var args = @cVaStart();
    defer @cVaEnd(&args);
    return .wrap(janet.value.vprintf(rt, fmt, args) catch janet.oom());
}

fn formatb(buffer: *Buffer, format: [*:0]const u8, ...) callconv(.c) *Buffer {
    const rt = janet.Runtime.default();
    var args = @cVaStart();
    defer @cVaEnd(&args);
    buffer.vprintf(rt, std.mem.span(format), args) catch janet.oom();
    return buffer;
}
