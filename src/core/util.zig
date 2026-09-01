const std = @import("std");
const assert = std.debug.assert;

const janet = @import("janet");

const String = janet.value.String;
const Table = janet.value.Table;
const Value = janet.Value;

comptime {
    @export(&string_calchash, .{ .name = "janet_string_calchash" });
    @export(&binding_from_entry, .{ .name = "janet_binding_from_entry" });
    @export(&resolve_ext, .{ .name = "janet_resolve_ext" });
    @export(&resolve, .{ .name = "janet_resolve" });
    @export(&def, .{ .name = "janet_def" });
    @export(&@"var", .{ .name = "janet_var" });
    @export(&def_sm, .{ .name = "janet_def_sm" });
    @export(&var_sm, .{ .name = "janet_var_sm" });
}

fn string_calchash(str: [*:0]const u8, len: i32) callconv(.c) i32 {
    const ulen: u32 = @intCast(len);
    const res: u32 = @truncate(std.hash_map.hashString(str[0..ulen]));
    return @bitCast(res);
}

fn binding_from_entry(entry: Value) callconv(.c) Table.Binding {
    return .from_value(entry);
}

fn resolve_ext(env: *Table.Extern, sym: String.Extern.Pointer) callconv(.c) Table.Binding {
    return env.cast().resolve(sym.cast_head());
}

fn resolve(env: *Table.Extern, sym: String.Extern.Pointer, out: *Value) callconv(.c) Table.Binding.Type {
    const binding = resolve_ext(env, sym);
    out.* = switch (binding.type) {
        .dynamic_def, .dynamic_macro => binding.value.unwrap().array.peek(),
        else => binding.value,
    };
    return binding.type;
}

fn def(env: *Table.Extern, name: [*:0]const u8, value: Value, doc: ?[*:0]const u8) callconv(.c) void {
    bind(env, name, value, doc, null, 0, false);
}

fn @"var"(env: *Table.Extern, name: [*:0]const u8, value: Value, doc: ?[*:0]const u8) callconv(.c) void {
    bind(env, name, value, doc, null, 0, true);
}

fn def_sm(env: *Table.Extern, name: [*:0]const u8, value: Value, doc: ?[*:0]const u8, source_file: ?[*:0]const u8, source_line: i32) callconv(.c) void {
    bind(env, name, value, doc, source_file, source_line, false);
}

fn var_sm(env: *Table.Extern, name: [*:0]const u8, value: Value, doc: ?[*:0]const u8, source_file: ?[*:0]const u8, source_line: i32) callconv(.c) void {
    bind(env, name, value, doc, source_file, source_line, true);
}

fn bind(env: *Table.Extern, name: [*:0]const u8, value: Value, doc: ?[*:0]const u8, source_file: ?[*:0]const u8, source_line: i32, mutable: bool) void {
    const source: ?Table.BindOptions.Source = if (source_file != null and source_line != 0)
        .{ .file = std.mem.span(source_file.?), .line = source_line }
    else
        null;
    env.cast().bind(.default(), std.mem.span(name), value, .{
        .mutable = mutable,
        .doc = if (doc) |d| std.mem.span(d) else null,
        .source = source,
    }) catch janet.oom();
}
