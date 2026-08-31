const std = @import("std");

const janet = @import("janet");

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

fn create_typed(requested_capacity: i32, object_type: janet.gc.ObjectType) std.mem.Allocator.Error!*Table.Extern {
    const rt = janet.Runtime.default();
    const handle, const table = try Table.create_deferred(rt);
    errdefer janet.gc.free(rt.gpa, @ptrCast(table));

    try table.reserve_total(rt, @intCast(requested_capacity));
    rt.c.gc_next_collection += @as(usize, table.capacity) * @sizeOf([2]janet.Value);

    handle.finish(object_type);

    return .wrap(table);
}
