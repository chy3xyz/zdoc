const std = @import("std");
const Io = std.Io;
const builtin = @import("builtin");
const tracy = @import("tracy");
const fatal = @import("../fatal.zig");
const root = @import("../root.zig");
const worker = @import("../worker.zig");
const Allocator = std.mem.Allocator;
const BuildAsset = root.BuildAsset;

const Kind = enum { site, blog, release };

pub fn siteCommand(io: Io, gpa: Allocator, args: []const []const u8) bool {
    return run(io, gpa, args, .site);
}

pub fn blogCommand(io: Io, gpa: Allocator, args: []const []const u8) bool {
    return run(io, gpa, args, .blog);
}

pub fn release(io: Io, gpa: Allocator, args: []const []const u8) bool {
    return run(io, gpa, args, .release);
}

fn run(io: Io, gpa: Allocator, args: []const []const u8, kind: Kind) bool {
    const cmd = Command.parse(gpa, args) catch fatal.oom();
    // Output stays next to where the command was typed. Entering the content
    // directory afterwards must not move `public/` inside that directory.
    const invoked_from = std.process.currentPathAlloc(io, gpa) catch fatal.oom();
    const output_dir_path = absoluteOutput(gpa, invoked_from, cmd.output_dir_path);
    enterContentDir(io, kind, cmd.dir);
    const cfg, const base_dir_path = root.Config.load(io, gpa, .auto);

    worker.start(io);
    defer if (builtin.mode == .debug) worker.stopWaitAndDeinit(io);

    const build = root.run(io, gpa, &cfg, .{
        .base_dir_path = base_dir_path,
        .build_assets = &cmd.build_assets,
        .drafts = cmd.drafts,
        .mode = .{
            .disk = .{
                .check_empty_output = !cmd.force,
                .output_dir_path = output_dir_path,
            },
        },
    }) catch fatal.oom();

    defer if (builtin.mode == .debug) build.deinit(io, gpa);

    if (tracy.enable) {
        tracy.frameMarkNamed("waiting for tracy");
        var progress_tracy = root.progress.start("Tracy", 0);
        std.Thread.sleep(100 * std.time.ns_per_ms);
        progress_tracy.end();
    }

    if (build.any_prerendering_error or
        build.any_rendering_error.load(.acquire))
    {
        return true;
    }

    return false;
}

pub const Command = struct {
    // search: root.Config.Search,
    /// Content root, when the user passed one. Null means the kind's default.
    dir: ?[]const u8,
    output_dir_path: ?[]const u8,
    build_assets: std.StringArrayHashMapUnmanaged(BuildAsset),
    drafts: bool,
    force: bool,

    pub fn deinit(co: *const Command, gpa: Allocator) void {
        var ba = co.build_assets;
        ba.deinit(gpa);
    }

    pub fn parse(gpa: Allocator, args: []const []const u8) !Command {
        // var config_path: ?[]const u8 = null;
        var dir: ?[]const u8 = null;
        var output_dir_path: ?[]const u8 = null;
        var build_assets: std.StringArrayHashMapUnmanaged(BuildAsset) = .empty;
        var drafts = false;
        var force = false;

        const eql = std.mem.eql;
        const startsWith = std.mem.startsWith;
        var idx: usize = 0;
        while (idx < args.len) : (idx += 1) {
            const arg = args[idx];
            if (eql(u8, arg, "-h") or eql(u8, arg, "--help")) {
                fatal.msg(help_message, .{});
            } else if (eql(u8, arg, "-f") or eql(u8, arg, "--force")) {
                force = true;
            } else if (eql(u8, arg, "-o") or eql(u8, arg, "--output")) {
                idx += 1;
                if (idx >= args.len) fatal.msg(
                    "error: missing argument to '{s}'",
                    .{arg},
                );
                output_dir_path = args[idx];
            } else if (startsWith(u8, arg, "--output=")) {
                output_dir_path = arg["--output=".len..];
                // } else if (eql(u8, arg, "-c") or eql(u8, arg, "--config")) {
                //     idx += 1;
                //     if (idx >= args.len) fatal.msg(
                //         "error: missing argument to '{s}'",
                //         .{arg},
                //     );
                //     config_path = args[idx];
                // } else if (startsWith(u8, arg, "--config=")) {
                //     config_path = arg["--config=".len..];
            } else if (startsWith(u8, arg, "--build-asset=")) {
                const name = arg["--build-asset=".len..];

                idx += 1;
                if (idx >= args.len) fatal.msg(
                    "error: missing build asset sub-argument for '{s}'",
                    .{name},
                );

                const input_path = args[idx];

                idx += 1;
                var install_path: ?[]const u8 = null;
                var install_always = false;
                if (idx < args.len) {
                    const next = args[idx];
                    if (startsWith(u8, next, "--install=")) {
                        install_path = next["--install=".len..];
                    } else if (startsWith(u8, next, "--install-always=")) {
                        install_always = true;
                        install_path = next["--install-always=".len..];
                    } else {
                        idx -= 1;
                    }
                }

                const gop = try build_assets.getOrPut(gpa, name);
                if (gop.found_existing) fatal.msg(
                    "error: duplicate build asset name '{s}'",
                    .{name},
                );

                gop.value_ptr.* = .{
                    .input_path = input_path,
                    .install_path = install_path,
                    .install_always = install_always,
                    .rc = .{ .raw = @intFromBool(install_always) },
                };
            } else if (eql(u8, arg, "--drafts")) {
                drafts = true;
            } else if (!startsWith(u8, arg, "-") and dir == null) {
                dir = arg;
            } else {
                fatal.msg("error: unexpected cli argument '{s}'\n", .{arg});
            }
        }

        return .{
            // .search = if (config_path) |p| .{ .path = p } else .auto,
            .dir = dir,
            .output_dir_path = output_dir_path,
            .build_assets = build_assets,
            .drafts = drafts,
            .force = force,
        };
    }
};

/// `site/` or `blog/` when that directory holds a config, otherwise the
/// directory the command was typed in. An explicit path always wins.
fn enterContentDir(io: Io, kind: Kind, explicit: ?[]const u8) void {
    const dir = explicit orelse switch (kind) {
        .site => if (ziggyIn(io, "site")) "site" else return,
        .blog => if (ziggyIn(io, "blog")) "blog" else return,
        .release => return,
    };
    if (std.mem.eql(u8, dir, ".")) return;
    std.Io.Threaded.chdir(dir) catch |err| fatal.dir(dir, err);
}

fn ziggyIn(io: Io, dir_name: []const u8) bool {
    var cwd = Io.Dir.cwd();
    var dir = cwd.openDir(io, dir_name, .{}) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return false,
        else => fatal.dir(dir_name, err),
    };
    defer dir.close(io);

    var file = dir.openFile(io, "zine.ziggy", .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => fatal.file("zine.ziggy", err),
    };
    file.close(io);
    return true;
}

fn absoluteOutput(gpa: Allocator, cwd: []const u8, output: ?[]const u8) []const u8 {
    const rel = output orelse "public";
    if (std.fs.path.isAbsolute(rel)) return rel;
    return std.fs.path.resolve(gpa, &.{ cwd, rel }) catch fatal.oom();
}

const help_message =
    \\Usage: zdoc site [dir] [OPTIONS]
    \\       zdoc blog [dir] [OPTIONS]
    \\
    \\Build a site from SuperMD pages (.smd) and SuperHTML templates
    \\(.shtml). `zdoc site` is the official site. `zdoc blog` is the
    \\dated posts and their feed. Both read `zine.ziggy`.
    \\
    \\[dir] defaults to 'site/' or 'blog/' when that directory contains
    \\`zine.ziggy`, otherwise the current directory.
    \\
    \\Command specific options:
    \\  --output, -o DIR   Directory where to output the website
    \\                     (defaults to 'public/')
    \\  --force, -f        Ignore other files in the output directory
    \\                     (otherwise a non-empty dir is an error)
    // \\  --config, -c FILE  Use a custom config file instead of searching
    // \\                     recursively upwards for a 'zine.ziggy' file
    \\  --help, -h         Show this help menu
    \\
    \\
;
