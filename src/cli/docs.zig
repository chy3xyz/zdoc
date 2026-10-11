//! `zdoc docs <dir>` — build a documentation site from a directory of Markdown
//! files, with no configuration file of any kind.
//!
//! This is the zero-config entry point. Everything it needs is derived from the
//! directory it is pointed at: the content directory is the argument, the
//! layouts and assets come from the built-in theme, and the site title comes
//! from the directory name. The config that normally lives in `zine.ziggy` is
//! built in memory instead.

const std = @import("std");
const Io = std.Io;
const builtin = @import("builtin");
const options = @import("options");
const tracy = @import("tracy");
const fatal = @import("../fatal.zig");
const root = @import("../root.zig");
const worker = @import("../worker.zig");
const docs = @import("../docs.zig");
const Allocator = std.mem.Allocator;
const BuildAsset = root.BuildAsset;

pub fn docsCommand(io: Io, gpa: Allocator, args: []const []const u8) bool {
    const cmd = DocsOptions.parse(io, gpa, args) catch fatal.oom();

    worker.start(io);
    defer if (builtin.mode == .debug) worker.stopWaitAndDeinit(io);

    const build = root.run(io, gpa, &cmd.config, .{
        .base_dir_path = cmd.base_dir_path,
        .build_assets = &cmd.build_assets,
        .drafts = cmd.drafts,
        .mode = .{
            .disk = .{
                .check_empty_output = !cmd.force,
                .output_dir_path = cmd.output_dir_path,
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

    if (build.any_prerendering_error or build.any_rendering_error.load(.acquire)) {
        return true;
    }

    const out = cmd.output_dir_path orelse "public";
    std.debug.print(
        \\
        \\Documentation site generated in '{s}/'.
        \\Point a web server at that directory to publish it.
        \\
        \\
    , .{out});

    return false;
}

pub const DocsOptions = struct {
    /// The synthesized config. Kept by value so the strings it points at live
    /// as long as the build does.
    config: root.Config,
    base_dir_path: []const u8,
    output_dir_path: ?[]const u8,
    build_assets: std.StringArrayHashMapUnmanaged(BuildAsset),
    drafts: bool,
    force: bool,

    pub fn deinit(co: *const DocsOptions, gpa: Allocator) void {
        var ba = co.build_assets;
        ba.deinit(gpa);
    }

    pub fn parse(io: Io, gpa: Allocator, args: []const []const u8) !DocsOptions {
        var content_dir_path: ?[]const u8 = null;
        var base_dir_path: ?[]const u8 = null;
        var title: ?[]const u8 = null;
        var output_dir_path: ?[]const u8 = null;
        const build_assets: std.StringArrayHashMapUnmanaged(BuildAsset) = .empty;
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
            } else if (eql(u8, arg, "--base")) {
                idx += 1;
                if (idx >= args.len) fatal.msg("error: missing argument to '{s}'", .{arg});
                base_dir_path = args[idx];
            } else if (startsWith(u8, arg, "--base=")) {
                base_dir_path = arg["--base=".len..];
            } else if (eql(u8, arg, "--title")) {
                idx += 1;
                if (idx >= args.len) fatal.msg("error: missing argument to '{s}'", .{arg});
                title = args[idx];
            } else if (startsWith(u8, arg, "--title=")) {
                title = arg["--title=".len..];
            } else if (eql(u8, arg, "--drafts")) {
                drafts = true;
            } else if (startsWith(u8, arg, "-")) {
                fatal.msg("error: unexpected cli argument '{s}'\n\n{s}", .{ arg, help_message });
            } else if (content_dir_path == null) {
                content_dir_path = arg;
            } else {
                fatal.msg(
                    "error: unexpected argument '{s}', only one content directory can be given",
                    .{arg},
                );
            }
        }

        const content = content_dir_path orelse {
            fatal.msg(
                \\
                \\error: missing the documentation directory
                \\
                \\Usage: zdoc docs <dir>
                \\  e.g. zdoc docs docs
                \\       zdoc docs ~/projects/myapp/docs --output public
                \\
                \\
            , .{});
        };

        // Without --base the content directory is also the base, which is the
        // common case: you point the command at your docs folder and it just
        // works. An absolute content path is handled by falling back to the
        // cwd for the base.
        const cwd = std.process.currentPathAlloc(io, gpa) catch fatal.oom();
        const base = base_dir_path orelse cwd;

        const site_title = title orelse deriveTitle(gpa, content);

        // Docs mode overrides the layout and asset directories with the
        // built-in theme, so the values here are placeholders that satisfy
        // deserialization without ever being read.
        const cfg: root.Config = .{
            .zine_version = options.version,
            .mode = "docs",
            .site = .{ .simple = .{
                .title = site_title,
                .host_url = "http://localhost/",
                .layouts_dir_path = docs.theme_layouts_path,
                .content_dir_path = content,
                .assets_dir_path = docs.theme_assets_path,
            } },
        };

        return .{
            .config = cfg,
            .base_dir_path = base,
            .output_dir_path = output_dir_path,
            .build_assets = build_assets,
            .drafts = drafts,
            .force = force,
        };
    }
};

/// Derives a human-readable site title from the content directory name,
/// turning `my-project-docs` into `My Project Docs`.
///
/// The result is heap-allocated because it outlives this function: it is
/// stored in the config, which the build keeps a reference to.
fn deriveTitle(gpa: Allocator, content_dir_path: []const u8) []const u8 {
    const base = std.fs.path.basename(content_dir_path);
    if (base.len == 0) return "Documentation";

    const buf = gpa.alloc(u8, base.len) catch fatal.oom();
    var len: usize = 0;
    var capitalize_next = true;

    for (base) |ch| {
        const is_sep = ch == '-' or ch == '_' or ch == '.' or ch == ' ';
        if (is_sep) {
            // Collapse runs of separators and drop the ones we do not need,
            // so `my-project_docs` reads as `My Project Docs`.
            if (len > 0 and buf[len - 1] != ' ') {
                buf[len] = ' ';
                len += 1;
            }
        } else {
            buf[len] = if (capitalize_next) std.ascii.toUpper(ch) else ch;
            len += 1;
        }
        capitalize_next = is_sep;
    }

    // Trim a trailing separator left by a name like `docs-`.
    while (len > 0 and buf[len - 1] == ' ') len -= 1;
    if (len == 0) return "Documentation";
    return buf[0..len];
}

const help_message =
    \\Usage: zdoc docs <dir> [OPTIONS]
    \\
    \\Build a documentation website from a directory of Markdown files, with no
    \\configuration file required. Layouts, styles and behaviour come from the
    \\built-in theme.
    \\
    \\Positional arguments:
    \\  <dir>               Directory containing the Markdown files
    \\
    \\Command specific options:
    \\  --title, -t TITLE   Site title (defaults to the directory name)
    \\  --base DIR          Base directory the content path is relative to
    \\                      (defaults to the current directory)
    \\  --output, -o DIR    Directory where to output the website
    \\                      (defaults to 'public/')
    \\  --force, -f         Ignore other files in the output directory
    \\  --help, -h          Show this help menu
    \\
    \\
;