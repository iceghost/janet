const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const assert = std.debug.assert;
const builtin = @import("builtin");

const janet = @import("janet");

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

        pub fn hash(x: Nan64) callconv(.c) u64 {
            return @bitCast(x);
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

        fn is_tagged(x: Nan64) bool {
            return std.math.isNan(x.float) and x.tagged.high == 0x1FFF;
        }

        pub fn truthy(x: Nan64) bool {
            if (!is_tagged(x)) return true;
            return switch (x.tagged.tag) {
                .nil => false,
                .boolean => x.tagged.payload != 0,
                else => true,
            };
        }

        pub fn unwrap_tag(x: Nan64) Tag {
            if (!is_tagged(x)) return .number;
            return x.tagged.tag;
        }

        pub fn pointer_bits(x: Nan64) usize {
            return @as(usize, x.tagged.payload) << pointer_shift;
        }
    };
};

pub const Table = extern struct {
    gc: janet.gc.Object,
    count: u32,
    capacity: u32,
    count_deleted: u32,
    data: [*][2]janet.Value,
    proto: ?*Table,

    const Extern = extern struct {
        gc: janet.gc.Object,
        count: i32,
        capacity: i32,
        count_deleted: i32,
        data: ?[*][2]janet.Value,
        proto: ?*Extern,
    };

    pub fn create(_: Allocator) *Table {
        //
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

pub fn hash(v: Value) u32 {
    return @bitCast(janet_hash(v));
}
