const std = @import("std");
const builtin = @import("builtin");
const options = @import("options");
const tracy = @import("tracy");
const fatal = @import("fatal.zig");
const worker = @import("worker.zig");
pub const root = @import("root.zig");
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.main);

pub const std_options: std.Options = .{
    .log_level = .err,
    .log_scope_levels = options.log_scope_levels,
};

const Command = enum {
    init,
    @"install-schemas",
    /// Official site: SuperMD pages and SuperHTML templates, from `zine.ziggy`.
    site,
    /// Blog: the same templates, with dated posts and a feed.
    blog,
    /// Previous name of `blog`, without the `blog/` directory default.
    release,
    debug,
    /// Build a documentation site from a directory of Markdown files, with no
    /// config file. The entry point this fork exists to provide.
    docs,
    /// The same Markdown tree as `docs`, rendered as a book.
    ebook,
    help,
    @"-h",
    @"--help",
    version,
    @"-v",
    @"--version",
    // Because other ssgs have them:
    serve,
    server,
    dev,
    develop,
};

var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
pub const gpa = if (builtin.single_threaded)
    debug_allocator.allocator()
else
    std.heap.smp_allocator;

pub fn main(init: std.process.Init) u8 {
    const io = init.io;

    root.progress = std.Progress.start(io, .{ .draw_buffer = &root.progress_buf });
    defer root.progress.end();

    if (builtin.mode == .debug) {
        std.debug.print(
            \\*-----------------------------------------------*
            \\|    WARNING: THIS IS A DEBUG BUILD OF ZINE     |
            \\|-----------------------------------------------|
            \\| Debug builds enable expensive sanity checks   |
            \\| that reduce performance.                      |
            \\|                                               |
            \\| To create a release build, run:               |
            \\|                                               |
            \\|       zig build -Doptimize=fast               |
            \\|                                               |
            \\| If you're investigating a bug in Zine, then a |
            \\| debug build might turn confusing behavior     |
            \\| into a crash.                                 |
            \\|                                               |
            \\| To disable all forms of concurrency, you can  |
            \\| add the following flag to your build command: |
            \\|                                               |
            \\|              -Dsingle-threaded                |
            \\|                                               |
            \\*-----------------------------------------------*
            \\
            \\
        , .{});
    }
    if (tracy.enable) {
        std.debug.print(
            \\*-----------------------------------------------*
            \\|            WARNING: TRACING ENABLED           |
            \\|-----------------------------------------------|
            \\| Tracing introduces a significant performance  |
            \\| overhead.                                     |
            \\|                                               |
            \\| If you're not interested in tracing Zine,     |
            \\| remove `-Dtracy` when building again.         |
            \\*-----------------------------------------------*
            \\
            \\
        , .{});
    }

    if (options.tsan) {
        std.debug.print(
            \\*-----------------------------------------------*
            \\|             WARNING: TSAN ENABLED             |
            \\|-----------------------------------------------|
            \\| Thread sanitizer introduces a significant     |
            \\| performance overhead.                         |
            \\|                                               |
            \\| If you're not interested in debugging         |  
            \\| concurrency bugs in Zine, remove `-Dtsan`     |
            \\| when building again.                          |
            \\*-----------------------------------------------*
            \\
            \\
        , .{});
    }

    const args = init.minimal.args.toSlice(init.arena.allocator()) catch fatal.oom();

    const cmd = blk: {
        if (args.len >= 2) {
            if (std.meta.stringToEnum(Command, args[1])) |cmd| {
                break :blk cmd;
            }
        }

        @import("cli/serve.zig").serve(io, gpa, args[1..]) catch fatal.oom();
    };

    const any_error = switch (cmd) {
        .init => @import("cli/init.zig").init(io, gpa, args[2..]),
        .site => @import("cli/release.zig").siteCommand(io, gpa, args[2..]),
        .blog => @import("cli/release.zig").blogCommand(io, gpa, args[2..]),
        .release => @import("cli/release.zig").release(io, gpa, args[2..]),
        .debug => @import("cli/debug.zig").debug(io, gpa, args[2..]),
        .docs => @import("cli/docs.zig").docsCommand(io, gpa, args[2..]),
        .ebook => @import("cli/docs.zig").ebookCommand(io, gpa, args[2..]),
        .@"install-schemas" => @import("cli/install-schemas.zig").install_schemas(io, gpa, args[2..]),
        .help, .@"-h", .@"--help" => fatal.help(),
        .version, .@"-v", .@"--version" => printVersion(),
        .serve, .server, .dev, .develop => {
            std.debug.print(
                "error: run zdoc without any subcommand to start the development server\n\n",
                .{},
            );
            fatal.help();
        },
    };

    return @intFromBool(any_error);
}

fn printVersion() noreturn {
    // This fork is zdoc; the underlying static site generator is Zine.
    std.debug.print("zdoc {s}\n", .{options.version});
    std.process.exit(0);
}
