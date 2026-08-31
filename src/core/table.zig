const std = @import("std");

const janet = @import("janet");

const Table = janet.value.Table;

comptime {
    @export(&default, .{ .name = "janet_table" });
    @export(&weakk, .{ .name = "janet_table_weakk" });
    @export(&weakv, .{ .name = "janet_table_weakv" });
    @export(&weakkv, .{ .name = "janet_table_weakkv" });
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

fn create_typed(requested_capacity: i32, object_type: janet.gc.ObjectType) std.mem.Allocator.Error!*Table.Extern {
    const s = janet.State.get();
    const handle, const table = try Table.create_deferred(s);
    errdefer janet.gc.free(s.gpa, @ptrCast(table));

    try table.reserve_total(s.gpa, @intCast(requested_capacity));
    s.c.gc_next_collection += @as(usize, table.capacity) * @sizeOf([2]janet.Value);

    handle.finish(object_type);

    return .wrap(table);
}
