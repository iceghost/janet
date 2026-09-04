const std = @import("std");

const janet = @import("janet");
const Buffer = janet.Buffer;
const x = @import("x");

comptime {
    @export(&create, .{ .name = "janet_buffer" });
    @export(&init, .{ .name = "janet_buffer_init" });
    @export(&pointer_unsafe, .{ .name = "janet_pointer_buffer_unsafe" });
    @export(&deinit, .{ .name = "janet_buffer_deinit" });
    @export(&ensure, .{ .name = "janet_buffer_ensure" });
    @export(&set_count, .{ .name = "janet_buffer_setcount" });
    @export(&extra, .{ .name = "janet_buffer_extra" });
    @export(&push_bytes, .{ .name = "janet_buffer_push_bytes" });
    @export(&push_string, .{ .name = "janet_buffer_push_string" });
    @export(&push_cstring, .{ .name = "janet_buffer_push_cstring" });
    @export(&push_u8, .{ .name = "janet_buffer_push_u8" });
    @export(&push_u16, .{ .name = "janet_buffer_push_u16" });
    @export(&push_u32, .{ .name = "janet_buffer_push_u32" });
    @export(&push_u64, .{ .name = "janet_buffer_push_u64" });
    @export(&trim, .{ .name = "janet_buffer_trim" });
}

extern fn janet_panic(message: [*:0]const u8) callconv(.c) noreturn;

fn create(capacity: i32) callconv(.c) *Buffer.Extern {
    const buffer = Buffer.create(.default(), @intCast(@max(capacity, 4))) catch janet.oom();
    return .wrap(buffer);
}

fn init(buffer_ext: *Buffer.Extern, capacity: i32) callconv(.c) *Buffer.Extern {
    const buffer: *Buffer = @ptrCast(buffer_ext);
    buffer.* = Buffer.init(.default(), @intCast(@max(capacity, 4))) catch janet.oom();
    return buffer_ext;
}

fn pointer_unsafe(memory: ?*anyopaque, capacity: i32, count: i32) callconv(.c) *Buffer.Extern {
    if (count < 0) janet_panic("count < 0");
    if (capacity < count) janet_panic("capacity < count");

    const handle, const buffer, _ = janet.gc.create_deferred(.default(), Buffer.Extern, u8, 0) catch janet.oom();
    buffer.* = .{
        .gc = .disabled,
        .count = count,
        .capacity = capacity,
        .data = if (memory) |ptr| @ptrCast(ptr) else null,
    };
    buffer.gc.flags_typed(Buffer.Flags).no_realloc = true;
    handle.finish(.buffer);
    return buffer;
}

fn deinit(buffer_ext: *Buffer.Extern) callconv(.c) void {
    if (cannot_realloc(buffer_ext)) return;
    const data = buffer_ext.data orelse return;
    janet.gc.free(.default(), @as([*]align(janet.gc.alignment_size) u8, @alignCast(data)));
    buffer_ext.data = null;
}

fn ensure(buffer_ext: *Buffer.Extern, capacity: i32, growth: i32) callconv(.c) void {
    if (capacity <= buffer_ext.capacity) return;
    check_realloc(buffer_ext);
    buffer_ext.cast().reserve_growth(.default(), @intCast(capacity), @intCast(growth)) catch janet.oom();
}

fn set_count(buffer_ext: *Buffer.Extern, count: i32) callconv(.c) void {
    if (count < 0) return;
    if (count > buffer_ext.count) check_realloc_if_needed(buffer_ext, count);
    buffer_ext.cast().set_count(.default(), @intCast(count)) catch janet.oom();
}

fn extra(buffer_ext: *Buffer.Extern, n: i32) callconv(.c) void {
    const new_size = @as(i64, n) + buffer_ext.count;
    if (new_size > Buffer.count_max) janet_panic("buffer overflow");
    if (new_size <= buffer_ext.capacity) return;
    check_realloc(buffer_ext);
    const new_capacity: u32 = if (new_size > Buffer.count_max / 2)
        Buffer.count_max
    else
        @intCast(new_size * 2);
    buffer_ext.cast().reserve_total_precise(.default(), new_capacity) catch janet.oom();
}

fn push_bytes(buffer_ext: *Buffer.Extern, string: ?[*]const u8, length: i32) callconv(.c) void {
    if (length == 0) return;
    extra(buffer_ext, length);
    const buffer = buffer_ext.cast();
    const bytes = x.c_slice(string, length);
    buffer.bytes.append_slice(bytes);
}

fn push_string(buffer_ext: *Buffer.Extern, string: [*]const u8) callconv(.c) void {
    const pointer: janet.value.String.Extern.Pointer = .{
        .ptr = @ptrCast(@alignCast(@constCast(string))),
    };
    push_bytes(buffer_ext, string, @intCast(pointer.cast_head().size));
}

fn push_cstring(buffer_ext: *Buffer.Extern, cstring: [*:0]const u8) callconv(.c) void {
    const bytes = std.mem.span(cstring);
    push_bytes(buffer_ext, bytes.ptr, @intCast(bytes.len));
}

fn push_u8(buffer_ext: *Buffer.Extern, byte: u8) callconv(.c) void {
    extra(buffer_ext, 1);
    buffer_ext.cast().bytes.append(byte);
}

fn push_u16(buffer_ext: *Buffer.Extern, value: u16) callconv(.c) void {
    push_int(buffer_ext, u16, value);
}

fn push_u32(buffer_ext: *Buffer.Extern, value: u32) callconv(.c) void {
    push_int(buffer_ext, u32, value);
}

fn push_u64(buffer_ext: *Buffer.Extern, value: u64) callconv(.c) void {
    push_int(buffer_ext, u64, value);
}

fn push_int(buffer_ext: *Buffer.Extern, comptime T: type, value: T) void {
    extra(buffer_ext, @sizeOf(T));
    const buffer = buffer_ext.cast();
    std.mem.writeInt(T, buffer.bytes.add_many_as_array(@sizeOf(T)), value, .little);
}

fn trim(buffer_ext: *Buffer.Extern) callconv(.c) void {
    check_realloc(buffer_ext);
    const new_capacity: u32 = @intCast(@max(buffer_ext.count, 4));
    if (new_capacity >= buffer_ext.capacity) return;
    buffer_ext.cast().reserve_total_precise(.default(), new_capacity) catch janet.oom();
}

fn cannot_realloc(buffer: *Buffer.Extern) bool {
    return buffer.gc.flags_typed(Buffer.Flags).no_realloc;
}

fn check_realloc(buffer: *Buffer.Extern) void {
    if (cannot_realloc(buffer)) janet_panic("buffer cannot reallocate foreign memory");
}

fn check_realloc_if_needed(buffer: *Buffer.Extern, capacity: i32) void {
    if (capacity > buffer.capacity) check_realloc(buffer);
}
