const std = @import("std");
const assert = std.debug.assert;
const mem = std.mem;
const Allocator = mem.Allocator;

const janet = @import("janet");
const x = @import("x");

pub const alignment: mem.Alignment = .of(std.c.max_align_t);
pub const alignment_size = alignment.toByteUnits();

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

pub const Object = extern struct {
    flags: Flags,
    data: extern union {
        next: ?*Object,
        refcount: std.atomic.Value(i32),
    },

    pub const disabled: Object = .{
        .flags = .{
            .type = .none,
        },
        .data = .{ .next = null },
    };

    pub const Flags = packed struct(u32) {
        type: ObjectType,
        reachable: bool = false,
        disabled: bool = false,
        unused: u6 = 0,
        payload: u16 = 0,
    };

    pub fn flags_typed(
        o: *Object,
        comptime T: type,
    ) *align(@alignOf(Object):@bitOffsetOf(Flags, "payload"):@sizeOf(Flags)) T {
        return @ptrCast(&o.flags.payload);
    }
};

const AllocationHead = extern struct {
    size: usize align(alignment_size),

    pub fn allocation(self: *AllocationHead) []align(alignment_size) u8 {
        const m: [*]align(alignment_size) u8 = @ptrCast(self);
        return m[0 .. @sizeOf(AllocationHead) + self.size];
    }
};

pub const Handle = struct {
    rt: *janet.Runtime,
    object: *Object,

    pub fn finish(self: Handle, ty: ObjectType) void {
        self.object.flags.type = ty;

        const c_state = self.rt.c;
        c_state.blocks_count += 1;

        switch (self.object.flags.type) {
            .array_weak, .table_weakk, .table_weakv, .table_weakkv => {
                self.object.data.next = c_state.blocks_weak;
                c_state.blocks_weak = self.object;
            },
            else => {
                self.object.data.next = c_state.blocks;
                c_state.blocks = self.object;
            },
        }
    }

    pub fn destroy(self: Handle) void {
        free(self.rt, self.object);
    }
};

pub fn create_deferred(
    rt: *janet.Runtime,
    comptime Head: type,
    comptime Elem: type,
    count: u32,
) Allocator.Error!struct { Handle, *Head, []Elem } {
    comptime assert(@sizeOf(Head) >= @sizeOf(Object));
    comptime assert(@alignOf(Head) == @alignOf(Object));
    comptime assert(@alignOf(Elem) <= @alignOf(Head));

    const size = @sizeOf(Head) + @sizeOf(Elem) * count;
    const allocation = try alloc(rt, u8, size);
    const head, const rest = x.mem_chop_head(allocation, Head);
    const obj: *Object = @ptrCast(head);
    const body: []Elem = x.bytes_as_slice(Elem, rest);
    return .{ .{ .rt = rt, .object = obj }, head, body };
}

pub fn alloc(
    rt: *janet.Runtime,
    comptime T: type,
    count: u32,
) Allocator.Error![]align(alignment_size) T {
    const memory = try alloc_untracked(rt.gpa, @sizeOf(T) * count);
    pressure(rt, T, 0, count);
    return @ptrCast(memory);
}

/// Only used for `malloc`.
pub fn alloc_untracked(gpa: Allocator, size: usize) Allocator.Error![]align(alignment_size) u8 {
    const allocation_new = blk: {
        const size_new = std.math.add(usize, @sizeOf(AllocationHead), size) catch return error.OutOfMemory;
        break :blk try gpa.alignedAlloc(u8, alignment, size_new);
    };
    const head, const m = x.mem_chop_head(allocation_new, AllocationHead);
    head.* = .{ .size = size };
    return m;
}

pub fn realloc(
    rt: *janet.Runtime,
    comptime T: type,
    m: []align(alignment_size) T,
    count: u32,
) Allocator.Error![]align(alignment_size) T {
    const memory = try realloc_raw(rt.gpa, @ptrCast(m), @sizeOf(T) * count);
    pressure(rt, T, m.len, count);
    return x.bytes_as_slice(T, memory);
}

pub fn realloc_raw(
    gpa: Allocator,
    m: [*]align(alignment_size) u8,
    size: usize,
) Allocator.Error![]align(alignment_size) u8 {
    const allocation_new = blk: {
        const size_new = std.math.add(usize, @sizeOf(AllocationHead), size) catch return error.OutOfMemory;
        const head = x.mem_recover_head(AllocationHead, m);
        break :blk try gpa.realloc(head.allocation(), size_new);
    };
    const head_new, const m_new = x.mem_chop_head(allocation_new, AllocationHead);
    head_new.* = .{ .size = size };
    return m_new;
}

pub fn free(rt: *janet.Runtime, m: anytype) void {
    const head = x.mem_recover_head(AllocationHead, m);
    pressure(rt, u8, head.size, 0);
    rt.gpa.free(head.allocation());
}

pub fn free_untracked(gpa: Allocator, m: anytype) void {
    const head = x.mem_recover_head(AllocationHead, m);
    gpa.free(head.allocation());
}

pub fn pressure(rt: *janet.Runtime, comptime T: type, count_old: usize, count_new: usize) void {
    if (count_new >= count_old) {
        rt.c.gc_next_collection += (count_new - count_old) * @sizeOf(T);
    } else {
        rt.c.gc_next_collection -%= (count_old - count_new) * @sizeOf(T);
    }
}
