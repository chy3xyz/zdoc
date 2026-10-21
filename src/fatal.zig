const std = @import("std");
const main = @import("main.zig");
const builtin = @import("builtin");

pub fn msg(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print(fmt, args);
    if (builtin.mode == .debug) std.debug.panic("\n\n(Zine debug stack trace)\n", .{});
    std.process.exit(1);
}

pub fn oom() noreturn {
    msg("oom\n", .{});
}

pub fn dir(path: []const u8, err: anyerror) noreturn {
    msg("error accessing dir '{s}': {t}\n", .{ path, err });
}

pub fn file(path: []const u8, err: anyerror) noreturn {
    msg("error accessing file '{s}': {t}\n", .{ path, err });
}

pub fn help() noreturn {
    std.debug.print(
        \\Usage: zdoc [COMMAND] [OPTIONS]
        \\
        \\Commands:
        \\  site [dir]         Build the official site from SuperMD (.smd) and
        \\                     SuperHTML (.shtml). Defaults to 'site/' when
        \\                     that directory has a zine.ziggy
        \\  blog [dir]         Build the blog the same way: dated posts and a
        \\                     feed. Defaults to 'blog/' when it has a zine.ziggy
        \\  docs [dir]         Build a documentation site from Markdown, with
        \\                     no config file. Defaults to 'docs/' when that
        \\                     directory exists, otherwise the current directory
        \\  ebook [dir]        Build that same tree as a book. The root page
        \\                     is the cover; other pages are chapters
        \\  (no command)       Development server. With zine.ziggy, previews the
        \\                     site or blog. Otherwise previews the docs tree
        \\  init [dir]         Initialize an official site: landing, product,
        \\                     blog, plus docs/ and book/ Markdown trees
        \\  release            Previous name of 'blog', from the current directory
        \\  install-schemas    Install up-to-date Ziggy Schemas for editor support
        \\  help               Show this menu and exit
        \\  version            Print the zdoc version and exit
        \\
        \\Documentation options:
        \\  --title, -t TITLE   Site title (defaults to the directory name)
        \\  --base DIR          Base directory the content path is relative to
        \\  --output, -o DIR    Output directory (defaults to 'public/')
        \\  --mermaid FILE|DIR  Vendored mermaid bundle or dist directory,
        \\                      for rendering diagrams without network access
        \\  --force, -f         Ignore other files in the output directory
        \\
        \\General Options:
        \\  --drafts           Enable draft pages
        \\  --help, -h         Print command specific usage and extra options
        \\
        \\Development web server options:
        \\  --host HOST             Listening host (default 'localhost')
        \\  --port PORT             Listening port (default 1990)
        \\  --debounce <ms>         Rebuild delay after a file change (default 25)
        \\  --url-path-prefix PATH  Override the 'url_path_prefix' value in 'zine.ziggy'
        // \\  --config, -c FILE  Use a custom config file instead of searching
        // \\                     recursively upwards for a 'zine.ziggy' file
        \\
        \\
    , .{});
    std.process.exit(1);
}
