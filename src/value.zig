const std = @import("std");
const math = std.math;
const mem = std.mem;
const Allocator = mem.Allocator;
const assert = std.debug.assert;
const builtin = @import("builtin");

const janet = @import("janet");
const Value = janet.Value;
const x = @import("x");

pub const CFunction = *const fn (argc: i32, argv: [*]Value) callconv(.c) Value;

/// Maximum allowed proto search depth. Arbitrary picked number
pub const max_proto_depth: usize = 200;

pub const Array = extern struct {
    gc: janet.gc.Object,
    items: x.array_list.Fat(Value),

    pub const empty: Array = .{
        .gc = .disabled,
        .items = .empty,
    };

    pub const count_max = std.math.maxInt(i32);

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

    pub fn create_deferred(rt: *janet.Runtime) Allocator.Error!struct { janet.gc.Handle, *Array } {
        const handle, const array, _ = try janet.gc.create_deferred(rt, Array, u8, 0);
        array.* = .empty;
        return .{ handle, array };
    }

    pub fn create(rt: *janet.Runtime) Allocator.Error!*Array {
        const handle, const array = try create_deferred(rt);
        handle.finish(.array);
        return array;
    }

    pub fn from_slice(rt: *janet.Runtime, elements: []const janet.Value) Allocator.Error!*Array {
        const count: u32 = @intCast(elements.len);

        const handle, const array = try create_deferred(rt);
        errdefer handle.destroy();

        try array.reserve_growth(rt, count, 1);

        @memcpy(array.items.ptr[0..count], elements);
        array.items.len = count;

        handle.finish(.array);

        return array;
    }

    pub fn deinit(self: *Array, rt: *janet.Runtime) void {
        rt.gpa.free(self.items.ptr[0..self.items.capacity]);
        const gc = self.gc;
        self.* = .empty;
        self.gc = gc;
    }

    pub fn slice(self: *const Array) []Value {
        return self.items.ptr[0..self.items.len];
    }

    pub fn reserve(self: *Array, rt: *janet.Runtime, unused: usize) Allocator.Error!void {
        return self.reserve_total(rt, try x.array_list.add_or_oom(self.items.len, unused));
    }

    pub fn reserve_total(self: *Array, rt: *janet.Runtime, total: u32) Allocator.Error!void {
        if (total <= self.items.capacity) return;
        return self.reserve_total_precise(rt, x.array_list.grow_capacity(Value, total));
    }

    pub fn reserve_total_precise(self: *Array, rt: *janet.Runtime, total: u32) Allocator.Error!void {
        assert(total <= count_max);
        const old_capacity = self.items.capacity;
        const allocation = try x.array_list.realloc(rt.gpa, self.items.ptr[0..old_capacity], .{
            .count = self.items.len,
            .total_new = total,
        });

        self.items.ptr = allocation.ptr;
        self.items.capacity = total;
        janet.gc.pressure(rt, janet.Value, old_capacity, @intCast(total));
    }

    pub fn reserve_growth(self: *Array, rt: *janet.Runtime, requested: u32, growth: u32) Allocator.Error!void {
        if (requested <= self.items.capacity) return;
        assert(growth != 0);

        const capacity = requested *| growth;
        if (capacity > count_max) return error.OutOfMemory;
        return self.reserve_total_precise(rt, capacity);
    }

    pub fn set_count(self: *Array, rt: *janet.Runtime, count: u32) Allocator.Error!void {
        if (count > self.items.len) {
            try self.reserve_growth(rt, count, 1);
            @memset(self.items.ptr[self.items.len..count], .nil);
        }
        self.items.len = count;
    }

    pub fn push(self: *Array, rt: *janet.Runtime, value: janet.Value) Allocator.Error!void {
        assert(self.items.len < count_max);
        try self.reserve_growth(rt, self.items.len + 1, 2);
        self.items.append(value);
    }

    /// Pop a value from the top of the array
    pub fn pop(self: *Array) janet.Value {
        return if (self.items.len == 0) .nil else self.items.pop();
    }

    pub fn peek(self: *const Array) janet.Value {
        return if (self.items.len == 0) .nil else self.items.ptr[self.items.len - 1];
    }

    pub fn trim(self: *Array, rt: *janet.Runtime) Allocator.Error!void {
        if (self.items.len == self.items.capacity) return;
        if (self.items.len == 0) {
            rt.gpa.free(self.items.ptr[0..self.items.capacity]);
            const gc = self.gc;
            self.* = .empty;
            self.gc = gc;
            return;
        }

        const allocation = try x.array_list.realloc(rt.gpa, self.items.ptr[0..self.items.capacity], .{
            .count = self.items.len,
            .total_new = self.items.len,
        });
        self.items.ptr = allocation.ptr;
        self.items.capacity = self.items.len;
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
        array: *Array,
        buffer: *Buffer,
        table: *Table,
        tuple: *Tuple,
        @"struct": *Struct,
    } {
        return switch (v.repr.unwrap_tag()) {
            .number => .{ .number = v.repr.float },
            .nil => .{ .nil = {} },
            .string, .keyword, .symbol => {
                const p: String.Extern.Pointer = .{ .ptr = @ptrFromInt(v.repr.pointer_bits()) };
                return .{ .string = p.cast_head() };
            },
            .array => .{ .array = @ptrFromInt(v.repr.pointer_bits()) },
            .buffer => .{ .buffer = @ptrFromInt(v.repr.pointer_bits()) },
            .table => .{ .table = @ptrFromInt(v.repr.pointer_bits()) },
            .tuple => {
                const p: Tuple.Extern.Pointer = .{ .ptr = @ptrFromInt(v.repr.pointer_bits()) };
                return .{ .tuple = p.cast_head() };
            },
            .@"struct" => {
                const p: Struct.Extern.Pointer = .{ .ptr = @ptrFromInt(v.repr.pointer_bits()) };
                return .{ .@"struct" = p.cast_head() };
            },
            else => @panic("unimplemented"),
        };
    }

    pub fn array(s: *Array) Box {
        return .{ .repr = .box_any(.array, s) };
    }

    pub fn tuple(t: *Tuple) Box {
        return .{ .repr = .box_any(.tuple, Tuple.Extern.Pointer.wrap(t).ptr) };
    }

    pub fn @"struct"(s: *Struct) Box {
        return .{ .repr = .box_any(.@"struct", Struct.Extern.Pointer.wrap(s).ptr) };
    }

    pub fn table(t: *Table) Box {
        return .{ .repr = .box_any(.table, t) };
    }

    pub fn number(n: f64) Box {
        return .{ .repr = .{ .float = n } };
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

    pub fn symbol(rt: *janet.Runtime, s: []const u8) Allocator.Error!Box {
        return .wrap_symbol(try .intern(rt, s));
    }

    pub fn keyword(rt: *janet.Runtime, s: []const u8) Allocator.Error!Box {
        return .wrap_keyword(try .intern(rt, s));
    }

    pub fn string(rt: *janet.Runtime, s: []const u8) Allocator.Error!Box {
        return .wrap_string(try .from_bytes(rt, s));
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

pub const Buffer = extern struct {
    gc: janet.gc.Object,
    bytes: x.array_list.Fat(u8),

    pub const empty: Buffer = .{
        .gc = .disabled,
        .bytes = .empty,
    };

    pub const count_max = std.math.maxInt(i32);

    pub const Flags = packed struct(u16) {
        no_realloc: bool,
        unused: u15 = 0,
    };

    /// Same as `Buffer`, but with potentially negative counts and null data.
    pub const Extern = extern struct {
        gc: janet.gc.Object,
        count: i32,
        capacity: i32,
        data: ?[*]u8,

        pub fn cast(self: *Extern) *Buffer {
            assert(self.count >= 0);
            assert(self.capacity >= 0);
            assert(self.data != null);
            return @ptrCast(self);
        }

        pub fn wrap(buffer: *Buffer) *Extern {
            return @ptrCast(buffer);
        }
    };

    pub fn create(rt: *janet.Runtime, capacity: u32) Allocator.Error!*Buffer {
        const handle, const buffer, _ = try janet.gc.create_deferred(rt, Buffer, u8, 0);
        errdefer handle.destroy();
        buffer.* = try init(rt, capacity);
        handle.finish(.buffer);
        return buffer;
    }

    pub fn init(rt: *janet.Runtime, capacity: u32) Allocator.Error!Buffer {
        const actual_capacity = @max(capacity, 4);
        const data = try janet.gc.alloc(rt, u8, actual_capacity);
        return .{
            .gc = .disabled,
            .bytes = .{
                .ptr = data.ptr,
                .len = 0,
                .capacity = actual_capacity,
            },
        };
    }

    pub fn deinit(self: *Buffer, rt: *janet.Runtime) void {
        const data: *align(janet.gc.alignment_size) anyopaque = @ptrCast(@alignCast(self.bytes.ptr));
        janet.gc.free(rt, data);
        const gc = self.gc;
        self.* = .empty;
        self.gc = gc;
    }

    pub fn reserve(self: *Buffer, rt: *janet.Runtime, unused: usize) Allocator.Error!void {
        return self.reserve_total(rt, try x.array_list.add_or_oom(self.bytes.len, unused));
    }

    pub fn reserve_total(self: *Buffer, rt: *janet.Runtime, total: u32) Allocator.Error!void {
        if (total <= self.bytes.capacity) return;
        return self.reserve_total_precise(rt, x.array_list.grow_capacity(u8, total));
    }

    pub fn reserve_total_precise(self: *Buffer, rt: *janet.Runtime, total: u32) Allocator.Error!void {
        assert(total <= count_max);
        const old = @as([*]align(janet.gc.alignment_size) u8, @alignCast(self.bytes.ptr))[0..self.bytes.capacity];
        const allocation = try janet.gc.realloc(rt, u8, old, total);
        self.bytes.ptr = allocation.ptr;
        self.bytes.capacity = total;
    }

    pub fn reserve_growth(self: *Buffer, rt: *janet.Runtime, requested: u32, growth: u32) Allocator.Error!void {
        if (requested <= self.bytes.capacity) return;
        assert(growth != 0);

        const capacity = requested *| growth;
        if (capacity > count_max) return error.OutOfMemory;
        return self.reserve_total_precise(rt, capacity);
    }

    pub fn set_count(self: *Buffer, rt: *janet.Runtime, count: u32) Allocator.Error!void {
        if (count > self.bytes.len) {
            try self.reserve_growth(rt, count, 1);
            @memset(self.bytes.ptr[self.bytes.len..count], 0);
        }
        self.bytes.len = count;
    }

    pub fn append_slice(self: *Buffer, rt: *janet.Runtime, bytes: []const u8) Allocator.Error!void {
        if (bytes.len == 0) return;
        const count = try x.array_list.add_or_oom(self.bytes.len, bytes.len);
        if (count > count_max) return error.OutOfMemory;
        try self.reserve_growth(rt, count, 2);
        self.bytes.append_slice(bytes);
    }

    pub fn append(self: *Buffer, rt: *janet.Runtime, byte: u8) Allocator.Error!void {
        if (self.bytes.len == count_max) return error.OutOfMemory;
        try self.reserve_growth(rt, self.bytes.len + 1, 2);
        self.bytes.append(byte);
    }

    pub fn slice(self: *Buffer) []u8 {
        return self.bytes.ptr[0..self.bytes.len];
    }
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

    pub fn from_table(t: *Table) DictView {
        return .{ .ptr = t.data, .count = t.count, .capacity = t.capacity };
    }

    pub fn from_struct(t: *Struct) DictView {
        return .{ .ptr = t.slice().ptr, .count = t.count, .capacity = t.capacity };
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
    proto: Proto,

    /// Detect negatives from C code
    pub const count_max = std.math.maxInt(i32);

    pub const Extern = extern struct {
        gc: janet.gc.Object,
        count: i32,
        hash: u32,
        capacity: i32,
        proto: ?[*]const Pair,
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
                return .{ .ptr = @ptrCast(s.slice_assume_wip().ptr) };
            }
        };
    };

    pub const Proto = extern struct {
        ptr: ?[*]align(@alignOf(usize)) u8,

        const none: Proto = .{ .ptr = null };

        pub fn unwrap(self: Proto) ?*Struct {
            const ptr = self.ptr orelse return null;
            return x.mem_recover_head(Struct, ptr);
        }

        pub fn wrap(s: *Struct) Proto {
            return .{ .ptr = @ptrCast(s.slice_assume_wip().ptr) };
        }
    };

    pub fn begin(rt: *janet.Runtime, count: u32) Allocator.Error!*Struct {
        const capacity = std.math.ceilPowerOfTwo(u32, 2 *| count +| 1) catch return error.OutOfMemory;
        assert(capacity <= count_max);

        const handle, const head, const entries = try janet.gc.create_deferred(rt, Struct, Pair, capacity);
        defer handle.finish(.@"struct");

        head.* = .{
            .gc = .disabled,
            .count = count,
            .hash = 0,
            .capacity = capacity,
            .proto = .none,
        };
        @memset(entries, .{ .key = .nil, .val = .nil });

        return head;
    }

    pub fn find(self: *Struct, key: Value) ?*const Pair {
        return switch (DictView.from_struct(self).probe(key)) {
            .existing,
            .not_found_but_vacant,
            .not_found_but_tombstone,
            => |i| &self.slice_assume_wip()[i],

            .not_found_and_full => null,
        };
    }

    /// Robinhood insertion to ensure consistent key order
    pub fn put(self: *Struct, key: Value, val: Value, replace: bool) void {
        if (key.checktype(.nil) or val.checktype(.nil)) return;
        if (key.checktype(.number) and math.isNan(key.repr.float)) return;
        assert(self.hash < self.count);

        const entries = self.slice_assume_wip();
        const mask = self.capacity - 1;

        var candidate: Pair = .{ .key = key, .val = val };
        var candidate_hash = hash(key);
        var distance: u32 = 0;
        var i = candidate_hash & mask;

        while (distance < self.capacity) : ({
            distance += 1;
            i = (i + 1) & mask;
        }) {
            const entry = &entries[i];
            if (entry.key.checktype(.nil)) {
                entry.* = candidate;
                self.hash += 1;
                return;
            }

            const entry_hash = hash(entry.key);
            const entry_distance = (i + self.capacity - (entry_hash & mask)) & mask;

            const ord: std.math.Order = if (distance != entry_distance)
                std.math.order(distance, entry_distance)
            else if (candidate_hash != entry_hash)
                std.math.order(candidate_hash, entry_hash)
            else
                std.math.order(janet_compare(candidate.key, entry.key), 0);

            switch (ord) {
                .lt => {},
                .eq => {
                    if (replace) entry.val = candidate.val;
                    return;
                },
                .gt => {
                    std.mem.swap(Pair, entry, &candidate);
                    candidate_hash = entry_hash;
                    distance = entry_distance;
                },
            }
        }
    }

    /// Finish building a struct and finalize its hash.
    pub fn end(self: *Struct, rt: *janet.Runtime) Allocator.Error!*Struct {
        if (self.hash != self.count) {
            const rebuilt = try begin(rt, self.hash);
            for (self.slice_assume_wip()) |entry| {
                if (!entry.key.checktype(.nil)) rebuilt.put(entry.key, entry.val, true);
            }
            rebuilt.proto = self.proto;
            return rebuilt.end(rt);
        }

        self.hash = 33;
        for (self.slice_assume_wip()) |entry| {
            self.hash = hash_mix(self.hash, hash(entry.key));
            self.hash = hash_mix(self.hash, hash(entry.val));
        }
        if (self.proto.unwrap()) |proto| {
            self.hash +%= 2654435761 *% proto.hash;
        }
        return self;
    }

    pub fn from_slice(rt: *janet.Runtime, values: []const Value) Allocator.Error!*Struct {
        const result = try begin(rt, @intCast(@divExact(values.len, 2)));
        var i: usize = 0;
        while (i < values.len) : (i += 2) {
            result.put(values[i], values[i + 1], true);
        }
        return result.end(rt);
    }

    pub fn get_shallow(self: *Struct, key: Value) ?Value {
        return switch (DictView.from_struct(self).probe(key)) {
            .existing => |i| self.slice()[i].val,
            .not_found_but_vacant,
            .not_found_and_full,
            .not_found_but_tombstone,
            => null,
        };
    }

    pub fn get(self: *Struct, key: Value) ?Value {
        const value, _ = self.get_proto(key) orelse return null;
        return value;
    }

    pub fn get_proto(self: *Struct, key: Value) ?struct { Value, *Struct } {
        var current: ?*Struct = self;
        var depth: usize = 0;
        while (current) |st| : ({
            current = st.proto.unwrap();
            depth += 1;
        }) {
            if (depth == max_proto_depth) break;
            if (st.get_shallow(key)) |value| return .{ value, st };
        }
        return null;
    }

    pub fn to_table(self: *Struct, rt: *janet.Runtime) Allocator.Error!*Table {
        const handle, const table = try Table.create_deferred(rt);
        errdefer handle.destroy();

        try table.reserve_total(rt, self.capacity);
        errdefer table.clear_and_free(rt);

        try table.merge(rt, .from_struct(self));
        janet.gc.pressure(rt, Pair, 0, table.capacity);
        handle.finish(.table);
        return table;
    }

    fn allocation(s: *Struct) []align(janet.gc.alignment_size) u8 {
        const ptr: [*]align(janet.gc.alignment_size) u8 = @ptrCast(s);
        return ptr[0 .. @sizeOf(Struct) + @sizeOf(Pair) * s.capacity];
    }

    pub fn slice(s: *Struct) []const Pair {
        return s.slice_assume_wip();
    }

    /// Must not be mutated after hash is finalized
    fn slice_assume_wip(s: *Struct) []Pair {
        const m = s.allocation();
        _, const data = x.mem_chop_head(m, Struct);
        return x.bytes_as_slice(Pair, data);
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

    pub fn create(rt: *janet.Runtime) Allocator.Error!*Table {
        const handle, const table, _ = try janet.gc.create_deferred(rt, Table, u8, 0);
        defer handle.finish(.table);
        table.* = .empty;
        return table;
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
        const v, _ = self.get_proto(key) orelse return null;
        return v;
    }

    pub fn get_proto(self: *Table, key: Value) ?struct { Value, *Table } {
        var current: ?*Table = self;
        var depth: usize = 0;
        while (current) |table| : ({
            current = table.proto;
            depth += 1;
        }) {
            if (depth == max_proto_depth) break;
            if (table.get_shallow(key)) |val| return .{ val, table };
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

        janet.gc.pressure(rt, Pair, 0, flattened.capacity);
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

    pub fn to_struct(self: *Table, rt: *janet.Runtime) Allocator.Error!*Struct {
        const s: *Struct = try .begin(rt, self.count);
        for (self.data[0..self.capacity]) |entry| {
            if (!entry.key.checktype(.nil)) s.put(entry.key, entry.val, true);
        }
        return try s.end(rt);
    }

    /// Special type of entry in symbol tables
    pub const Binding = extern struct {
        type: Type,
        value: Value,
        deprecation: Deprecation,

        pub const none: Binding = .{
            .type = .none,
            .value = .nil,
            .deprecation = .none,
        };

        pub const Type = enum(c_int) {
            none,
            def,
            @"var",
            macro,
            dynamic_def,
            dynamic_macro,
        };

        pub const Deprecation = enum(c_int) {
            none,
            relaxed,
            normal,
            strict,
        };

        pub fn from_value(v: Value) Binding {
            if (!v.checktype(.table)) return .none;
            const table = v.unwrap().table;

            const deprecate = get_deprecation(table);
            const is_macro = get_macro(table);
            if (get_ref_and_redef(table)) |r| {
                return .{
                    .deprecation = deprecate,
                    .value = .array(r.ref),
                    .type = if (is_macro and r.redef)
                        .dynamic_macro
                    else if (r.redef)
                        .dynamic_def
                    else
                        .@"var",
                };
            } else {
                return .{
                    .deprecation = deprecate,
                    .value = table.get_keyword("value") orelse Value.nil,
                    .type = if (is_macro)
                        .macro
                    else
                        .def,
                };
            }
        }

        fn get_deprecation(binding: *Table) Deprecation {
            const kw = binding.get_keyword("deprecated") orelse return .none;
            if (kw.checktype(.nil)) return .none;

            if (kw.checktype(.keyword)) {
                const kw_data = kw.unwrap().string;
                if (mem.eql(u8, kw_data.slice(), "relaxed")) {
                    return .relaxed;
                } else if (mem.eql(u8, kw_data.slice(), "normal")) {
                    return .normal;
                } else if (mem.eql(u8, kw_data.slice(), "strict")) {
                    return .strict;
                }
            }

            return .normal;
        }

        fn get_macro(binding: *Table) bool {
            return (binding.get_keyword("macro") orelse Value.nil).repr.truthy();
        }

        fn get_ref_and_redef(binding: *Table) ?struct { ref: *Array, redef: bool } {
            const ref = binding.get_keyword("ref") orelse return null;
            if (!ref.checktype(.array)) return null;
            const redef = (binding.get_keyword("redef") orelse Value.nil).repr.truthy();
            return .{
                .ref = ref.unwrap().array,
                .redef = redef,
            };
        }

        fn set_doc(binding: *Table, rt: *janet.Runtime, doc: []const u8) !void {
            try binding.put(rt, try .keyword(rt, "doc"), try .string(rt, doc));
        }

        fn set_sourcemap(
            binding: *Table,
            rt: *janet.Runtime,
            source_file: []const u8,
            source_line: i32,
        ) !void {
            const tup: *Tuple = try .from_slice(rt, &.{
                try .string(rt, source_file),
                .number(@floatFromInt(source_line)),
                .number(1),
            });
            try binding.put(rt, try .keyword(rt, "source-map"), .tuple(tup));
        }

        fn set_value(binding: *Table, rt: *janet.Runtime, value: Value) !void {
            try binding.put(rt, try .keyword(rt, "value"), value);
        }

        fn set_ref(binding: *Table, rt: *janet.Runtime, value: Value) !void {
            const cell: *Array = try .from_slice(rt, &.{value});
            try binding.put(rt, try .keyword(rt, "ref"), .array(cell));
        }
    };

    pub fn resolve(env: *Table, sym: *String) Binding {
        return .from_value(env.get(.wrap_symbol(sym)) orelse return .none);
    }

    pub const BindOptions = struct {
        mutable: bool = false,
        doc: ?[]const u8 = null,
        source: ?Source = null,

        pub const Source = struct {
            file: []const u8,
            line: i32,
        };
    };

    /// Create a binding for `(def ...)` and `(var ...)` forms
    pub fn bind(
        env: *Table,
        rt: *janet.Runtime,
        name: []const u8,
        value: Value,
        options: BindOptions,
    ) Allocator.Error!void {
        const binding: *Table = try .create(rt);
        if (options.mutable) {
            try Binding.set_ref(binding, rt, value);
        } else {
            try Binding.set_value(binding, rt, value);
        }
        if (options.doc) |d| {
            try Binding.set_doc(binding, rt, d);
        }
        if (options.source) |s| {
            try Binding.set_sourcemap(binding, rt, s.file, s.line);
        }
        try env.put(rt, try .symbol(rt, name), .table(binding));
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

    pub const count_max = std.math.maxInt(i32);

    pub const Extern = extern struct {
        gc: janet.gc.Object,
        count: i32,
        hash: i32,
        line: i32,
        column: i32,
        data: [0]Value = .{},

        pub const Pointer = extern struct {
            ptr: [*]align(@alignOf(Extern)) u8,

            pub fn cast_head(self: Pointer) *Tuple {
                const head = x.mem_recover_head(Extern, self.ptr);
                assert(head.count >= 0);
                return @ptrCast(head);
            }

            pub fn wrap(tuple: *Tuple) Pointer {
                return .{ .ptr = @ptrCast(tuple.slice_assume_wip().ptr) };
            }
        };
    };

    pub fn begin(rt: *janet.Runtime, count: u32) Allocator.Error!*Tuple {
        assert(count <= count_max);
        const handle, const head, _ = try janet.gc.create_deferred(rt, Tuple, Value, count);
        defer handle.finish(.tuple);

        head.* = .{
            .gc = .disabled,
            .count = count,
            .hash = undefined,
            .line = -1,
            .column = -1,
        };

        return head;
    }

    pub fn end(self: *Tuple) void {
        self.hash = 33;
        for (self.slice()) |v| self.hash = hash_mix(self.hash, hash(v));
    }

    pub fn from_slice(rt: *janet.Runtime, values: []const Value) Allocator.Error!*Tuple {
        const tuple = try begin(rt, @intCast(values.len));
        @memcpy(tuple.slice_assume_wip(), values);
        tuple.end();
        return tuple;
    }

    fn allocation(tuple: *Tuple) []align(janet.gc.alignment_size) u8 {
        const ptr: [*]align(janet.gc.alignment_size) u8 = @ptrCast(tuple);
        return ptr[0 .. @sizeOf(Tuple) + @sizeOf(Value) * tuple.count];
    }

    pub fn slice(tuple: *Tuple) []const Value {
        return tuple.slice_assume_wip();
    }

    /// Must not be mutated after hash is finalized
    pub fn slice_assume_wip(tuple: *Tuple) []Value {
        const memory = tuple.allocation();
        _, const data = x.mem_chop_head(memory, Tuple);
        return x.bytes_as_slice(Value, data);
    }
};

extern fn janet_hash(v: Value) callconv(.c) i32;
extern fn janet_equals(lhs: Value, rhs: Value) callconv(.c) c_int;
extern fn janet_compare(lhs: Value, rhs: Value) callconv(.c) c_int;

pub fn order(rt: *janet.Runtime, lhs: Value, rhs: Value) std.math.Order {
    // need this for comparing abstracts
    _ = rt;
    const res = janet_compare(lhs, rhs);
    if (res < 0) return .lt;
    if (res == 0) return .eq;
    if (res > 0) return .gt;
    unreachable;
}

pub fn hash(v: Value) u32 {
    return @bitCast(janet_hash(v));
}

/// A function definition. Contains information needed to instantiate closures.
pub const FunctionDefinition = extern struct {
    gc: janet.gc.Object,
    /// Which environments to capture from the parent.
    environments: ?[*]i32,
    constants: ?[*]Value,
    defs: ?[*]*FunctionDefinition,
    bytecode: ?[*]janet.bytecode.Quadruple,
    /// Bit set indicating which slots can be referenced by closures.
    closure_bitset: ?[*]u32,

    /// Debug information.
    sourcemap: ?[*]SourceMapping,
    source: ?[*:0]const u8,
    name: ?[*:0]const u8,
    symbolmap: ?[*]SymbolMapping,

    flags: Flags,
    /// The amount of stack space required for the function.
    slotcount: u32,
    /// Does not include varargs.
    arity: u32,
    /// Includes varargs.
    min_arity: i32,
    /// Includes varargs.
    max_arity: i32,
    constants_length: i32,
    bytecode_length: i32,
    environments_length: i32,
    defs_length: i32,
    symbolmap_length: i32,
    named_args_count: i32,

    pub const Flags = packed struct(i32) {
        tag: u16,
        vararg: bool,
        needs_environment: bool,
        has_symbolmap: bool,
        has_name: bool,
        has_source: bool,
        has_defs: bool,
        has_envs: bool,
        has_sourcemap: bool,
        structarg: bool,
        has_closure_bitset: bool,
        named_args: bool,
        unused: u5 = 0,
    };

    pub const SourceMapping = extern struct {
        line: i32,
        column: i32,
    };

    pub const SymbolMapping = extern struct {
        birth_pc: u32,
        death_pc: u32,
        slot_index: u32,
        symbol: [*:0]const u8,
    };
};

pub const Function = extern struct {
    gc: janet.gc.Object,
    def: *FunctionDefinition,
    envs: [0]?*FunctionEnvironment = .{},
};

pub const FunctionEnvironment = extern struct {
    gc: janet.gc.Object,
    as: extern union {
        fiber: ?*Fiber,
        values: ?[*]Value,
    },
    /// Size of the environment.
    length: u32,
    /// Stack offset while values are on the stack. If this is zero or negative,
    /// the environment is no longer on the stack.
    offset: i32,

    /// Validate potentially untrusted func env (unmarshalled envs are difficult to verify).
    pub fn valid(self: *FunctionEnvironment) bool {
        if (self.offset >= 0) return true;

        const real_offset: u32 = @intCast(-@as(i64, self.offset));
        const fiber = self.as.fiber orelse return false;
        const slots = fiber.stack.data.ptr[0..fiber.stack.data.len];
        var view: ?Fiber.Stack.View = if (fiber.stack.frame == 0) null else .{
            .frame_begin = fiber.stack.frame,
            .frame_end = fiber.stack.stackstart,
        };
        while (view) |current| : (view = current.prev(slots)) {
            const frame = current.frame(slots);
            if (real_offset == current.frame_begin and
                frame.env == self and
                frame.func != null and
                frame.func.?.def.slotcount == self.length)
            {
                self.offset = @intCast(real_offset);
                return true;
            }
        }

        return false;
    }

    pub fn invalidate(self: *FunctionEnvironment) void {
        // Invalid, set to empty off-stack variant.
        self.offset = 0;
        self.length = 0;
        self.as.values = null;
    }

    /// If a frame has a closure environment, detach it from the stack and have it keep its own values.
    pub fn detach(self: *FunctionEnvironment, rt: *janet.Runtime) Allocator.Error!void {
        if (!self.valid()) {
            self.invalidate();
            return;
        }

        const len = self.length; // Maximum is 256.
        const values = try janet.gc.alloc(rt, Value, len);

        const fiber = self.as.fiber.?;
        const offset: u32 = @intCast(self.offset);
        @memcpy(values, fiber.stack.data.ptr[offset..][0..len]);

        const view: Fiber.Stack.View = .{
            .frame_begin = offset,
            .frame_end = undefined,
        };
        const frame = view.frame(fiber.stack.data.ptr[0..fiber.stack.data.len]);
        if (frame.func.?.def.closure_bitset) |bitset| {
            // Clear unneeded references in closure environment.
            for (values, 0..) |*value, i| {
                if (bitset[i / 32] & (@as(u32, 1) << @intCast(i % 32)) == 0) value.* = .nil;
            }
        }

        self.offset = 0;
        self.as.values = values.ptr;
    }

    /// Detach a fiber from the env if the target fiber has stopped mutating.
    pub fn detach_maybe(self: *FunctionEnvironment, rt: *janet.Runtime) Allocator.Error!void {
        // Check for detachable closure envs.
        if (!self.valid()) self.invalidate();
        if (self.offset <= 0) return;

        switch (self.as.fiber.?.flags.status) {
            .dead, .@"error", .user0, .user1, .user2, .user3, .user4 => try self.detach(rt),
            else => {},
        }
    }
};

pub const Fiber = extern struct {
    gc: janet.gc.Object,
    /// More flags
    flags: Flags,
    /// Arbitrary defined limit for stack overflow
    maxstack: u32,
    /// Stack memory
    stack: Stack,
    /// Dynamic bindings table (usually current environment).
    env: *Table,
    /// Keep linked list of fibers for restarting pending fibers
    child: ?*Fiber,
    /// Last returned value from a fiber
    last_value: Value,
    /// Increment everytime fiber is scheduled by event loop
    sched_id: u32,
    /// Call this before starting scheduled fibers
    ev_callback: ?*anyopaque,
    /// which stream we are waiting on
    ev_stream: ?*anyopaque,
    /// Extra data for ev callback state. On windows, first element must be OVERLAPPED.
    ev_state: ?*anyopaque,
    /// Channel to push self to when complete
    supervisor_channel: ?*anyopaque,

    pub const Flags = packed struct(u32) {
        ev_in_flight: bool = false,
        @"error": bool = false,
        debug: bool = false,
        yield: bool = false,
        user: u10 = 0,
        unused1: u2 = 0,
        status: Status = .dead,
        resume_signal: bool = false,
        unused2: bool = false,
        breakpoint: bool = false,
        resume_no_useval: bool = false,
        resume_no_skip: bool = false,
        did_longjump: bool = false,
        unused3: u1 = 0,
        /// Used by marshal
        haschild: bool = false,
        hasenv: bool = false,
        unused: u1 = 0,
    };

    pub const Status = enum(u6) {
        dead,
        @"error",
        debug,
        pending,
        user0,
        user1,
        user2,
        user3,
        user4,
        user5,
        user6,
        user7,
        user8,
        user9,
        new,
        alive,
        _,
    };

    pub const Stack = extern struct {
        /// Dynamically resized stack memory
        data: x.array_list.Fat(Value),
        /// Index of the stack frame
        frame: u32,
        /// Beginning of next args
        stackstart: u32,

        fn reserve(self: *Stack, rt: *janet.Runtime, unused: usize) Allocator.Error!void {
            const total_needed = try x.array_list.add_or_oom(self.data.len, unused);
            return self.reserve_total(rt, total_needed);
        }

        fn reserve_total(self: *Stack, rt: *janet.Runtime, total: u32) Allocator.Error!void {
            if (total <= self.data.capacity) return;
            const capacity_next = x.array_list.grow_capacity(Value, total);
            return self.reserve_total_precise(rt, capacity_next);
        }

        pub fn reserve_total_precise(self: *Stack, rt: *janet.Runtime, total: u32) Allocator.Error!void {
            const memory = try janet.gc.realloc(rt, Value, self.data.ptr[0..self.data.capacity], total);
            self.data.ptr = @ptrCast(memory.ptr);
            self.data.capacity = total;
        }

        pub fn push(self: *Stack, rt: *janet.Runtime, v: Value) Allocator.Error!void {
            try self.reserve(rt, 1);
            self.data.append(v);
        }

        pub fn push2(self: *Stack, rt: *janet.Runtime, x1: Value, x2: Value) Allocator.Error!void {
            try self.reserve(rt, 2);
            self.data.add_many_as_array(2).* = .{ x1, x2 };
        }

        pub fn push3(self: *Stack, rt: *janet.Runtime, x1: Value, x2: Value, x3: Value) Allocator.Error!void {
            try self.reserve(rt, 3);
            self.data.add_many_as_array(3).* = .{ x1, x2, x3 };
        }

        pub fn pushn(self: *Stack, rt: *janet.Runtime, values: []const Value) Allocator.Error!void {
            try self.reserve(rt, values.len);
            const start = self.data.len;
            const end = start + @as(u32, @intCast(values.len));
            @memcpy(self.data.ptr[start..end], values);
            self.data.len = end;
        }

        /// Pack the values passed in varargs position into a single struct or tuple.
        /// Update the stack size accordingly.
        fn pack_varargs(self: *Stack, rt: *janet.Runtime, def: *FunctionDefinition) Allocator.Error!void {
            assert(def.flags.vararg);

            const varargs_index = self.stackstart + def.arity;

            const varargs: []Value = if (varargs_index >= self.data.len) blk: {
                assert(self.data.capacity >= varargs_index);
                // This can happen if one does not pass the optional args.
                // In that case, fill with nil.
                @memset(self.data.ptr[self.data.len..varargs_index], .nil);
                break :blk &.{};
            } else blk: {
                break :blk self.data.ptr[varargs_index..self.data.len];
            };

            self.data.ptr[varargs_index] = if (def.flags.structarg) varargs: {
                // Janet silently drops an unmatched final structarg after reporting a compiler lint.
                const count_even = varargs.len - varargs.len % 2;
                break :varargs .@"struct"(try .from_slice(rt, varargs[0..count_even]));
            } else varargs: {
                break :varargs .tuple(try .from_slice(rt, varargs));
            };

            self.data.len = varargs_index + 1;
        }

        pub fn push_funcframe(self: *Stack, rt: *janet.Runtime, func: *Function) error{ ArityMismatch, OutOfMemory }!View {
            const def = func.def;
            const next_frame_begin = self.stackstart;
            const arity: i64 = self.data.len - next_frame_begin;

            if (arity < def.min_arity or arity > def.max_arity) return error.ArityMismatch;

            const next_stack_top = next_frame_begin + def.slotcount + frame_size;
            try self.reserve_total(rt, next_stack_top);

            if (def.flags.vararg) try self.pack_varargs(rt, def);

            // might be vacant now due to varargs packing
            if (self.data.len < next_stack_top) {
                @memset(self.data.ptr[self.data.len..next_stack_top], .nil);
            }

            const view: View = .{
                .frame_begin = next_frame_begin,
                .frame_end = next_stack_top,
            };
            view.frame(self.data.ptr[0..next_stack_top]).* = .{
                .func = func,
                .pc = .{ .bytecode = def.bytecode },
                .env = null,
                .prev = self.frame,
                .flags = .{
                    .tailcall = false,
                    .entrance = false,
                    .hasenv = false,
                },
            };

            self.frame = next_frame_begin;
            self.stackstart = next_stack_top;
            self.data.len = next_stack_top;
            return view;
        }

        pub fn push_funcframe_tail(self: *Stack, rt: *janet.Runtime, func: *Function) error{ ArityMismatch, OutOfMemory }!View {
            const def = func.def;
            const arity: i64 = self.data.len - self.stackstart;

            if (arity < def.min_arity or arity > def.max_arity) return error.ArityMismatch;

            const next_frame_top = self.frame + def.slotcount;
            const next_stack_top = next_frame_top + frame_size;
            const tuple_begin = self.stackstart + def.arity;
            const capacity_needed = if (def.flags.vararg)
                @max(next_stack_top, tuple_begin + 1)
            else
                next_stack_top;
            try self.reserve_total(rt, capacity_needed);

            const view: View = .{
                .frame_begin = self.frame,
                .frame_end = self.stackstart,
            };
            const frame = view.frame(self.data.ptr[0..self.data.capacity]);
            const frame_prev = frame.*;
            if (frame_prev.func != null) {
                if (frame_prev.env) |env| try env.detach(rt);
            }

            if (def.flags.vararg) try self.pack_varargs(rt, def);

            const stack_size = self.data.len - self.stackstart;
            @memmove(
                self.data.ptr[self.frame..][0..stack_size],
                self.data.ptr[self.stackstart..][0..stack_size],
            );
            if (self.frame + stack_size < next_frame_top) {
                @memset(self.data.ptr[self.frame + stack_size .. next_frame_top], .nil);
            }

            var flags = frame_prev.flags;
            flags.tailcall = true;
            flags.hasenv = false;
            frame.* = .{
                .func = func,
                .pc = .{ .bytecode = def.bytecode },
                .env = null,
                .prev = frame_prev.prev,
                .flags = flags,
            };

            self.stackstart = next_stack_top;
            self.data.len = next_stack_top;
            return .{
                .frame_begin = self.frame,
                .frame_end = next_stack_top,
            };
        }

        pub fn push_cframe(self: *Stack, rt: *janet.Runtime, cfunc: CFunction) Allocator.Error!View {
            const old_frame = self.frame;
            const next_frame_begin = self.stackstart;
            const next_stack_top = self.data.len + frame_size;
            try self.reserve_total(rt, next_stack_top);
            @memset(self.data.ptr[self.data.len..next_stack_top], .nil);

            const view: View = .{
                .frame_begin = next_frame_begin,
                .frame_end = next_stack_top,
            };
            view.frame(self.data.ptr[0..next_stack_top]).* = .{
                .func = null,
                .pc = .{ .cfunction = cfunc },
                .env = null,
                .prev = old_frame,
                .flags = .{
                    .tailcall = false,
                    .entrance = false,
                    .hasenv = false,
                },
            };

            self.frame = next_frame_begin;
            self.stackstart = next_stack_top;
            self.data.len = next_stack_top;
            return view;
        }

        pub fn pop_frame(self: *Stack, rt: *janet.Runtime) Allocator.Error!void {
            if (self.frame == 0) return;

            const view: View = .{
                .frame_begin = self.frame,
                .frame_end = self.stackstart,
            };
            const frame = view.frame(self.data.ptr[0..self.data.len]);
            const prev = frame.prev;
            if (frame.func != null) {
                if (frame.env) |env| try env.detach(rt);
            }

            self.data.len = self.frame;
            self.stackstart = self.frame;
            self.frame = prev;
        }

        pub const Frame = extern struct {
            func: ?*Function,
            pc: ProgramCounter,
            env: ?*FunctionEnvironment,
            prev: u32,
            flags: Frame.Flags,

            pub const ProgramCounter = extern union {
                bytecode: ?[*]const janet.bytecode.Quadruple,
                cfunction: CFunction,
            };

            pub const Flags = packed struct(u32) {
                tailcall: bool,
                entrance: bool,
                unused: u29 = 0,
                // used by marshalling
                hasenv: bool,
            };
        };

        pub const frame_size: u32 = 4;

        pub const View = struct {
            frame_begin: u32,
            frame_end: u32,

            pub fn frame(self: View, slots: []Value) *Frame {
                return @ptrCast(@alignCast(slots[self.frame_begin - frame_size .. self.frame_begin].ptr));
            }

            pub fn args_and_locals(self: View, slots: []Value) []Value {
                return slots[self.frame_begin .. self.frame_end - frame_size];
            }

            pub fn prev(self: View, slots: []Value) ?View {
                const f = self.frame(slots);
                if (f.prev == 0) return null;
                return .{
                    .frame_begin = f.prev,
                    .frame_end = self.frame_begin,
                };
            }
        };
    };
};

// TODO: port those later than compiler and vm
extern fn janet_formatbv(b: *Buffer, fmt: [*:0]const u8, std.builtin.VaList) void;
extern fn janet_jdn(b: ?*Buffer, depth: c_int, v: Value) *Buffer;
extern fn janet_description_b(b: *Buffer, v: Value) void;
extern fn janet_to_string_b(b: *Buffer, v: Value) void;

pub fn printf(rt: *janet.Runtime, b: *Buffer, fmt: [:0]const u8, ...) janet.Runtime.Error!void {
    var args = @cVaStart();
    defer @cVaEnd(&args);
    return vprintf(rt, b, fmt, args);
}

pub fn vprintf(rt: *janet.Runtime, b: *Buffer, fmt: [:0]const u8, args: std.builtin.VaList) janet.Runtime.Error!void {
    // not implemented yet, but at least we know:
    // - it might fail with panic (malformed fmt) or oom, so re need rt and error.
    _ = rt;
    janet_formatbv(b, fmt.ptr, args);
}

pub fn print_jdn(rt: *janet.Runtime, b: *Buffer, v: Value, options: struct {
    depth: u32 = 1024,
}) janet.Runtime.Error!void {
    // not implemented yet, but at least we know:
    // - it might fail with panic (malformed fmt) or oom, so re need rt and error.
    _ = rt;
    // in Zig we require user create the buffer, so ignore return value
    const ret = janet_jdn(b, @intCast(options.depth), v);
    assert(ret == b);
}

pub fn print_description(rt: *janet.Runtime, b: *Buffer, v: Value) janet.Runtime.Error!void {
    // not implemented yet, but at least we know:
    // - it might fail with panic (malformed fmt) or oom, so re need rt and error.
    _ = rt;
    janet_description_b(b, v);
}

pub fn print(rt: *janet.Runtime, b: *Buffer, v: Value) janet.Runtime.Error!void {
    // not implemented yet, but at least we know:
    // - it might fail with panic (malformed fmt) or oom, so re need rt and error.
    _ = rt;
    janet_to_string_b(b, v);
}
