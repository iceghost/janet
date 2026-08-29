const std = @import("std");

pub const ObjectType = enum(u8) {
    none,
    string,
    symbol,
    array,
    tuple,
    table,
    @"struct",
    fiber,
    buffer,
    function,
    abstract,
    funcenv,
    funcdef,
    threaded_abstract,
    table_weakk,
    table_weakv,
    table_weakkv,
    array_weak,
};

pub const Head = extern struct {
    flags: Flags,
    data: extern union {
        next: ?*Head,
        refcount: std.atomic.Value(i32),
    },

    pub const Flags = packed struct(u32) {
        type: ObjectType,
        reachable: bool = false,
        disabled: bool = false,
        unused: u6 = 0,
        payload: packed union(u16) {
            unused: u16,
        } = .{ .unused = 0 },
    };
};
