const std = @import("std");
const assert = std.debug.assert;

const janet = @import("janet");
const x = @import("x");

const String = janet.value.String;

comptime {
    @export(&init, .{ .name = "janet_symcache_init" });
    @export(&deinit, .{ .name = "janet_symcache_deinit" });
    @export(&symbol_deinit, .{ .name = "janet_symbol_deinit" });
    @export(&symbol, .{ .name = "janet_symbol" });
    @export(&csymbol, .{ .name = "janet_csymbol" });
    @export(&symbol_gen, .{ .name = "janet_symbol_gen" });
}

fn init() callconv(.c) void {
    const rt = janet.Runtime.default();
    rt.symbol_pool.init(rt.gpa) catch janet.oom();
}

fn deinit() callconv(.c) void {
    const rt = janet.Runtime.default();
    rt.symbol_pool.deinit(rt.gpa);
    rt.symbol_generator.reset();
}

fn symbol_deinit(sym: String.Extern.Pointer) callconv(.c) void {
    janet.Runtime.default().symbol_pool.remove(sym.cast_head());
}

fn symbol(bytes_ptr: ?[*]const u8, size: i32) callconv(.c) String.Extern.Pointer {
    const rt = janet.Runtime.default();
    const string = rt.symbol_pool.intern(rt, x.c_slice(bytes_ptr, size)) catch janet.oom();
    return .wrap(string);
}

fn csymbol(cstring: ?[*:0]const u8) callconv(.c) String.Extern.Pointer {
    const rt = janet.Runtime.default();
    const string = rt.symbol_pool.intern(rt, std.mem.span(cstring.?)) catch janet.oom();
    return .wrap(string);
}

fn symbol_gen() callconv(.c) String.Extern.Pointer {
    const rt = janet.Runtime.default();
    const string = rt.symbol_generator.next(rt) catch janet.oom();
    return .wrap(string);
}
