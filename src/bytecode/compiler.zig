const x = @import("x");
const janet = @import("janet");
const Register = janet.compile.Register;

c: C,
diagnostics: *Result.Diagnostics,

pub const Error = error{JanetCompileFail};

pub const Result = struct {
    def: *janet.value.FunctionDefinition,

    const Diagnostics = struct {
        @"error": []u8 = undefined,
        macrofiber: *janet.value.Fiber = undefined,
        mapping: C.SourceMapping = undefined,
        lints: ?*janet.Array = null,
    };
};

const C = extern struct {
    /// Pointer to current scope
    scope: *Scope,
    buffer: x.array_list.Thin(u32),
    mapbuffer: x.array_list.Thin(SourceMapping),
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
    lints: ?*janet.Array.Extern,
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
            function: bool,
            env: bool,
            top: bool,
            unused: bool,
            closure: bool,
            @"while": bool,
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
            type: janet.Value.TypeFlags,
            constant: bool,
            named: bool,
            mutable: bool,
            ref: bool,
            returned: bool,
            dep_note: bool,
            dep_warn: bool,
            dep_error: bool,
            spliced: bool,
        };
    };
};
