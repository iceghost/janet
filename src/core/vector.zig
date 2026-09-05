const janet = @import("janet");
const Compiler = janet.bytecode.Compiler;
const x = @import("x");

comptime {
    @export(&grow, .{ .name = "janet_v_grow" });
}

fn grow(vector: ?*anyopaque, increment: i32, item_size: i32) callconv(.c) *anyopaque {
    inline for (.{
        u32,
        janet.Value,
        Compiler.C.EnvRef,
        Compiler.C.Slot,
        Compiler.C.SlotHeadPair,
        Compiler.C.SymPair,
    }) |T| {
        if (item_size == @sizeOf(T)) return grow_t(
            T,
            .{ .base = @ptrCast(@alignCast(vector)) },
            increment,
        ).base.?;
    }
    @panic("unsupported vector item size");
}

fn grow_t(comptime T: type, list: x.array_list.Thin(T), increment: i32) x.array_list.Thin(T) {
    var mut = list;
    const rt: *janet.Runtime = .default();
    var arena = rt.arena_per_gc.promote(rt.gpa);
    defer rt.arena_per_gc = arena.state;
    mut.reserve(arena.allocator(), @intCast(increment)) catch janet.oom();
    return mut;
}
