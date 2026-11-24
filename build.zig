const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const mytui = b.addModule("mytui", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const example = b.addExecutable(.{
        .name = "counter",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/counter.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "mytui", .module = mytui }},
        }),
    });
    b.installArtifact(example);
    const run = b.addRunArtifact(example);
    run.stdio = .inherit;
    b.step("run", "Run the counter").dependOn(&run.step);

    const tests = b.addTest(.{ .root_module = mytui });
    mytui.addAnonymousImport("grapheme_cases", .{ .root_source_file = b.path("test/data/GraphemeBreakTest.txt") });
    mytui.addAnonymousImport("word_cases", .{ .root_source_file = b.path("test/data/WordBreakTest.txt") });
    mytui.addAnonymousImport("line_cases", .{ .root_source_file = b.path("test/data/LineBreakTest.txt") });
    b.step("test", "Verify core transactions and storage invariants").dependOn(&b.addRunArtifact(tests).step);
    const pty_app = b.addExecutable(.{
        .name = "pty-app",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/app.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "mytui", .module = mytui }},
        }),
    });
    const terminal_step = b.step("test-terminal", "Verify fragmented Unicode output with Ghostty");
    if (b.option(bool, "terminal-tests", "Enable the pinned Ghostty test dependency") orelse false) {
        if (b.lazyDependency("ghostty", .{
            .target = target,
            .optimize = optimize,
            .@"emit-lib-vt" = true,
            .@"emit-themes" = false,
            .@"app-runtime" = .none,
            .simd = false,
            .@"vt-features" = "-all,+kitty-graphics",
        })) |ghostty| {
            const terminal_tests = b.addTest(.{ .root_module = b.createModule(.{
                .root_source_file = b.path("test/terminal.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "mytui", .module = mytui },
                    .{ .name = "ghostty-vt", .module = ghostty.module("ghostty-vt") },
                },
            }) });
            terminal_step.dependOn(&b.addRunArtifact(terminal_tests).step);
            const terminal_check = b.addExecutable(.{ .name = "terminal-check", .root_module = terminal_tests.root_module });
            const lifecycle = b.addSystemCommand(&.{ "python3", "test/pty.py" });
            lifecycle.addArtifactArg(pty_app);
            lifecycle.addArg("--terminal");
            lifecycle.addArtifactArg(terminal_check);
            terminal_step.dependOn(&lifecycle.step);
        }
    } else {
        terminal_step.dependOn(&b.addFail("Use -Dterminal-tests=true to enable Ghostty verification").step);
    }
    const pty = b.addSystemCommand(&.{ "python3", "test/pty.py" });
    pty.addArtifactArg(pty_app);
    b.step("test-pty", "Verify terminal lifecycle in private PTYs").dependOn(&pty.step);
    const mixed = b.addSystemCommand(&.{ "python3", "test/pty.py" });
    mixed.addArtifactArg(pty_app);
    mixed.addArg("--mixed");
    b.step("test-stress", "Verify mixed-load fairness and bounded shutdown").dependOn(&mixed.step);
    const pty_benchmark = b.addSystemCommand(&.{ "python3", "test/pty.py" });
    pty_benchmark.addArtifactArg(pty_app);
    pty_benchmark.addArg("--bench");
    b.step("bench-pty", "Measure event latency and idle wakeups in private PTYs").dependOn(&pty_benchmark.step);

    const benchmark = b.addExecutable(.{
        .name = "render-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/render.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "mytui", .module = mytui }},
        }),
    });
    const run_benchmark = b.addRunArtifact(benchmark);
    run_benchmark.addPassthruArgs();
    b.step("bench", "Measure rendering and output work").dependOn(&run_benchmark.step);
}
