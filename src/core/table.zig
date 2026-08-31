const std = @import("std");

const janet = @import("janet");

const Pair = janet.value.Pair;
const Struct = janet.value.Struct;
const Table = janet.value.Table;

comptime {
    @export(&default, .{ .name = "janet_table" });
    @export(&weakk, .{ .name = "janet_table_weakk" });
    @export(&weakv, .{ .name = "janet_table_weakv" });
    @export(&weakkv, .{ .name = "janet_table_weakkv" });
    @export(&init, .{ .name = "janet_table_init" });
    @export(&init_raw, .{ .name = "janet_table_init_raw" });
    @export(&deinit, .{ .name = "janet_table_deinit" });
    @export(&put, .{ .name = "janet_table_put" });
    @export(&proto_flatten, .{ .name = "janet_table_proto_flatten" });
    @export(&clone, .{ .name = "janet_table_clone" });
    @export(&find, .{ .name = "janet_table_find" });
    @export(&get, .{ .name = "janet_table_get" });
    @export(&get_keyword, .{ .name = "janet_table_get_keyword" });
    @export(&get_ex, .{ .name = "janet_table_get_ex" });
    @export(&rawget, .{ .name = "janet_table_rawget" });
    @export(&remove, .{ .name = "janet_table_remove" });
    @export(&clear, .{ .name = "janet_table_clear" });
    @export(&merge_table, .{ .name = "janet_table_merge_table" });
    @export(&merge_struct, .{ .name = "janet_table_merge_struct" });
    @export(&to_struct, .{ .name = "janet_table_to_struct" });
}

fn default(capacity: i32) callconv(.c) *Table.Extern {
    return create_typed(capacity, .table) catch janet.oom();
}

fn weakk(capacity: i32) callconv(.c) *Table.Extern {
    return create_typed(capacity, .table_weakk) catch janet.oom();
}

fn weakv(capacity: i32) callconv(.c) *Table.Extern {
    return create_typed(capacity, .table_weakv) catch janet.oom();
}

fn weakkv(capacity: i32) callconv(.c) *Table.Extern {
    return create_typed(capacity, .table_weakkv) catch janet.oom();
}

fn init(t: *Table, capacity: i32) callconv(.c) *Table.Extern {
    t.* = .empty_scratch;
    t.reserve_total(.default(), @intCast(capacity)) catch janet.oom();
    return .wrap(t);
}

fn init_raw(t: *Table, capacity: i32) callconv(.c) *Table.Extern {
    t.* = .empty;
    t.reserve_total(.default(), @intCast(capacity)) catch janet.oom();
    return .wrap(t);
}

fn deinit(table: *Table.Extern) callconv(.c) void {
    const t: *Table = table.cast();
    t.clear_and_free(.default());
}

fn put(table: *Table.Extern, key: janet.Value, value: janet.Value) callconv(.c) void {
    table.cast().put(.default(), key, value) catch janet.oom();
}

fn proto_flatten(table: *Table.Extern) callconv(.c) *Table.Extern {
    const flattened = table.cast().flatten(.default()) catch janet.oom();
    return .wrap(flattened);
}

fn clone(table: *Table.Extern) callconv(.c) *Table.Extern {
    return .wrap(table.cast().clone(.default()) catch janet.oom());
}

fn find(table: *Table.Extern, key: janet.Value) callconv(.c) ?*Pair {
    const t = table.cast();
    return switch (t.probe(key)) {
        .existing,
        .not_found_but_vacant,
        .not_found_but_tombstone,
        => |i| &t.data[i],

        .not_found_and_full => null,
    };
}

fn get(table: *Table.Extern, key: janet.Value) callconv(.c) janet.Value {
    return table.cast().get(key) orelse .nil;
}

fn get_keyword(table: *Table.Extern, keyword: [*:0]const u8) callconv(.c) janet.Value {
    return table.cast().get_keyword(std.mem.span(keyword)) orelse .nil;
}

fn get_ex(table: *Table.Extern, key: janet.Value, which: *?*Table.Extern) callconv(.c) janet.Value {
    const value, const proto = table.cast().get_proto(key) orelse return .nil;
    which.* = .wrap(proto);
    return value;
}

fn rawget(table: *Table.Extern, key: janet.Value) callconv(.c) janet.Value {
    return table.cast().get_shallow(key) orelse .nil;
}

fn remove(table: *Table.Extern, key: janet.Value) callconv(.c) janet.Value {
    return table.cast().remove(key) orelse .nil;
}

fn clear(table: *Table.Extern) callconv(.c) void {
    table.cast().clear();
}

fn merge_table(table: *Table.Extern, other: *Table.Extern) callconv(.c) void {
    table.cast().merge(.default(), .from_table(other.cast())) catch janet.oom();
}

fn merge_struct(table: *Table.Extern, other: Struct.Extern.Pointer) callconv(.c) void {
    table.cast().merge(.default(), .from_struct(other.cast_head())) catch janet.oom();
}

fn to_struct(table: *Table.Extern) callconv(.c) Struct.Extern.Pointer {
    return .wrap(table.cast().to_struct(.default()) catch janet.oom());
}

fn create_typed(requested_capacity: i32, object_type: janet.gc.ObjectType) std.mem.Allocator.Error!*Table.Extern {
    const rt = janet.Runtime.default();
    const handle, const table = try Table.create_deferred(rt);
    errdefer janet.gc.free(rt.gpa, @ptrCast(table));

    try table.reserve_total(rt, @intCast(requested_capacity));
    rt.c.gc_next_collection += @as(usize, table.capacity) * @sizeOf([2]janet.Value);

    handle.finish(object_type);

    return .wrap(table);
}
