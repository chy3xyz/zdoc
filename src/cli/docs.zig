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
const site_meta = @import("../docs/site_meta.zig");
const Allocator = std.mem.Allocator;
const BuildAsset = root.BuildAsset;

pub fn docsCommand(io: Io, gpa: Allocator, args: []const []const u8) bool {
    return run(io, gpa, args, false);
}

pub fn ebookCommand(io: Io, gpa: Allocator, args: []const []const u8) bool {
    return run(io, gpa, args, true);
}

fn run(io: Io, gpa: Allocator, args: []const []const u8, ebook: bool) bool {
    const cmd = DocsOptions.parse(io, gpa, args, ebook) catch fatal.oom();

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
        .theme_dir = cmd.theme_dir,
        .theme_keep_existing = cmd.theme_keep_existing,
        .strict_links = cmd.strict,
        .exclude = cmd.exclude,
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

    // `--strict` reports a non-zero exit for dead links, but only after the
    // site has been written: a CI failure over a broken link should still
    // leave the output in place to look at.
    if (build.docs_link_errors > 0) {
        std.debug.print(
            \\error: {d} link(s) did not resolve and --strict is set.
            \\\nThe site was generated; failing because of the dead links above.
            \\\n
        , .{build.docs_link_errors});
        return true;
    }

    const out = cmd.output_dir_path orelse "public";
    const kind = if (ebook) "Reading" else "Documentation";
    std.debug.print(
        \\
        \\{s} site generated in '{s}/'.
        \\Point a web server at that directory to publish it.
        \\
        \\
    , .{ kind, out });

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
    theme_dir: ?[]const u8,
    theme_keep_existing: bool,
    strict: bool,
    exclude: []const []const u8,

    pub fn deinit(co: *const DocsOptions, gpa: Allocator) void {
        var ba = co.build_assets;
        ba.deinit(gpa);
    }

    pub fn parse(io: Io, gpa: Allocator, args: []const []const u8, ebook: bool) !DocsOptions {
        var content_dir_path: ?[]const u8 = null;
        var base_dir_path: ?[]const u8 = null;
        var title: ?[]const u8 = null;
        var lang: ?[]const u8 = null;
        var mermaid: ?[]const u8 = null;
        var url_path_prefix: ?[]const u8 = null;
        var theme_dir: ?[]const u8 = null;
        var theme_keep_existing = false;
        var strict = false;
        var exclude: std.ArrayListUnmanaged([]const u8) = .empty;
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
            } else if (eql(u8, arg, "--lang")) {
                idx += 1;
                if (idx >= args.len) fatal.msg("error: missing argument to '{s}'", .{arg});
                lang = args[idx];
            } else if (startsWith(u8, arg, "--lang=")) {
                lang = arg["--lang=".len..];
            } else if (eql(u8, arg, "--mermaid")) {
                idx += 1;
                if (idx >= args.len) fatal.msg("error: missing argument to '{s}'", .{arg});
                mermaid = args[idx];
            } else if (startsWith(u8, arg, "--mermaid=")) {
                mermaid = arg["--mermaid=".len..];
            } else if (eql(u8, arg, "--url-prefix")) {
                idx += 1;
                if (idx >= args.len) fatal.msg("error: missing argument to '{s}'", .{arg});
                url_path_prefix = args[idx];
            } else if (startsWith(u8, arg, "--url-prefix=")) {
                url_path_prefix = arg["--url-prefix=".len..];
            } else if (eql(u8, arg, "--theme-dir")) {
                idx += 1;
                if (idx >= args.len) fatal.msg("error: missing argument to '{s}'", .{arg});
                theme_dir = args[idx];
            } else if (startsWith(u8, arg, "--theme-dir=")) {
                theme_dir = arg["--theme-dir=".len..];
            } else if (eql(u8, arg, "--keep-theme")) {
                theme_keep_existing = true;
            } else if (eql(u8, arg, "--strict")) {
                strict = true;
            } else if (eql(u8, arg, "--exclude")) {
                idx += 1;
                if (idx >= args.len) fatal.msg("error: missing argument to '{s}'", .{arg});
                try exclude.append(gpa, args[idx]);
            } else if (startsWith(u8, arg, "--exclude=")) {
                try exclude.append(gpa, arg["--exclude=".len..]);
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

        // No path means "the docs folder people already have". A repository
        // keeps that tree in `docs/`; a command run from inside the tree
        // itself has no such subdirectory, and the current directory is it.
        const content = chooseContentDir(content_dir_path, contentDirExists(io, "docs"));

        // Without --base the content directory is also the base, which is the
        // common case: you point the command at your docs folder and it just
        // works. An absolute content path is handled by falling back to the
        // cwd for the base.
        const cwd = std.process.currentPathAlloc(io, gpa) catch fatal.oom();
        const base = base_dir_path orelse cwd;

        // `--theme-dir` replaces this. Otherwise a `.zdoc-theme/` next to the
        // content root the build opens (`docs/.zdoc-theme` when the tree is
        // `docs/`) is the override. One in the current directory is not the
        // theme for a `docs/` tree. Absent means the built-in theme only.
        if (theme_dir == null) {
            theme_dir = themeDirBesideContent(io, gpa, base, content);
        }

        const chrome = loadChrome(io, gpa, base, theme_dir);

        // A flag is the one-off. `site.yaml` is what the preview server can
        // see, because that server builds with the same defaults as
        // `zdoc docs` and has no place to put a flag.
        const site_title = title orelse if (chrome.title.len != 0)
            chrome.title
        else
            deriveTitle(gpa, content);
        const site_lang = lang orelse if (chrome.lang.len != 0) chrome.lang else null;
        const site_mermaid = mermaid orelse if (chrome.mermaid.len != 0) chrome.mermaid else null;

        // Normalize here rather than in `root.Config.validate`, because that
        // validation is shared with blog mode and rejects a leading slash
        // outright. Authors write `--url-prefix /docs/` far more often than
        // `--url-prefix docs`, and both have to mean the same thing.
        // A yaml value of `/` means the site root, which is the default.
        const prefix = if (url_path_prefix) |raw|
            try normalizeUrlPrefix(gpa, raw)
        else if (chrome.url_prefix.len != 0 and std.mem.trim(u8, chrome.url_prefix, "/").len != 0)
            try normalizeUrlPrefix(gpa, chrome.url_prefix)
        else
            null;

        // Docs mode overrides the layout and asset directories with the
        // built-in theme, so the values here are placeholders that satisfy
        // deserialization without ever being read.
        const cfg: root.Config = .{
            .zine_version = options.version,
            .mode = if (ebook) "ebook" else "docs",
            .site = .{ .simple = .{
                .title = site_title,
                .lang = site_lang,
                .host_url = "http://localhost/",
                .url_path_prefix = prefix,
                .layouts_dir_path = docs.theme_layouts_path,
                .content_dir_path = content,
                .assets_dir_path = docs.theme_assets_path,
                .mermaid = site_mermaid,
            } },
            .chrome = chrome,
        };

        return .{
            .config = cfg,
            .base_dir_path = base,
            .output_dir_path = output_dir_path,
            .build_assets = build_assets,
            .drafts = drafts,
            .force = force,
            .theme_dir = theme_dir,
            .theme_keep_existing = theme_keep_existing,
            .strict = strict,
            .exclude = try exclude.toOwnedSlice(gpa),
        };
    }
};

/// The content directory for `zdoc docs` when the caller may have omitted it.
///
/// An explicit path always wins, including a path that does not exist yet:
/// that failure belongs to the build, which can name the directory the user
/// actually typed. With no path, `docs/` is the conventional tree and `.` is
/// the tree you are already standing in.
fn chooseContentDir(explicit: ?[]const u8, docs_dir_exists: bool) []const u8 {
    if (explicit) |dir| return dir;
    if (docs_dir_exists) return "docs";
    return ".";
}

/// Whether `name` in the current directory can be opened as a directory.
///
/// A file of that name is not a documentation tree, so it counts as absent
/// and the command falls back to the current directory. Any other failure
/// (permissions, I/O) is reported: silently switching trees would build the
/// wrong site.
fn contentDirExists(io: Io, name: []const u8) bool {
    var cwd = Io.Dir.cwd();
    var dir = cwd.openDir(io, name, .{}) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return false,
        else => fatal.dir(name, err),
    };
    dir.close(io);
    return true;
}

/// `.zdoc-theme/` beside the content directory the build will open.
///
/// The path is relative to `base_path`, the same way the content path is.
/// A missing directory, or a file of that name, is not an override.
fn themeDirBesideContent(
    io: Io,
    gpa: Allocator,
    base_path: []const u8,
    content: []const u8,
) ?[]const u8 {
    const candidate = std.fs.path.join(gpa, &.{ content, docs.theme_dir }) catch fatal.oom();
    var base = Io.Dir.cwd().openDir(io, base_path, .{}) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => {
            gpa.free(candidate);
            return null;
        },
        else => fatal.dir(base_path, err),
    };
    defer base.close(io);

    var dir = base.openDir(io, candidate, .{}) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => {
            gpa.free(candidate);
            return null;
        },
        else => fatal.dir(candidate, err),
    };
    dir.close(io);
    return candidate;
}

/// Reads `.zdoc-theme/site.yaml` when the theme directory exists.
///
/// A missing file is the common case and means the built-in chrome. A file
/// that cannot be parsed stops the build: a typo in the only place an author
/// sets the footer should not silently publish the site without it.
fn loadChrome(
    io: Io,
    gpa: Allocator,
    base: []const u8,
    theme_dir: ?[]const u8,
) site_meta.Chrome {
    const dir = theme_dir orelse return .{};
    const yaml_path = std.fs.path.join(gpa, &.{ base, dir, "site.yaml" }) catch fatal.oom();
    const bytes = Io.Dir.cwd().readFileAllocOptions(
        io,
        yaml_path,
        gpa,
        .limited(1024 * 1024),
        .of(u8),
        0,
    ) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => fatal.file(yaml_path, err),
    };
    const parsed = site_meta.parse(gpa, bytes) catch fatal.oom();
    if (parsed.err) |msg| fatal.msg("error: {s}\n", .{msg});
    return parsed.chrome;
}

test "chooseContentDir prefers an explicit path" {
    try std.testing.expectEqualStrings("guide", chooseContentDir("guide", true));
}

test "chooseContentDir uses docs when that directory exists" {
    try std.testing.expectEqualStrings("docs", chooseContentDir(null, true));
}

test "chooseContentDir falls back to the current directory" {
    try std.testing.expectEqualStrings(".", chooseContentDir(null, false));
}

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

/// Trims the slashes an author is likely to wrap a URL prefix in.
///
/// The prefix is joined into hrefs as `/{prefix}/`, so a leading or trailing
/// slash would produce `//docs//`. Rejecting those forms would be worse than
/// accepting them: `--url-prefix /docs/` is the natural thing to type.
fn normalizeUrlPrefix(
    gpa: Allocator,
    raw: []const u8,
) error{OutOfMemory}![]const u8 {
    const trimmed = std.mem.trim(u8, raw, "/");
    if (trimmed.len == 0) return fatal.msg(
        \\error: --url-prefix cannot be empty
        \\
        \\Pass a subpath like 'docs' if the site is served from
        \\a subdirectory of its host.
        \\
    , .{});
    return gpa.dupe(u8, trimmed);
}

const help_message =
    \\Usage: zdoc docs [dir] [OPTIONS]
    \\       zdoc ebook [dir] [OPTIONS]
    \\
    \\Build a website from a directory of Markdown files, with no configuration
    \\file required. `zdoc docs` is a documentation site. `zdoc ebook` is the
    \\same tree read as a book: the root page is the cover, and each other
    \\page links to the previous and next chapter. Layouts and styles come
    \\from the built-in theme. A '.zdoc-theme/' directory next to the
    \\content can replace individual files, add custom.css, and carry
    \\site.yaml for a logo, footer, edit link and language switcher.
    \\
    \\Positional arguments:
    \\  [dir]               Directory containing the Markdown files.
    \\                      Defaults to 'docs/' when that directory exists,
    \\                      otherwise the current directory.
    \\                      e.g. zdoc docs
    \\                           zdoc docs ~/projects/myapp/docs --output public
    \\
    \\Command specific options:
    \\  --title, -t TITLE   Site title (defaults to the directory name)
    \\  --lang LANG         BCP 47 language tag for the site, used for
    \\                      <html lang> and for choosing the right
    \\                      localized copy of a page (defaults to 'en')
    \\  --base DIR          Base directory the content path is relative to
    \\                      (defaults to the current directory)
    \\  --output, -o DIR    Directory where to output the website
    \\                      (defaults to 'public/')
    \\  --mermaid FILE|DIR  Vendored mermaid bundle or dist directory,
    \\                      for rendering diagrams without network access
    \\  --url-prefix PATH  Serve the site from a subdirectory, for
    \\                      example when publishing to
    \\                      https://example.com/repo/docs/
    \\  --theme-dir DIR    Use theme files from DIR where present, and the
    \\                      built-in theme for the rest. Override a single
    \\                      stylesheet or layout without copying the rest.
    \\                      '.zdoc-theme/' next to the content is picked up
    \\                      automatically, and --theme-dir replaces that.
    \\                      site.yaml and custom.css in that directory set
    \\                      the logo, footer, edit link, languages, versions, colors,
    \\                      title, language tag, URL prefix and mermaid path.
    \\                      A command-line flag replaces the matching key.
    \\  --keep-theme        Do not overwrite theme files that already exist
    \\                      in '.zdoc-theme/', so local edits survive a
    \\                      rebuild
    \\  --exclude GLOB      Do not publish pages matching GLOB, relative to the
    \\                      content directory. Repeatable. `*` stays within one
    \\                      path segment, `**` crosses directories, so
    \\                      'dev/**' removes a whole section. The same thing
    \\                      can be said of a page with `exclude: true` in its
    \\                      frontmatter, which on a section's index page
    \\                      removes that section.
    \\  --strict            Exit non-zero when a link does not resolve. The
    \\                      site is still generated, so the output is there
    \\                      to inspect.
    \\  --force, -f         Ignore other files in the output directory
    \\  --help, -h          Show this help menu
    \\
    \\
;
