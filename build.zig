const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const dvui = b.dependency("dvui", .{
        .target = target,
        .optimize = optimize,
        .backend = .sdl3,
    });

    const sdl = b.dependency("sdl", .{
        .target = target,
        .optimize = optimize,
    });

    // A small named-pipe singleton, following fizzy's ownership model.
    const app = b.createModule(.{
        .root_source_file = b.path("src/app.zig"),
        .target = target,
        .optimize = optimize,
    });
    const app_assets = b.createModule(.{
        .root_source_file = b.path("assets.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "steam-controller-battery",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // This module provides SDL's C API as translated Zig declarations
    // and links the SDL3 library built by the dependency.
    exe.root_module.addImport("sdl3", sdl.module("sdl3"));

    b.installArtifact(exe);
    addWindowsTrayApp(b, target, optimize, sdl, dvui, app, app_assets);

    addSdlTestController(b, target, optimize, sdl);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run.addArgs(args);
    }

    const run_step = b.step("run", "Read connected gamepad battery levels");
    run_step.dependOn(&run.step);
}

fn addWindowsTrayApp(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    sdl: *std.Build.Dependency,
    dvui: *std.Build.Dependency,
    app: *std.Build.Module,
    app_assets: *std.Build.Module,
) void {
    if (target.result.os.tag != .windows) return;

    const tray = b.addExecutable(.{
        .name = "steam-controller-battery-tray",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tray_main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    tray.root_module.addImport("sdl3", sdl.module("sdl3"));
    tray.root_module.addImport("dvui", dvui.module("dvui_sdl3"));
    tray.root_module.addImport("sdl-backend", dvui.module("sdl3"));
    tray.root_module.addImport("app", app);
    tray.root_module.addImport("app_assets", app_assets);
    tray.subsystem = .Windows;
    tray.linkSystemLibrary("user32");
    tray.linkSystemLibrary("gdi32");
    tray.linkSystemLibrary("shell32");

    b.installArtifact(tray);
}

fn addSdlTestController(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    sdl: *std.Build.Dependency,
) void {
    const upstream_root = findUpstreamSdlRoot(b) catch @panic("failed to locate upstream SDL source in .zig-global-cache");

    const sdl_lib = sdl.artifact("SDL3");
    const test_support_sources = collectTestSupportSources(b, upstream_root) catch @panic("failed to locate SDL test support sources");
    const test_dir = std.fmt.allocPrint(b.allocator, "{s}/test", .{upstream_root}) catch @panic("oom");
    const src_test_dir = std.fmt.allocPrint(b.allocator, "{s}/src/test", .{upstream_root}) catch @panic("oom");
    const src_dir = std.fmt.allocPrint(b.allocator, "{s}/src", .{upstream_root}) catch @panic("oom");
    const khronos_dir = std.fmt.allocPrint(b.allocator, "{s}/src/video/khronos", .{upstream_root}) catch @panic("oom");
    const testcontroller_c = std.fmt.allocPrint(b.allocator, "{s}/test/testcontroller.c", .{upstream_root}) catch @panic("oom");
    const gamepadutils_c = std.fmt.allocPrint(b.allocator, "{s}/test/gamepadutils.c", .{upstream_root}) catch @panic("oom");
    const testutils_c = std.fmt.allocPrint(b.allocator, "{s}/test/testutils.c", .{upstream_root}) catch @panic("oom");

    const testcontroller = b.addExecutable(.{
        .name = "sdl-testcontroller",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    testcontroller.linkLibrary(sdl_lib);
    testcontroller.addIncludePath(.{ .cwd_relative = test_dir });
    testcontroller.addIncludePath(.{ .cwd_relative = src_test_dir });
    testcontroller.addIncludePath(.{ .cwd_relative = src_dir });
    testcontroller.addIncludePath(.{ .cwd_relative = khronos_dir });

    const testcontroller_sources = [_][]const u8{
        testcontroller_c,
        gamepadutils_c,
        testutils_c,
    };

    testcontroller.addCSourceFiles(.{
        .files = &testcontroller_sources,
        .flags = &.{"-std=c99"},
    });
    testcontroller.addCSourceFiles(.{
        .files = test_support_sources,
        .flags = &.{"-std=c99"},
    });

    const install_testcontroller = b.addInstallArtifact(testcontroller, .{});

    const step = b.step(
        "sdl-testcontroller",
        "Build the upstream SDL testcontroller app",
    );
    step.dependOn(&install_testcontroller.step);
}

fn findUpstreamSdlRoot(b: *std.Build) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    var base = try std.fs.cwd().openDir(".zig-global-cache/p", .{ .iterate = true });
    defer base.close();

    var walker = try base.walk(allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.endsWith(u8, entry.path, "/test/testcontroller.c")) {
            const root = std.fs.path.dirname(entry.path) orelse continue;
            const parent = std.fs.path.dirname(root) orelse continue;
            return std.fmt.allocPrint(b.allocator, ".zig-global-cache/p/{s}", .{parent});
        }
    }

    return error.UpstreamSdlSourceNotFound;
}

fn collectTestSupportSources(b: *std.Build, upstream_root: []const u8) ![]const []const u8 {
    var files = std.array_list.Managed([]const u8).init(b.allocator);
    errdefer files.deinit();

    const relative_dir = try std.fmt.allocPrint(b.allocator, "{s}/src/test", .{upstream_root});
    var dir = try std.fs.cwd().openDir(relative_dir, .{ .iterate = true });
    defer dir.close();

    var walker = try dir.walk(b.allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.startsWith(u8, std.fs.path.basename(entry.path), "SDL_test_")) continue;
        if (!std.mem.endsWith(u8, entry.path, ".c")) continue;

        const full_path = try std.fmt.allocPrint(b.allocator, "{s}/src/test/{s}", .{
            upstream_root,
            entry.path,
        });
        try files.append(full_path);
    }

    if (files.items.len == 0) {
        return error.SdlTestSupportSourcesNotFound;
    }

    std.mem.sort([]const u8, files.items, {}, struct {
        fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
            return std.mem.lessThan(u8, lhs, rhs);
        }
    }.lessThan);

    return files.toOwnedSlice();
}
