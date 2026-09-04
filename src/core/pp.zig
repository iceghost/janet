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
    var buffer = Buffer.init(rt, 10) catch janet.oom();
    defer buffer.deinit(rt);

    janet.value.print_description(rt, &buffer, value) catch janet.oom();
    return .wrap(String.from_bytes(rt, buffer.slice()) catch janet.oom());
}

fn to_string(value: Value) callconv(.c) String.Extern.Pointer {
    const rt = janet.Runtime.default();
    switch (value.repr.unwrap_tag()) {
        .buffer => {
            const buffer = value.unwrap().buffer;
            return .wrap(String.from_bytes(rt, buffer.slice()) catch janet.oom());
        },
        .string, .symbol, .keyword => return .wrap(value.unwrap().string),
        else => {
            var buffer = Buffer.init(rt, 10) catch janet.oom();
            defer buffer.deinit(rt);

            janet.value.print(rt, &buffer, value) catch janet.oom();
            return .wrap(String.from_bytes(rt, buffer.slice()) catch janet.oom());
        },
    }
}

fn formatc(format: [*:0]const u8, ...) callconv(.c) String.Extern.Pointer {
    const rt = janet.Runtime.default();
    const fmt = std.mem.span(format);
    var buffer = Buffer.init(rt, @intCast(fmt.len)) catch janet.oom();
    defer buffer.deinit(rt);

    var args = @cVaStart();
    defer @cVaEnd(&args);
    janet.value.vprintf(rt, &buffer, fmt, args) catch janet.oom();
    return .wrap(String.from_bytes(rt, buffer.slice()) catch janet.oom());
}

fn formatb(buffer: *Buffer, format: [*:0]const u8, ...) callconv(.c) *Buffer {
    const rt = janet.Runtime.default();
    var args = @cVaStart();
    defer @cVaEnd(&args);
    janet.value.vprintf(rt, buffer, std.mem.span(format), args) catch janet.oom();
    return buffer;
}
