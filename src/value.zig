const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const assert = std.debug.assert;
const builtin = @import("builtin");

const janet = @import("janet");
const x = @import("x");

const Value = janet.Value;

pub const Array = extern struct {
    gc: janet.gc.Object,
    count: u32,
    capacity: u32,
    data: [*]janet.Value,

    /// Same as `Array`, but with potentially negative counts and null data
    pub const Extern = extern struct {
        gc: janet.gc.Object,
        count: i32,
        capacity: i32,
        data: ?[*]janet.Value,

        pub fn cast(self: *Extern) *Array {
            assert(self.count >= 0);
            assert(self.capacity >= 0);
            assert(self.data != null);
            return @ptrCast(self);
        }

        pub fn wrap(arr: *Array) *Extern {
            return @ptrCast(arr);
        }
    };

    /// Pop a value from the top of the array
    pub fn pop(self: *Array) janet.Value {
        if (self.count > 0) {
            defer self.count -= 1;
            return self.data[self.count - 1];
        } else {
            return .nil;
        }
    }
};

pub const Box = extern struct {
    repr: Nan64,

    pub const nil: Box = .{ .repr = .nil };

    pub const representation: union(enum) {
        unbox,
        nanbox32,
        nanbox64: struct {
            pointer_shift: isize,
        },
    } = blk: {
        if (!janet.options.nanbox) break :blk .unbox;

        // always work on 32-bit addresses
        if (@bitSizeOf(usize) == @bitSizeOf(u32)) break :blk .nanbox32;

        if (builtin.cpu.arch == .x86_64 or
            builtin.cpu.arch == .riscv64)
        {
            break :blk .{ .nanbox64 = .{ .pointer_shift = 0 } };
        }

        if (builtin.cpu.arch == .aarch64) {
            break :blk .{
                .nanbox64 = .{
                    .pointer_shift = if (builtin.os.tag == .macos) 0 else 2,
                },
            };
        }
    };

    pub const Nan64 = packed union(u64) {
        tagged: packed struct(u64) {
            payload: u47,
            tag: Tag,
            high: u13 = 0x1FFF,
        },
        float: f64,

        pub const Tag = enum(u4) {
            number,
            nil,
            boolean,
            fiber,
            string,
            symbol,
            keyword,
            array,
            tuple,
            table,
            @"struct",
            buffer,
            function,
            cfunction,
            abstract,
            pointer,
        };

        const pointer_shift = representation.nanbox64.pointer_shift;
        pub const nil = box_any(.nil, 1);

        pub fn hash(v: Nan64) callconv(.c) u64 {
            return @bitCast(v);
        }

        fn box_any(
            comptime tag: Tag,
            payload: anytype,
        ) Nan64 {
            return .{
                .tagged = .{
                    .tag = tag,
                    .payload = switch (@typeInfo(@TypeOf(payload))) {
                        .pointer => @truncate(@intFromPtr(payload) >> pointer_shift),
                        .int, .comptime_int => @truncate(payload),
                        else => @panic("unsupported nanbox payload: " ++ @typeName(@TypeOf(payload))),
                    },
                },
            };
        }

        fn is_tagged(v: Nan64) bool {
            return std.math.isNan(v.float) and v.tagged.high == 0x1FFF;
        }

        pub fn truthy(v: Nan64) bool {
            if (!is_tagged(v)) return true;
            return switch (v.tagged.tag) {
                .nil => false,
                .boolean => v.tagged.payload != 0,
                else => true,
            };
        }

        pub fn unwrap_tag(v: Nan64) Tag {
            if (!is_tagged(v)) return .number;
            return v.tagged.tag;
        }

        pub fn pointer_bits(v: Nan64) usize {
            return @as(usize, v.tagged.payload) << pointer_shift;
        }
    };
};

pub const Pair = extern struct {
    key: Value,
    val: Value,
};

pub const Struct = extern struct {
    gc: janet.gc.Object,
    count: u32,
    hash: u32,
    capacity: u32,
    proto: ?*Struct,
    data: [0]Pair = .{},

    pub const Extern = extern struct {
        gc: janet.gc.Object,
        count: i32,
        hash: u32,
        capacity: i32,
        proto: ?*Extern,
        data: [0]Pair = .{},

        pub const Pointer = extern struct {
            ptr: [*]align(@alignOf(Extern)) u8,

            pub fn cast_head(self: Pointer) *Struct {
                const head = x.mem_recover_head(Extern, self.ptr);
                assert(head.count >= 0);
                assert(head.capacity >= 0);
                return @ptrCast(head);
            }

            pub fn wrap(s: *Struct) Pointer {
                return .{ .ptr = @ptrCast(&s.data) };
            }
        };
    };

    pub fn begin(s: *janet.State, count: u32) Allocator.Error!*Struct {
        const doubled = std.math.mul(u32, count, 2) catch return error.OutOfMemory;
        const minimum = std.math.add(u32, doubled, 1) catch return error.OutOfMemory;
        const capacity = std.math.ceilPowerOfTwo(u32, minimum) catch return error.OutOfMemory;
        if (capacity > std.math.maxInt(i32)) return error.OutOfMemory;

        const handle, const head, const entries = try janet.gc.create_deferred(s.gpa, Struct, Pair, capacity);
        defer handle.finish(s, .@"struct");

        head.* = .{
            .gc = .disabled,
            .count = count,
            .hash = 0,
            .capacity = capacity,
            .proto = null,
        };
        @memset(entries, .{ .key = .nil, .val = .nil });

        return head;
    }
};

pub const Table = extern struct {
    gc: janet.gc.Object,
    count: u32,
    capacity: u32,
    count_deleted: u32,
    data: [*][2]janet.Value,
    proto: ?*Table,

    pub const Extern = extern struct {
        gc: janet.gc.Object,
        count: i32,
        capacity: i32,
        count_deleted: i32,
        data: ?[*][2]janet.Value,
        proto: ?*Extern,

        pub fn cast(self: *Extern) *Table {
            assert(self.count >= 0);
            assert(self.capacity >= 0);
            assert(self.data != null);
            return @ptrCast(self);
        }

        pub fn wrap(table: *Table) *Extern {
            return @ptrCast(table);
        }
    };

    pub fn create_deferred(gpa: Allocator) Allocator.Error!struct { janet.gc.Deferral, *Table } {
        const handle, const table, _ = try janet.gc.create_deferred(gpa, Table, u8, 0);
        table.* = .{
            .gc = .disabled,
            .count = 0,
            .capacity = 0,
            .count_deleted = 0,
            .data = undefined,
            .proto = null,
        };
        return .{ handle, table };
    }

    pub fn reserve_total(self: *Table, gpa: Allocator, requested: u32) Allocator.Error!void {
        var total = requested;
        total |= total >> 1;
        total |= total >> 2;
        total |= total >> 4;
        total |= total >> 8;
        total |= total >> 16;
        return self.reserve_total_precise(
            gpa,
            if (total == std.math.maxInt(u32)) total else total + 1,
        );
    }

    pub fn reserve_total_precise(self: *Table, gpa: Allocator, total: u32) Allocator.Error!void {
        if (total <= self.capacity) return;

        const size = std.math.mul(usize, total, @sizeOf([2]Value)) catch return error.OutOfMemory;
        const allocation = try janet.gc.alloc(gpa, size);
        const entries: [*][2]Value = @ptrCast(allocation.ptr);
        @memset(entries[0..total], .{ .nil, .nil });

        const old_data = self.data;
        const old_capacity = self.capacity;
        self.data = entries;
        self.capacity = total;
        self.count = 0;
        self.count_deleted = 0;

        if (old_capacity > 0) {
            for (old_data[0..old_capacity]) |entry| {
                janet_table_put(.wrap(self), entry[0], entry[1]);
            }
            janet.gc.free(gpa, @ptrCast(old_data));
        }
    }
};

fn hash_mix(input: u32, more: u32) u32 {
    const mix1 = more +% 0x9e3779b9 +% (input << 6) +% (input >> 2);
    return input ^ (0x9e3779b9 +% (mix1 << 6) +% (mix1 >> 2));
}

pub const Tuple = extern struct {
    gc: janet.gc.Object,
    count: u32,
    hash: u32,
    line: i32,
    column: i32,
    data: [0]Value = .{},

    pub fn create_from_slice(s: *janet.State, values: []const Value) Allocator.Error!*Tuple {
        const handle, const head, const elems = try janet.gc.create_deferred(s.gpa, Tuple, Value, @intCast(values.len));
        defer handle.finish(s, .tuple);

        @memcpy(elems, values);

        head.* = .{
            .gc = .disabled,
            .count = @intCast(values.len),
            // initial
            .hash = 33,
            .line = -1,
            .column = -1,
        };
        for (values) |v| head.hash = hash_mix(head.hash, hash(v));

        return head;
    }
};

extern fn janet_hash(v: Value) callconv(.c) i32;
extern fn janet_table_put(table: *Table.Extern, key: Value, value: Value) callconv(.c) void;

pub fn hash(v: Value) u32 {
    return @bitCast(janet_hash(v));
}
