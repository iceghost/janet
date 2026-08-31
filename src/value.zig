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
    pub const @"false": Box = .{ .repr = .box_any(.boolean, 0) };

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

    pub fn unwrap(v: Box) union {
        nil: void,
        number: f64,
        string: *String,
    } {
        return switch (v.repr.unwrap_tag()) {
            .number => .{ .number = v.repr.float },
            .nil => .{ .nil = {} },
            .string, .keyword, .symbol => {
                const p: String.Extern.Pointer = .{ .ptr = @ptrFromInt(v.repr.pointer_bits()) };
                return .{ .string = p.cast_head() };
            },
            else => @panic("unimplemented"),
        };
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
    pub fn begin_deferred(rt: *janet.Runtime, size: u32) Allocator.Error!struct { janet.gc.Handle, *String, [:0]u8 } {
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

    pub fn from_bytes(rt: *janet.Runtime, bytes: []const u8) Allocator.Error!*String {
        const handle, const s, const data = try begin_deferred(rt, @intCast(bytes.len));
        @memcpy(data, bytes);
        s.end();
        handle.finish(.string);
        return s;
    }

    pub fn intern(rt: *janet.Runtime, bytes: []const u8) Allocator.Error!*String {
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

        pub fn intern(self: *Pool, rt: *janet.Runtime, bs: []const u8) error{OutOfMemory}!*String {
            const gop = try self.get_or_put(rt, bs);
            return gop.key_ptr.*;
        }

        fn get_or_put(self: *Pool, rt: *janet.Runtime, bs: []const u8) error{OutOfMemory}!Map.GetOrPutResult {
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
        pub fn next(self: *Generator, rt: *janet.Runtime) Allocator.Error!*String {
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

pub const DictView = extern struct {
    ptr: [*]const Pair,
    count: u32,
    capacity: u32,

    pub fn from_table(t: *const Table) DictView {
        return .{ .ptr = t.data, .count = t.count, .capacity = t.capacity };
    }

    pub fn from_struct(t: *const Struct) DictView {
        return .{ .ptr = @ptrCast(&t.data), .count = t.count, .capacity = t.capacity };
    }

    pub const ProbeResult = union(enum) {
        existing: usize,
        not_found_but_vacant: usize,
        not_found_but_tombstone: usize,
        not_found_and_full,
    };

    pub fn probe(self: DictView, key: Value) ProbeResult {
        if (self.capacity == 0) return .not_found_and_full;

        const start = hash(key) & (self.capacity - 1);
        var first_tombstone: ?usize = null;

        inline for (
            [_][]const Pair{ self.ptr[start..self.capacity], self.ptr[0..start] },
            .{ start, 0 },
        ) |half, i_start| {
            for (half, i_start..) |pair, i| {
                if (pair.key.checktype(.nil)) {
                    if (pair.val.checktype(.nil)) return .{ .not_found_but_vacant = i };
                    first_tombstone = first_tombstone orelse i;
                } else if (janet_equals(pair.key, key) != 0) {
                    return .{ .existing = i };
                }
            }
        }

        return if (first_tombstone) |i|
            .{ .not_found_but_tombstone = i }
        else
            .not_found_and_full;
    }

    pub fn probe_keyword(self: DictView, kw: []const u8) ProbeResult {
        if (self.capacity == 0) return .not_found_and_full;

        const hash_val: u32 = @truncate(std.hash_map.hashString(kw));
        const start = hash_val & (self.capacity - 1);

        var first_tombstone: ?usize = null;
        inline for (
            [_][]const Pair{ self.ptr[start..self.capacity], self.ptr[0..start] },
            .{ start, 0 },
        ) |half, i_start| {
            for (half, i_start..) |pair, i| {
                if (pair.key.checktype(.nil)) {
                    if (pair.val.checktype(.nil)) return .{ .not_found_but_vacant = i };
                    first_tombstone = first_tombstone orelse i;
                } else if (pair.key.checktype(.keyword)) {
                    const s = pair.key.unwrap().string;
                    if (hash_val == s.hash and std.mem.eql(u8, s.slice(), kw)) {
                        return .{ .existing = i };
                    }
                }
            }
        }

        return if (first_tombstone) |i|
            .{ .not_found_but_vacant = i }
        else
            .not_found_and_full;
    }
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

    pub fn begin(rt: *janet.Runtime, count: u32) Allocator.Error!*Struct {
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

    pub const empty: Table = .{
        .gc = .disabled,
        .count = 0,
        .capacity = 0,
        .count_deleted = 0,
        .data = &.{},
        .proto = null,
    };

    /// Allocated using the scratch allocator
    pub const empty_scratch: Table = blk: {
        var table: Table = .empty;
        const flags = table.gc.flags_typed(Flags);
        flags.stack = true;
        break :blk table;
    };

    const Flags = packed struct(u16) {
        stack: bool,
        unused: u15 = 0,
    };

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

    pub fn create_deferred(rt: *janet.Runtime) Allocator.Error!struct { janet.gc.Handle, *Table } {
        const handle, const table, _ = try janet.gc.create_deferred(rt, Table, u8, 0);
        table.* = .empty;
        return .{ handle, table };
    }

    pub fn clear_and_free(self: *Table, rt: *janet.Runtime) void {
        var scratch = rt.arena_per_gc.promote(rt.gpa);
        defer rt.arena_per_gc = scratch.state;

        const flags = self.gc.flags_typed(Flags);
        const allocator = if (flags.stack) scratch.allocator() else rt.gpa;

        allocator.free(self.data[0..self.capacity]);

        const gc = self.gc;
        self.* = .empty;
        self.gc = gc;
    }

    pub fn reserve_total(self: *Table, rt: *janet.Runtime, requested: u32) Allocator.Error!void {
        if (requested <= self.capacity) return;
        return self.reserve_total_precise(rt, grow_capacity(requested));
    }

    pub fn probe(self: *Table, key: Value) DictView.ProbeResult {
        return DictView.from_table(self).probe(key);
    }

    pub fn get(self: *Table, key: Value) ?Value {
        var current: ?*Table = self;
        var depth: usize = 0;
        while (current) |table| : ({
            current = table.proto;
            depth += 1;
        }) {
            if (depth == max_proto_depth) break;

            switch (table.probe(key)) {
                .existing => |i| return table.data[i].val,
                .not_found_but_vacant,
                .not_found_and_full,
                .not_found_but_tombstone,
                => continue,
            }
        }
        return null;
    }

    pub fn get_proto(self: *Table, key: Value) ?struct { Value, *Table } {
        var current: ?*Table = self;
        var depth: usize = 0;
        while (current) |table| : ({
            current = table.proto;
            depth += 1;
        }) {
            if (depth == max_proto_depth) break;
            switch (table.probe(key)) {
                .existing => |i| return .{ table.data[i].val, table },
                .not_found_but_vacant,
                .not_found_and_full,
                .not_found_but_tombstone,
                => continue,
            }
        }
        return null;
    }

    pub fn get_keyword(self: *Table, keyword: []const u8) ?Value {
        var current: ?*Table = self;
        var depth: usize = 0;
        while (current) |table| : ({
            current = table.proto;
            depth += 1;
        }) {
            if (depth == max_proto_depth) break;
            const view: DictView = .from_table(table);
            switch (view.probe_keyword(keyword)) {
                .existing => |i| return table.data[i].val,
                .not_found_but_vacant,
                .not_found_and_full,
                .not_found_but_tombstone,
                => continue,
            }
        }
        return null;
    }

    pub fn get_shallow(self: *Table, key: Value) ?Value {
        return switch (self.probe(key)) {
            .existing => |i| self.data[i].val,
            .not_found_but_vacant,
            .not_found_and_full,
            .not_found_but_tombstone,
            => null,
        };
    }

    pub fn remove(self: *Table, key: Value) ?Value {
        switch (self.probe(key)) {
            .existing => |i| {
                const removed = self.data[i].val;
                self.count -= 1;
                self.count_deleted += 1;
                self.data[i] = .{ .key = .nil, .val = .false };
                return removed;
            },
            .not_found_but_vacant,
            .not_found_and_full,
            .not_found_but_tombstone,
            => return null,
        }
    }

    pub fn clear(self: *Table) void {
        @memset(self.data[0..self.capacity], .{ .key = .nil, .val = .nil });
        self.count = 0;
        self.count_deleted = 0;
    }

    fn reserve_total_precise(self: *Table, rt: *janet.Runtime, total: u32) Allocator.Error!void {
        var scratch = rt.arena_per_gc.promote(rt.gpa);
        defer rt.arena_per_gc = scratch.state;

        const flags = self.gc.flags_typed(Flags);
        const allocator = if (flags.stack) scratch.allocator() else rt.gpa;

        const allocation = try allocator.alloc(Pair, total);
        @memset(allocation, .{ .key = .nil, .val = .nil });

        const old_data = self.data;
        const old_capacity = self.capacity;
        self.data = allocation.ptr;
        self.capacity = total;
        self.count_deleted = 0;

        for (old_data[0..old_capacity]) |entry| {
            if (!entry.key.checktype(.nil)) {
                const index = switch (self.probe(entry.key)) {
                    .existing, .not_found_but_vacant, .not_found_but_tombstone => |i| i,
                    .not_found_and_full => unreachable,
                };
                self.data[index] = entry;
            }
        }
        allocator.free(old_data[0..old_capacity]);
    }

    fn grow_capacity(count: u32) u32 {
        return std.math.ceilPowerOfTwo(u32, 2 *| count +| 2) catch |err| switch (err) {
            error.Overflow => return std.math.maxInt(u32),
        };
    }

    pub fn put(self: *Table, rt: *janet.Runtime, key: Value, val: Value) Allocator.Error!void {
        if (key.checktype(.nil)) return;
        if (key.checktype(.number) and math.isNan(key.repr.float)) return;
        if (val.checktype(.nil)) {
            _ = self.remove(key);
            return;
        }

        const gop = try self.get_or_put_assume_checked(rt, key);
        self.data[gop.index].val = val;
    }

    const GetOrPutResult = struct {
        found_existing: bool,
        index: usize,
    };

    fn get_or_put_assume_checked(self: *Table, rt: *janet.Runtime, key: Value) Allocator.Error!GetOrPutResult {
        // internal use so those should be true
        assert(!key.checktype(.nil));
        assert(!key.checktype(.number) or !math.isNan(key.repr.float));

        const result_initial = self.probe(key);
        const result = find: switch (result_initial) {
            .existing => |i| return .{
                .found_existing = true,
                .index = i,
            },
            .not_found_and_full,
            .not_found_but_vacant,
            .not_found_but_tombstone,
            => |_, t| {
                if (t == .not_found_and_full or
                    self.count +| self.count_deleted +| 1 > self.capacity / 2)
                {
                    try self.reserve_total_precise(rt, grow_capacity(self.count));
                    break :find self.probe(key);
                } else {
                    break :find result_initial;
                }
            },
        };

        switch (result) {
            .existing,
            .not_found_and_full,
            => unreachable,

            .not_found_but_vacant,
            .not_found_but_tombstone,
            => |i, t| {
                if (t == .not_found_but_tombstone) self.count_deleted -= 1;
                self.count += 1;
                self.data[i].key = key;
                return .{
                    .found_existing = false,
                    .index = i,
                };
            },
        }
    }

    /// Flatten all tables in the proto chain into a new table
    pub fn flatten(self: *Table, rt: *janet.Runtime) Allocator.Error!*Table {
        const handle, const flattened = try create_deferred(rt);
        errdefer handle.destroy();

        try flattened.reserve_total(rt, self.capacity);
        errdefer flattened.clear_and_free(rt);

        var current: ?*Table = self;
        while (current) |table| : (current = table.proto) {
            for (table.data[0..table.capacity]) |entry| {
                if (!entry.key.checktype(.nil)) {
                    const gop = try flattened.get_or_put_assume_checked(rt, entry.key);
                    if (!gop.found_existing) {
                        flattened.data[gop.index].val = entry.val;
                    }
                }
            }
        }

        rt.c.gc_next_collection += @as(usize, flattened.capacity) * @sizeOf(Pair);
        handle.finish(.table);
        return flattened;
    }

    pub fn clone(self: *Table, rt: *janet.Runtime) Allocator.Error!*Table {
        const handle, const cloned = try create_deferred(rt);
        errdefer handle.destroy();

        try cloned.reserve_total_precise(rt, self.capacity);

        cloned.count = self.count;
        cloned.count_deleted = self.count_deleted;
        cloned.proto = self.proto;
        @memcpy(cloned.data[0..cloned.capacity], self.data[0..self.capacity]);
        handle.finish(.table);
        return cloned;
    }

    pub fn merge(self: *Table, rt: *janet.Runtime, view: DictView) Allocator.Error!void {
        for (view.ptr[0..view.capacity]) |entry| {
            if (!entry.key.checktype(.nil)) try self.put(rt, entry.key, entry.val);
        }
    }

    pub fn to_struct(self: *Table) [*]const Pair {
        const result = janet_struct_begin(@intCast(self.count));
        for (self.data[0..self.capacity]) |entry| {
            if (!entry.key.checktype(.nil)) janet_struct_put(result, entry.key, entry.val);
        }
        return janet_struct_end(result);
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

    pub fn create_from_slice(rt: *janet.Runtime, values: []const Value) Allocator.Error!*Tuple {
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
extern fn janet_equals(lhs: Value, rhs: Value) callconv(.c) c_int;
extern fn janet_struct_begin(count: i32) callconv(.c) [*]Pair;
extern fn janet_struct_put(st: [*]Pair, key: Value, value: Value) callconv(.c) void;
extern fn janet_struct_end(st: [*]Pair) callconv(.c) [*]const Pair;

pub fn hash(v: Value) u32 {
    return @bitCast(janet_hash(v));
}
