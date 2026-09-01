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
