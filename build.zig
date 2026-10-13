const std = @import("std");

const ShellBuildCtx = struct {
    b: *std.Build,
    exe: *std.Build.Step.Compile,
    mod: *std.Build.Module,
};

fn setup_tests(ctx: *ShellBuildCtx) void {
    const b: *std.Build = ctx.b;
    const exe: *std.Build.Step.Compile = ctx.exe;
    const mod: *std.Build.Module = ctx.mod;

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}

fn setup_build(b: *std.Build, ctx: *ShellBuildCtx) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const mod = b.addModule("shell", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });
    const exe = b.addExecutable(.{
        .name = "bs",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "shell", .module = mod },
            },
        }),
    });

    b.installArtifact(exe);

    const shell_run_step = b.step("run", "Run the shell");

    const run_cmd = b.addRunArtifact(exe);
    shell_run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();

    ctx.b = b;
    ctx.exe = exe;
    ctx.mod = mod;
}

pub fn build(b: *std.Build) void {
    var ctx: ShellBuildCtx = undefined;
    setup_build(b, &ctx);
    setup_tests(&ctx);
}
