const std = @import("std");
const mem = std.mem;
const janet = @import("janet");
const Register = janet.compile.Register;
const x = @import("x");

const Compiler = @This();

gpa: mem.Allocator,
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
            type: std.bit_set.IntegerBitSet(16) = .empty,
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
            type: std.bit_set.IntegerBitSet(16) = .empty,
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

            // FIXME: bitset does not allow setting in packed struct
            var typeset: std.bit_set.IntegerBitSet(16) = .empty;
            typeset.set(@intFromEnum(v.repr.unwrap_tag()));
            slot.flags.type = typeset;

            return slot;
        }

        pub fn init_far(c: *Compiler) Slot {
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
extern fn janet_def_addflags(def: *janet.value.FunctionDefinition) callconv(.c) void;
extern fn janetc_scope(scope: *C.Scope, compiler: *C, flags: C.Scope.Flags, name: [*:0]const u8) callconv(.c) void;
extern fn janetc_popscope(compiler: *C) callconv(.c) void;
extern fn janetc_pop_funcdef(compiler: *C) callconv(.c) *janet.value.FunctionDefinition;
extern fn janetc_fopts_default(compiler: *C) callconv(.c) C.Fopts;
extern fn janetc_value(options: C.Fopts, source: janet.Value) callconv(.c) C.Slot;

pub fn compile(compiler: *Compiler, rt: *janet.Runtime, source: janet.Value) C.Result {
    _ = rt;

    janetc_scope(&compiler.scope_root, &compiler.c, .{ .function = true, .top = true }, "root");

    var options = janetc_fopts_default(&compiler.c);
    options.flags = .{
        .type = .initFull(),
        .tail = true,
    };
    _ = janetc_value(options, source);

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
