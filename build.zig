const std = @import("std");
const Build = std.Build;

pub fn build(b: *Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const step_check = b.step("check", "Compile artifacts for ZLS");
    const step_test = b.step("test", "Run unit tests");

    const mod_x = b.createModule(.{
        .root_source_file = b.path("src/x.zig"),
    });
    mod_x.addImport("x", mod_x);

    const test_x = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/x.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_x.root_module.addImport("x", test_x.root_module);
    const run_test_x = b.addRunArtifact(test_x);
    step_test.dependOn(&run_test_x.step);

    const path_core_image = build_core_image(b, .{ .mod_x = mod_x });

    const exe = b.addExecutable(.{
        .name = "janet",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    exe.root_module.addImport("janet", create_janet_module(b, .{
        .name = "janet",
        .module_x = mod_x,
        .path_core_image = path_core_image,
    }));
    add_cjanet(b, exe.root_module, .{
        .kind = .executable,
    });
    b.installArtifact(exe);

    const exe_test = b.addTest(.{
        .root_module = create_janet_module(b, .{
            .module_x = mod_x,
            .target = target,
            .optimize = optimize,
            .path_core_image = path_core_image,
        }),
        .test_runner = .{
            .path = b.path("src/main_test.zig"),
            .mode = .simple,
        },
    });
    exe_test.root_module.addImport("janet", exe_test.root_module);
    exe_test.root_module.addImport("x", mod_x);
    add_cjanet(b, exe_test.root_module, .{
        .kind = .library,
    });
    const run_test = b.addRunArtifact(exe_test);
    run_test.addArtifactArg(exe);
    run_test.addDirectoryArg(b.path("test"));

    step_test.dependOn(&run_test.step);

    b.installFile("janet.1", "share/man/man1/janet.1");

    step_check.dependOn(&exe.step);
}

fn create_janet_module(b: *std.Build, options: struct {
    name: ?[]const u8 = null,
    module_x: *std.Build.Module,
    target: ?std.Build.ResolvedTarget = null,
    optimize: ?std.builtin.OptimizeMode = null,
    path_core_image: ?std.Build.LazyPath = null,
}) *std.Build.Module {
    const mod = b.createModule(.{
        .root_source_file = b.path("src/janet.zig"),
        .target = options.target,
        .optimize = options.optimize,
    });
    if (options.name) |name| {
        b.modules.putNoClobber(b.allocator, name, mod) catch @panic("oom");
    }
    mod.addImport("x", options.module_x);
    mod.addImport("janet", mod);
    // Those include paths are for @cImport
    mod.addIncludePath(b.path("src/conf"));
    mod.addIncludePath(b.path("src/include"));
    if (options.path_core_image) |core_image| {
        mod.addAnonymousImport("core.jimage", .{ .root_source_file = core_image });
    }
    return mod;
}

fn add_cjanet(b: *std.Build, mod: *std.Build.Module, options: struct {
    kind: enum {
        bootstrap,
        executable,
        library,
    },
}) void {
    const c_flags: []const []const u8 = &.{"-std=c99"};
    const core_src: []const []const u8 = &.{
        "src/core/abstract.c",
        "src/core/array.c",
        "src/core/asm.c",
        "src/core/buffer.c",
        "src/core/bytecode.c",
        "src/core/capi.c",
        "src/core/cfuns.c",
        "src/core/compile.c",
        "src/core/corelib.c",
        "src/core/debug.c",
        "src/core/emit.c",
        "src/core/ev.c",
        "src/core/ffi.c",
        "src/core/fiber.c",
        "src/core/filewatch.c",
        "src/core/gc.c",
        "src/core/inttypes.c",
        "src/core/io.c",
        "src/core/marsh.c",
        "src/core/math.c",
        "src/core/net.c",
        "src/core/os.c",
        "src/core/parse.c",
        "src/core/peg.c",
        "src/core/pp.c",
        "src/core/run.c",
        "src/core/specials.c",
        "src/core/state.c",
        "src/core/string.c",
        "src/core/strtod.c",
        "src/core/struct.c",
        "src/core/table.c",
        "src/core/tuple.c",
        "src/core/util.c",
        "src/core/value.c",
        "src/core/vector.c",
        "src/core/vm.c",
        "src/core/wrap.c",
    };

    mod.addCSourceFiles(.{
        .root = b.path(""),
        .files = switch (options.kind) {
            .bootstrap => core_src ++ .{
                "src/boot/array_test.c",
                "src/boot/buffer_test.c",
                "src/boot/number_test.c",
                "src/boot/system_test.c",
                "src/boot/table_test.c",
            },
            else => core_src,
        },
        .flags = switch (options.kind) {
            .bootstrap => c_flags ++ .{"-DJANET_BOOTSTRAP"},
            else => c_flags ++ .{"-fvisibility=hidden"},
        },
    });
    mod.addIncludePath(b.path("src/boot"));
    mod.addIncludePath(b.path("src/conf"));
    mod.addIncludePath(b.path("src/include"));
    if (options.kind == .executable) {
        mod.addCSourceFile(.{
            .file = b.path("src/mainclient/shell.c"),
            .flags = c_flags,
        });
    }
}

fn build_core_image(b: *std.Build, options: struct {
    mod_x: *std.Build.Module,
}) std.Build.LazyPath {
    const mod = create_janet_module(b, .{ .module_x = options.mod_x });
    const boot = b.addExecutable(.{
        .name = "janet-boot",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main_boot.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
            .link_libc = true,
        }),
    });
    boot.root_module.addImport("janet", mod);
    add_cjanet(b, boot.root_module, .{
        .kind = .bootstrap,
    });

    const run_boot = b.addRunArtifact(boot);
    run_boot.addDirectoryArg(b.path(""));

    const core_image = run_boot.captureStdOut(.{ .basename = "core.jimage" });

    return core_image;
}
