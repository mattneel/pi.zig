const build_zon = @import("build.zig.zon");
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const test_filters = b.option(
        []const []const u8,
        "test-filter",
        "Run tests whose names contain any of these substrings",
    ) orelse &.{};
    const live = b.option(bool, "live", "Run live provider smoke tests") orelse false;

    const ai_dep = b.dependency("ai", .{
        .target = target,
        .optimize = optimize,
        .@"default-openrouter" = false,
    });
    const zigzag_dep = b.dependency("zigzag", .{
        .target = target,
        .optimize = optimize,
    });
    const quickjs_dep = b.dependency("quickjs-ng", .{
        .target = target,
        .optimize = optimize,
    });
    const deps: Dependencies = .{
        .ai = ai_dep.module("ai"),
        .provider = ai_dep.module("provider"),
        .provider_utils = ai_dep.module("provider_utils"),
        .anthropic = ai_dep.module("anthropic"),
        .openai = ai_dep.module("openai"),
        .openai_compatible = ai_dep.module("openai_compatible"),
        .openrouter = ai_dep.module("openrouter"),
        .google = ai_dep.module("google"),
        .xai = ai_dep.module("xai"),
        .mcp = ai_dep.module("mcp"),
        .zigzag = zigzag_dep.module("zigzag"),
        .quickjs = quickjs_dep.module("quickjs"),
    };
    const quickjs_lib = quickjs_dep.artifact("quickjs-ng");

    const pi = b.addModule("pi", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    addDependencyImports(pi, deps);

    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", build_zon.version);
    build_options.addOption(bool, "live", live);

    const crash_helper_module = b.createModule(.{
        .root_source_file = b.path("src/session_crash_helper.zig"),
        .target = target,
        .optimize = optimize,
    });
    addDependencyImports(crash_helper_module, deps);
    const crash_helper = b.addExecutable(.{
        .name = "session-crash-helper",
        .root_module = crash_helper_module,
        .use_llvm = true,
    });
    build_options.addOptionPath("session_crash_helper_path", crash_helper.getEmittedBin());
    pi.addOptions("build_options", build_options);

    const exe_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_module.addImport("pi", pi);
    addDependencyImports(exe_module, deps);
    exe_module.linkLibrary(quickjs_lib);

    const exe = b.addExecutable(.{
        .name = "omp-zig",
        .root_module = exe_module,
        .use_llvm = true,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run omp-zig");
    run_step.dependOn(&run_cmd.step);

    const pi_tests = b.addTest(.{
        .name = "pi-tests",
        .root_module = pi,
        .filters = test_filters,
        .use_llvm = true,
    });
    pi_tests.root_module.linkLibrary(quickjs_lib);
    const run_pi_tests = b.addRunArtifact(pi_tests);

    const exe_tests = b.addTest(.{
        .name = "omp-zig-tests",
        .root_module = exe_module,
        .filters = test_filters,
        .use_llvm = true,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run module and executable tests");
    test_step.dependOn(&run_pi_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}

const Dependencies = struct {
    ai: *std.Build.Module,
    provider: *std.Build.Module,
    provider_utils: *std.Build.Module,
    anthropic: *std.Build.Module,
    openai: *std.Build.Module,
    openai_compatible: *std.Build.Module,
    openrouter: *std.Build.Module,
    google: *std.Build.Module,
    xai: *std.Build.Module,
    mcp: *std.Build.Module,
    zigzag: *std.Build.Module,
    quickjs: *std.Build.Module,
};

fn addDependencyImports(module: *std.Build.Module, deps: Dependencies) void {
    module.addImport("ai", deps.ai);
    module.addImport("provider", deps.provider);
    module.addImport("provider_utils", deps.provider_utils);
    module.addImport("anthropic", deps.anthropic);
    module.addImport("openai", deps.openai);
    module.addImport("openai_compatible", deps.openai_compatible);
    module.addImport("openrouter", deps.openrouter);
    module.addImport("google", deps.google);
    module.addImport("xai", deps.xai);
    module.addImport("mcp", deps.mcp);
    module.addImport("zigzag", deps.zigzag);
    module.addImport("quickjs", deps.quickjs);
}
