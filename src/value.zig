const std = @import("std");
const math = std.math;
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

    pub fn checktype(v: Box, ty: Tag) bool {
        return v.repr.unwrap_tag() == ty;
    }

    pub fn unwrap(v: Box) union(Tag) { number: f64 } {
        switch (v.repr.unwrap_tag()) {
            .number => {
                //
            },
        }
    }

    pub fn wrap_keyword(s: *String) Box {
        return .{ .repr = .box_any(.keyword, String.Extern.Pointer.wrap(s).ptr) };
    }

    pub fn wrap_string(s: *String) Box {
        return .{ .repr = .box_any(.string, String.Extern.Pointer.wrap(s).ptr) };
    }

    pub fn wrap_symbol(s: *String) Box {
        return .{ .repr = .box_any(.symbol, String.Extern.Pointer.wrap(s).ptr) };
    }

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

pub const String = extern struct {
    gc: janet.gc.Object,
    size: u32,
    hash: u32,

    /// Make sure C code does not use negative i32 first
    pub const size_max = std.math.maxInt(u31);

    pub const Extern = extern struct {
        gc: janet.gc.Object,
        size: i32,
        hash: i32,
        data: [0]u8,

        pub const Pointer = extern struct {
            ptr: [*]align(@alignOf(Extern)) u8,

            pub fn cast_head(self: Pointer) *String {
                const head = x.mem_recover_head(Extern, self.ptr);
                assert(head.size >= 0);
                return @ptrCast(head);
            }

            pub fn wrap(s: *String) Pointer {
                const m = s.allocation();
                _, const data = x.mem_chop_head(m, String);
                return .{ .ptr = data.ptr };
            }
        };
    };

    fn allocation(s: *String) []align(janet.gc.alignment_size) u8 {
        const ptr: [*]align(janet.gc.alignment_size) u8 = @ptrCast(s);
        return ptr[0 .. @sizeOf(String) + s.size + 1];
    }

    /// Return the string data slice
    pub fn slice(s: *String) [:0]const u8 {
        const m = s.allocation();
        _, const data = x.mem_chop_head(m, String);
        return data[0..s.size :0];
    }

    /// `end()` and `handle.finish()` must be called afterwards
    pub fn begin_deferred(rt: *janet.State, size: u32) Allocator.Error!struct { janet.gc.Handle, *String, [:0]u8 } {
        assert(size <= size_max);
        const handle, const head, const data = try janet.gc.create_deferred(rt, String, u8, size + 1);
        head.* = .{
            .gc = .disabled,
            .size = size,
            .hash = undefined,
        };
        data[size] = 0;
        return .{ handle, head, data[0..size :0] };
    }

    pub fn end(s: *String) void {
        const m = s.allocation();
        _, const data = x.mem_chop_head(m, String);
        assert(data.len >= 1);
        s.hash = @truncate(std.hash_map.hashString(data[0..s.size]));
    }

    pub fn from_bytes(rt: *janet.State, bytes: []const u8) Allocator.Error!*String {
        const handle, const s, const data = try begin_deferred(rt, @intCast(bytes.len));
        @memcpy(data, bytes);
        s.end();
        handle.finish(.string);
        return s;
    }

    pub fn intern(rt: *janet.State, bytes: []const u8) Allocator.Error!*String {
        return rt.symbol_pool.intern(rt, bytes);
    }

    pub const Pool = struct {
        map: Map,

        pub const empty: Pool = .{
            .map = .empty,
        };

        const Map = std.ArrayHashMapUnmanaged(*String, void, Context, false);

        const Context = struct {
            pub fn hash(_: Context, s: *String) u32 {
                return s.hash;
            }

            pub fn eql(_: Context, a: *String, b: *String, _: usize) bool {
                return a == b;
            }
        };

        const Adapter = struct {
            hash_value: u32,

            pub fn hash(ctx: @This(), _: []const u8) u32 {
                return ctx.hash_value;
            }

            pub fn eql(ctx: @This(), lookup: []const u8, s: *String, _: usize) bool {
                if (ctx.hash_value != s.hash) return false;
                return mem.eql(u8, s.slice(), lookup);
            }
        };

        pub fn init(self: *Pool, allocator: Allocator) error{OutOfMemory}!void {
            try self.map.ensureTotalCapacityContext(allocator, 1024, .{});
        }

        pub fn deinit(self: *Pool, allocator: Allocator) void {
            self.map.deinit(allocator);
            self.* = .empty;
        }

        pub fn intern(self: *Pool, rt: *janet.State, bs: []const u8) error{OutOfMemory}!*String {
            const gop = try self.get_or_put(rt, bs);
            return gop.key_ptr.*;
        }

        fn get_or_put(self: *Pool, rt: *janet.State, bs: []const u8) error{OutOfMemory}!Map.GetOrPutResult {
            const hash_value: u32 = @truncate(std.hash_map.hashString(bs));

            const result = try self.map.getOrPutAdapted(rt.gpa, bs, Adapter{ .hash_value = hash_value });
            if (result.found_existing) {
                return result;
            } else {
                errdefer self.map.swapRemoveAtContext(result.index, Context{});
                const handle, const s, const data = try String.begin_deferred(rt, @intCast(bs.len));
                @memcpy(data, bs);
                s.end();
                handle.finish(.symbol);
                result.key_ptr.* = s;
                return result;
            }
        }

        pub fn remove(self: *Pool, s: *String) void {
            _ = self.map.swapRemoveContext(s, Context{});
        }
    };

    /// (gensym) string generator
    pub const Generator = struct {
        /// Generated symbols have the format _XXXXXX, where X is a base64 digit.
        counter: [7:0]u8,

        pub const init: Generator = .{
            .counter = "_000000".*,
        };

        // Increment the gensym buffer.
        fn increment(self: *Generator) void {
            var i: usize = self.counter.len - 1;
            carry: switch (self.counter[i]) {
                '9' => self.counter[i] = 'a',
                'z' => self.counter[i] = 'A',
                'Z' => {
                    self.counter[i] = '0';
                    i -= 1;
                    if (i == 0) @panic("(gensym) pool exhausted");
                    continue :carry self.counter[i];
                },
                else => self.counter[i] += 1,
            }
        }

        pub fn reset(self: *Generator) void {
            self.* = .init;
        }

        /// Generate a unique symbol for (gensym)
        pub fn next(self: *Generator, rt: *janet.State) Allocator.Error!*String {
            // There are 64^6 possible suffixes,
            // which is enough for resolving collisions.
            while (true) {
                const bs = self.counter[0..];
                const result = try rt.symbol_pool.get_or_put(rt, bs);
                if (!result.found_existing) return result.key_ptr.*;
                self.increment();
            }
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

    pub fn begin(rt: *janet.State, count: u32) Allocator.Error!*Struct {
        const doubled = std.math.mul(u32, count, 2) catch return error.OutOfMemory;
        const minimum = std.math.add(u32, doubled, 1) catch return error.OutOfMemory;
        const capacity = std.math.ceilPowerOfTwo(u32, minimum) catch return error.OutOfMemory;
        if (capacity > std.math.maxInt(i32)) return error.OutOfMemory;

        const handle, const head, const entries = try janet.gc.create_deferred(rt, Struct, Pair, capacity);
        defer handle.finish(.@"struct");

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
    data: [*]Pair,
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

    pub fn create_deferred(rt: *janet.State) Allocator.Error!struct { janet.gc.Handle, *Table } {
        const handle, const table, _ = try janet.gc.create_deferred(rt, Table, u8, 0);
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

        const size = std.math.mul(usize, total, @sizeOf(Pair)) catch return error.OutOfMemory;
        const allocation = try janet.gc.alloc(gpa, size);
        const entries: [*]Pair = @ptrCast(allocation.ptr);
        @memset(entries[0..total], .{ .key = .nil, .val = .nil });

        const old_data = self.data;
        const old_capacity = self.capacity;
        self.data = entries;
        self.capacity = total;
        self.count = 0;
        self.count_deleted = 0;

        if (old_capacity > 0) {
            for (old_data[0..old_capacity]) |entry| {
                janet_table_put(.wrap(self), entry.key, entry.val);
            }
            janet.gc.free(gpa, @ptrCast(old_data));
        }
    }

    fn grow_capacity(count: u32) u32 {
        return std.math.ceilPowerOfTwo(u32, 2 *| count +| 2) catch |err| switch (err) {
            error.Overflow => return std.math.maxInt(u32),
        };
    }

    pub fn put(self: *Table, key: Value, val: Value) void {
        if (key.checktype(.nil)) return;
        if (key.checktype(.number) and math.isNaN(key.unwrap().number)) return;
        if (val.checktype(.nil)) {
            self.remove(key);
        }

        // TODO
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

    pub fn create_from_slice(rt: *janet.State, values: []const Value) Allocator.Error!*Tuple {
        const handle, const head, const elems = try janet.gc.create_deferred(rt, Tuple, Value, @intCast(values.len));
        defer handle.finish(.tuple);

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
