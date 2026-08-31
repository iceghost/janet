const janet = @import("janet");

const Pair = janet.value.Pair;
const Struct = janet.value.Struct;
const Table = janet.value.Table;

comptime {
    @export(&begin, .{ .name = "janet_struct_begin" });
    @export(&put_ext, .{ .name = "janet_struct_put_ext" });
    @export(&put, .{ .name = "janet_struct_put" });
    @export(&end, .{ .name = "janet_struct_end" });
    @export(&find, .{ .name = "janet_struct_find" });
    @export(&get, .{ .name = "janet_struct_get" });
    @export(&rawget, .{ .name = "janet_struct_rawget" });
    @export(&get_ex, .{ .name = "janet_struct_get_ex" });
    @export(&to_table, .{ .name = "janet_struct_to_table" });
}

fn begin(count: i32) callconv(.c) Struct.Extern.Pointer {
    return .wrap(Struct.begin(.default(), @intCast(count)) catch janet.oom());
}

fn put_ext(st: Struct.Extern.Pointer, key: janet.Value, value: janet.Value, replace: c_int) callconv(.c) void {
    st.cast_head().put(key, value, replace != 0);
}

fn put(st: Struct.Extern.Pointer, key: janet.Value, value: janet.Value) callconv(.c) void {
    st.cast_head().put(key, value, true);
}

fn end(st: Struct.Extern.Pointer) callconv(.c) Struct.Extern.Pointer {
    return .wrap(st.cast_head().end(.default()) catch janet.oom());
}

fn find(st: Struct.Extern.Pointer, key: janet.Value) callconv(.c) ?*const Pair {
    return st.cast_head().find(key);
}

fn get(st: Struct.Extern.Pointer, key: janet.Value) callconv(.c) janet.Value {
    return st.cast_head().get(key) orelse .nil;
}

fn rawget(st: Struct.Extern.Pointer, key: janet.Value) callconv(.c) janet.Value {
    return st.cast_head().get_shallow(key) orelse .nil;
}

fn get_ex(st: Struct.Extern.Pointer, key: janet.Value, which: *Struct.Extern.Pointer) callconv(.c) janet.Value {
    const value, const proto = st.cast_head().get_proto(key) orelse return .nil;
    which.* = .wrap(proto);
    return value;
}

fn to_table(st: Struct.Extern.Pointer) callconv(.c) *Table.Extern {
    return .wrap(st.cast_head().to_table(.default()) catch janet.oom());
}
