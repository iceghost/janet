const std = @import("std");
const mem = std.mem;

const janet = @import("janet");
const Register = janet.compile.Register;
const x = @import("x");

const Compiler = @This();

c: C,
scope_root: C.Scope,

pub const Error = mem.Allocator.Error || error{JanetCompileFail};

pub const Result = struct {
    def: *janet.value.FunctionDefinition,

    const Diagnostics = struct {
        @"error": []u8 = undefined,
        macrofiber: *janet.value.Fiber = undefined,
        mapping: C.SourceMapping = undefined,
        lints: ?*janet.Array = null,
    };
};

pub const C = extern struct {
    /// Pointer to current scope
    scope: ?*Scope,
    buffer: x.array_list.Thin(janet.bytecode.Quadruple) = .empty,
    mapbuffer: x.array_list.Thin(SourceMapping) = .empty,
    /// Hold the environment
    env: ?*janet.value.Table,
    /// Name of source to attach to generated functions
    source: ?[*:0]const u8,
    /// The result of compilation
    result: C.Result,
    /// Keep track of where we are in the source
    current_mapping: SourceMapping,
    /// Prevent unbounded recursion
    recursion_guard: i32,
    /// Collect linting result
    lints: ?*janet.Array,
    /// Cached version of (dyn *redef*)
    is_redef: i32,

    /// A lexical scope during compilation
    pub const Scope = extern struct {
        /// For debugging the compiler
        name: [*:0]const u8,
        /// Scopes are doubly linked list.
        parent: ?*Scope,
        /// Scopes are doubly linked list.
        child: ?*Scope,

        /// Constants for this funcdef
        consts: x.array_list.Thin(janet.Value),
        /// Map of symbols to slots. Use a simple linear scan for symbols
        syms: x.array_list.Thin(SymPair),
        /// FuncDefs
        defs: x.array_list.Thin(*janet.value.FunctionDefinition),
        /// Register allocator
        ra: Register.Allocator,
        /// Upvalue allocator
        ua: Register.Allocator,
        /// Referenced closure environments
        ///
        /// The values at each index correspond to which index to get the
        /// environment from in the parent. The environment that corresponds to the
        /// direct parent's stack will always have value 0
        envs: x.array_list.Thin(EnvRef),
        bytecode_start: i32,
        flags: Flags,

        pub const Flags = packed struct(i32) {
            function: bool = false,
            env: bool = false,
            top: bool = false,
            unused: bool = false,
            closure: bool = false,
            @"while": bool = false,
            reserved: u26 = 0,
        };

        pub fn find_outermost_function(self: *Scope) ?*Scope {
            var it: ?*Scope = self;
            while (it) |s| : (it = s.parent) {
                if (s.flags.function) return s;
            } else {
                return null;
            }
        }
    };

    /// Source mapping for a bytecode instruction.
    pub const SourceMapping = extern struct {
        line: i32,
        column: i32,
    };

    pub const Result = extern struct {
        funcdef: ?*janet.value.FunctionDefinition,
        @"error": ?[*:0]const u8,
        macrofiber: ?*janet.c.JanetFiber,
        error_mapping: SourceMapping,
        status: Status,

        pub const Status = enum(i32) {
            ok,
            @"error",
        };
    };

    pub const Fopts = extern struct {
        compiler: *C,
        hint: Slot,
        /// Accepted primitive types and form-compilation options.
        flags: Flags,

        pub const Flags = packed struct(u32) {
            type: x.bit_set.Enum(janet.Value.Tag) = .empty,
            tail: bool = false,
            hint: bool = false,
            drop: bool = false,
            accept_splice: bool = false,
            reserved: u12 = 0,
        };

        pub fn init(compiler: *Compiler) Fopts {
            return .{
                .compiler = &compiler.c,
                .flags = .{},
                .hint = .init_constant(.nil),
            };
        }
    };

    pub const Special = extern struct {
        name: [*:0]const u8,
        compile: *const fn (Fopts, i32, [*]const janet.Value) callconv(.c) Slot,
    };

    /// A symbol and slot pair.
    pub const SymPair = extern struct {
        slot: Slot,
        sym: ?[*:0]const u8,
        sym2: ?[*:0]const u8,
        keep: i32,
        /// Whether this value has been used.
        referenced: i32,
        birth_pc: u32,
        death_pc: u32,
    };

    pub const EnvRef = extern struct {
        envindex: i32,
        scope: *Scope,
    };

    /// A stack slot.
    pub const Slot = extern struct {
        /// The slot's constant value, when `flags.constant` is set.
        constant: janet.Value,
        index: i32,
        /// Zero for a local slot, or a positive number for an upvalue.
        envindex: i32,
        flags: Flags,

        pub const Flags = packed struct(u32) {
            type: x.bit_set.Enum(janet.Value.Tag) = .empty,
            constant: bool = false,
            named: bool = false,
            mutable: bool = false,
            ref: bool = false,
            returned: bool = false,
            dep_note: bool = false,
            dep_warn: bool = false,
            dep_error: bool = false,
            spliced: bool = false,
            reserved: u7 = 0,
        };

        pub fn init_constant(v: janet.Value) Slot {
            var slot: Slot = .{
                .flags = .{
                    .constant = true,
                },
                .index = -1,
                .constant = v,
                .envindex = -1,
            };

            slot.flags.type = slot.flags.type.set(v.repr.unwrap_tag());

            return slot;
        }

        pub fn init_far(c: *Compiler) Error!Slot {
            return .{
                .flags = .{
                    .type = .full,
                },
                .index = try c.allocfar(),
                .constant = .nil,
                .envindex = -1,
            };
        }
    };
};

pub fn init(
    compiler: *Compiler,
    env: *janet.value.Table,
    source: ?[*:0]const u8,
    lints: ?*janet.Array,
) void {
    compiler.scope_root = undefined;
    compiler.c = .{
        .scope = null,
        .buffer = .empty,
        .mapbuffer = .empty,
        .env = env,
        .source = source,
        .result = .{
            .funcdef = null,
            .@"error" = null,
            .macrofiber = null,
            .error_mapping = .{ .line = -1, .column = -1 },
            .status = .ok,
        },
        .current_mapping = .{ .line = -1, .column = -1 },
        .recursion_guard = 1024,
        .lints = lints,
        .is_redef = if (env.get_keyword("redef")) |v| @intFromBool(v.repr.truthy()) else 0,
    };
}

pub fn deinit(compiler: *Compiler, rt: *janet.Runtime) void {
    // TODO: use a compiler scratch allocator
    _ = rt;

    compiler.c.env = null;
}

extern fn janet_sfree(memory: *anyopaque) callconv(.c) void;
extern fn janet_cstring(cstring: [*:0]const u8) callconv(.c) [*:0]const u8;
extern fn janet_tuple_n(values: ?[*]const janet.Value, count: i32) callconv(.c) [*]const janet.Value;
extern fn janet_def_addflags(def: *janet.value.FunctionDefinition) callconv(.c) void;
extern fn janetc_scope(scope: *C.Scope, compiler: *C, flags: C.Scope.Flags, name: [*:0]const u8) callconv(.c) void;
extern fn janetc_popscope(compiler: *C) callconv(.c) void;
extern fn janetc_pop_funcdef(compiler: *C) callconv(.c) *janet.value.FunctionDefinition;
extern fn janetc_array(options: C.Fopts, source: janet.Value) callconv(.c) C.Slot;
extern fn janetc_tuple(options: C.Fopts, source: janet.Value) callconv(.c) C.Slot;
extern fn janetc_tablector(options: C.Fopts, source: janet.Value, opcode: i32) callconv(.c) C.Slot;
extern fn janetc_bufferctor(options: C.Fopts, source: janet.Value) callconv(.c) C.Slot;
extern fn janetc_call(options: C.Fopts, slots: ?[*]C.Slot, function: C.Slot, form: [*]const janet.Value) callconv(.c) C.Slot;
extern fn janetc_toslots(compiler: *C, values: [*]const janet.Value, len: i32) callconv(.c) ?[*]C.Slot;
extern fn janetc_freeslot(compiler: *C, slot: C.Slot) callconv(.c) void;
extern fn janetc_resolve(compiler: *C, symbol: [*:0]const u8) callconv(.c) C.Slot;
extern fn janetc_return(compiler: *C, slot: C.Slot) callconv(.c) C.Slot;
extern fn janetc_copy(compiler: *C, destination: C.Slot, source: C.Slot) callconv(.c) void;
extern fn janetc_cerror(compiler: *C, message: [*:0]const u8) callconv(.c) void;
extern fn janetc_macroexpand1(compiler: *C, source: janet.Value, out: *janet.Value, special: *?*const C.Special) callconv(.c) c_int;

pub fn compile(compiler: *Compiler, rt: *janet.Runtime, source: janet.Value) !C.Result {
    janetc_scope(&compiler.scope_root, &compiler.c, .{ .function = true, .top = true }, "root");

    const flags: C.Fopts.Flags = .{
        .type = .full,
        .tail = true,
    };
    _ = try compiler.compile_value(rt, .init_constant(.nil), flags, source);

    if (compiler.c.result.status == .ok) {
        const def = janetc_pop_funcdef(&compiler.c);
        def.name = janet_cstring("thunk");
        janet_def_addflags(def);
        compiler.c.result.funcdef = def;
    } else {
        compiler.c.result.error_mapping = compiler.c.current_mapping;
        janetc_popscope(&compiler.c);
    }

    return compiler.c.result;
}

pub fn compile_value(
    compiler: *Compiler,
    rt: *janet.Runtime,
    hint: C.Slot,
    flags: C.Fopts.Flags,
    v: janet.Value,
) !C.Slot {
    const last_mapping = compiler.c.current_mapping;
    compiler.c.recursion_guard -= 1;

    if (compiler.c.result.status == .@"error") return .init_constant(.nil);
    if (compiler.c.recursion_guard <= 0) {
        janetc_cerror(&compiler.c, "recursed too deeply");
        return .init_constant(.nil);
    }

    var source = v;
    var special: ?*const C.Special = null;
    var macro_expansions: usize = 200;
    while (macro_expansions > 0 and
        compiler.c.result.status != .@"error" and
        janetc_macroexpand1(&compiler.c, source, &source, &special) != 0) : (macro_expansions -= 1)
    {}
    if (macro_expansions == 0) {
        janetc_cerror(&compiler.c, "recursed too deeply in macro expansion");
        return .init_constant(.nil);
    }

    const options: C.Fopts = .{
        .compiler = &compiler.c,
        .hint = hint,
        .flags = flags,
    };
    var result: C.Slot = undefined;
    if (special) |s| {
        const tuple = source.unwrap().tuple;
        const values = tuple.slice();
        result = s.compile(options, @intCast(values.len - 1), values.ptr + 1);
    } else switch (source.repr.unwrap_tag()) {
        .tuple => {
            const tuple = source.unwrap().tuple;
            const values = tuple.slice();
            if (values.len == 0) {
                result = .init_constant(.tuple(try .from_slice(rt, &.{})));
            } else if ((@as(u32, @bitCast(tuple.gc.flags)) & 0x10000) != 0) {
                result = janetc_tuple(options, source);
            } else {
                var subflags: C.Fopts.Flags = .{};
                const function = try compiler.compile_value(rt, .init_constant(.nil), subflags, values[0]);
                subflags.type = subflags.type.set(.function).set(.cfunction);
                result = janetc_call(
                    options,
                    janetc_toslots(&compiler.c, values.ptr + 1, @intCast(values.len - 1)),
                    function,
                    values.ptr,
                );
                janetc_freeslot(&compiler.c, function);
            }
            result.flags.spliced = false;
        },
        .symbol => result = janetc_resolve(&compiler.c, source.unwrap().string.slice().ptr),
        .array => result = janetc_array(options, source),
        .@"struct" => result = janetc_tablector(options, source, @intFromEnum(janet.bytecode.OpCode.make_struct)),
        .table => result = janetc_tablector(options, source, @intFromEnum(janet.bytecode.OpCode.make_table)),
        .buffer => result = janetc_bufferctor(options, source),
        else => result = .init_constant(source),
    }

    if (compiler.c.result.status == .@"error") return .init_constant(.nil);
    if (flags.tail) result = janetc_return(&compiler.c, result);
    if (flags.hint) {
        janetc_copy(&compiler.c, hint, result);
        result = hint;
    }
    compiler.c.current_mapping = last_mapping;
    compiler.c.recursion_guard += 1;
    return result;
}

fn @"error"(compiler: *Compiler, str: *janet.value.String) Error {
    // don't override first error
    if (compiler.c.result.status == .@"error") {
        return error.JanetCompileFail;
    }
    compiler.c.result.status = .@"error";
    compiler.c.result.@"error" = str.slice().ptr;
    return error.JanetCompileFail;
}

fn allocfar(compiler: *Compiler) Error!Register {
    const reg = try compiler.c.scope.?.ra.alloc(compiler.gpa);
    if (@intFromEnum(reg) > 0xFFFF) {
        return compiler.@"error"("ran out of internal registers");
    }
    return reg;
}
