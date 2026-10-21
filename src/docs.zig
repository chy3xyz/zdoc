//! Policy for "docs mode": turning a plain directory of Markdown files into a
//! documentation website, VitePress style.
//!
//! Docs mode differs from Zine's blog mode in three ways, all of which exist
//! because the input is documentation written for GitHub rather than for Zine:
//!
//!   1. `.md` is accepted alongside `.smd`, and `README.md` counts as a
//!      directory's index page (VitePress semantics).
//!   2. Frontmatter is optional. `title` is synthesized from the first level-1
//!      heading, and `date` defaults to the epoch so that sorting never fails.
//!   3. Recoverable problems are reported as warnings instead of failing the
//!      build, because imported docs routinely contain dead links to files that
//!      live outside the docs tree.
//!   4. Headings get GitHub-compatible auto-generated anchor ids, so that the
//!      `#anchor` links written for GitHub keep working.

const std = @import("std");
const Io = std.Io;
const supermd = @import("supermd");
const slug = @import("docs/slug.zig");
const heading_id = @import("docs/heading_id.zig");
const explicitHeadingId = heading_id.explicitHeadingId;
pub const Sidebar = @import("docs/Sidebar.zig");
/// The YAML-subset frontmatter reader used in docs mode.
pub const frontmatter = @import("docs/frontmatter.zig");
/// Per-page last-modified dates read from git history.
pub const GitDates = @import("docs/GitDates.zig");
/// Search index generation.
pub const Search = @import("docs/Search.zig");
/// `sitemap.xml` generation.
pub const Sitemap = @import("docs/Sitemap.zig");
/// `:::` container rewriting.
pub const Containers = @import("docs/Containers.zig");
/// Keeping pages out of the site.
pub const Exclude = @import("docs/Exclude.zig");
const Variant = @import("Variant.zig");
const StringTable = @import("StringTable.zig");
const PathTable = @import("PathTable.zig");
const String = StringTable.String;
const Path = PathTable.Path;

/// The layout used by pages that do not declare one.
pub const default_layout = "doc.shtml";

/// The layout `zdoc ebook` uses when a page does not declare one.
///
/// A book is the same tree as a documentation site, read as chapters: the
/// root page is the cover, and every other page has a previous and a next.
pub const ebook_layout = "ebook.shtml";

/// Which built-in layout a page gets when its frontmatter does not name one.
pub fn defaultLayout(ebook: bool) []const u8 {
    return if (ebook) ebook_layout else default_layout;
}

/// Files that make up the built-in documentation theme.
///
/// In docs mode the configured `layouts_dir_path` and `assets_dir_path` are
/// overridden with these two directories, and the files are materialized into
/// them before the build starts. That keeps rendering on a single code path:
/// the templates and assets are discovered by the ordinary scanning code
/// whether they came from the binary or from the user.
const theme_layout_files = [_]struct { path: []const u8, src: []const u8 }{
    .{ .path = "doc.shtml", .src = @embedFile("docs/theme/layouts/doc.shtml") },
    .{ .path = "ebook.shtml", .src = @embedFile("docs/theme/layouts/ebook.shtml") },
    .{ .path = "home.shtml", .src = @embedFile("docs/theme/layouts/home.shtml") },
    .{
        .path = "templates/base.shtml",
        .src = @embedFile("docs/theme/layouts/templates/base.shtml"),
    },
    .{
        .path = "templates/base_bare.shtml",
        .src = @embedFile("docs/theme/layouts/templates/base_bare.shtml"),
    },
};

const theme_asset_files = [_]struct { path: []const u8, src: []const u8 }{
    .{ .path = "zdoc.css", .src = @embedFile("docs/theme/assets/zdoc.css") },
    .{ .path = "zdoc.js", .src = @embedFile("docs/theme/assets/zdoc.js") },
    // A static host serves this for any URL it cannot find. Generating it
    // rather than asking the author to write one keeps it in step with the
    // theme, which is the whole reason to generate it at all.
    .{ .path = "404.html", .src = @embedFile("docs/theme/assets/404.html") },
};

/// Directory the built-in theme is materialized into, relative to the base
/// directory. Dot-prefixed so it never shows up in a content scan.
pub const theme_dir = ".zdoc-theme";
pub const theme_layouts_path = ".zdoc-theme/layouts";
pub const theme_assets_path = ".zdoc-theme/assets";

/// Name the vendored mermaid bundle is published under. It sits next to the
/// generated loader in the output root, so the loader can import it with a
/// plain relative URL.
pub const mermaid_bundle_name = "mermaid.esm.min.mjs";
pub const mermaid_loader_name = "mermaid.js";

/// Writes the docs-mode 404 page.
///
/// The theme ships a static `404.html` so a host has something to serve
/// before this runs. That file always points at `/`. A site mounted at
/// `/docs/` would then load neither its stylesheet nor its homepage, so the
/// build rewrites the page with the same prefix the rest of the links use.
/// `lang` is the site language. `title` is the site title, used on the link
/// back; an empty title keeps the generic label.
pub fn writeNotFound(
    w: *std.Io.Writer,
    prefix: []const u8,
    lang: []const u8,
    title: []const u8,
) std.Io.Writer.Error!void {
    try w.writeAll("<!DOCTYPE html>\n<html lang=\"");
    try writeHtmlAttr(w, if (lang.len == 0) "en" else lang);
    try w.writeAll("\">\n\t<head id=\"head\">\n");
    try w.writeAll("\t\t<meta charset=\"utf-8\">\n");
    try w.writeAll("\t\t<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n");
    try w.writeAll("\t\t<title>Page not found</title>\n");
    try w.writeAll("\t\t<meta name=\"robots\" content=\"noindex\">\n");
    try w.writeAll("\t\t<link rel=\"stylesheet\" href=\"");
    try writeRootHref(w, prefix, "zdoc.css");
    try w.writeAll("\">\n");
    try w.writeAll("\t\t<link rel=\"stylesheet\" href=\"");
    try writeRootHref(w, prefix, "custom.css");
    try w.writeAll("\">\n");
    try w.writeAll("\t</head>\n\t<body id=\"body\">\n");
    try w.writeAll("\t\t<div class=\"notfound\">\n");
    try w.writeAll("\t\t\t<p class=\"notfound__code\">404</p>\n");
    try w.writeAll("\t\t\t<h1 class=\"notfound__title\">This page does not exist</h1>\n");
    try w.writeAll("\t\t\t<p class=\"notfound__body\">\n");
    try w.writeAll("\t\t\t\tThe address may be mistyped, or the page may have been moved or\n");
    try w.writeAll("\t\t\t\trenamed since the link was written.\n");
    try w.writeAll("\t\t\t</p>\n");
    try w.writeAll("\t\t\t<p class=\"notfound__actions\">\n");
    try w.writeAll("\t\t\t\t<a class=\"hero__action hero__action--brand\" href=\"");
    try writeRootHref(w, prefix, "");
    try w.writeAll("\">");
    if (title.len == 0) {
        try w.writeAll("Back to the documentation");
    } else {
        try w.writeAll("Back to ");
        try writeHtmlText(w, title);
    }
    try w.writeAll("</a>\n");
    try w.writeAll("\t\t\t</p>\n\t\t</div>\n\t</body>\n</html>\n");
}

fn writeRootHref(w: *std.Io.Writer, prefix: []const u8, name: []const u8) std.Io.Writer.Error!void {
    try w.writeByte('/');
    if (prefix.len != 0) {
        try writeHtmlAttr(w, prefix);
        try w.writeByte('/');
    }
    try writeHtmlAttr(w, name);
}

fn writeHtmlAttr(w: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
    for (s) |c| switch (c) {
        '&' => try w.writeAll("&amp;"),
        '"' => try w.writeAll("&quot;"),
        '<' => try w.writeAll("&lt;"),
        '>' => try w.writeAll("&gt;"),
        else => try w.writeByte(c),
    };
}

fn writeHtmlText(w: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
    try writeHtmlAttr(w, s);
}

const mermaid_cdn =
    "https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.esm.min.mjs";

/// The generated loader. Kept as a file rather than inline script so the
/// template stays static and the template language never has to decide where
/// mermaid comes from.
///
/// Only the diagrams actually present are rendered, and the import itself is
/// deferred, so a page without diagrams costs nothing.
fn mermaidLoaderSrc(gpa: std.mem.Allocator, local: bool) ![]const u8 {
    // Built by concatenation rather than `std.fmt`: Zig 0.17's formatter rejects
    // `{{` escaping in a runtime format string, and the JavaScript below is full
    // of braces.
    const url = if (local) "./" ++ mermaid_bundle_name else mermaid_cdn;

    return std.mem.concat(gpa, u8, &.{
        "// Generated by zdoc. Resolves the mermaid bundle, preferring a\n",
        "// vendored copy so the documentation renders without network access.\n",
        "const MermaidURL = '",
        url,
        "';\n",
        "const blocks = document.querySelectorAll('pre.mermaid');\n",
        // No top-level `return`: this file is an ES module, where `return`
        // outside a function is a syntax error and would stop the whole
        // loader from running.
        "if (blocks.length > 0) {\n",
        "\tlet mermaid;\n",
        "\ttry {\n",
        "\t\tmermaid = (await import(MermaidURL)).default;\n",
        "\t} catch (err) {\n",
        "\t\tfor (const el of blocks) {\n",
        "\t\t\tel.classList.add('mermaid-error');\n",
        "\t\t\tel.setAttribute('title', String(err));\n",
        "\t\t}\n",
        "\t}\n",
        "\tif (mermaid) {\n",
        "\t\tmermaid.initialize({ startOnLoad: false });\n",
        "\t\tfor (const el of blocks) {\n",
        "\t\t\ttry {\n",
        "\t\t\t\tconst { svg } = await mermaid.render(\n",
        "\t\t\t\t\t'm' + Math.random().toString(36).slice(2),\n",
        "\t\t\t\t\tel.textContent\n",
        "\t\t\t\t);\n",
        "\t\t\t\tel.innerHTML = svg;\n",
        "\t\t\t} catch (err) {\n",
        "\t\t\t\t// A malformed diagram should not blank the page; leave\n",
        "\t\t\t\t// the source visible so the author can still read it.\n",
        "\t\t\t\tel.classList.add('mermaid-error');\n",
        "\t\t\t\tel.setAttribute('title', String(err));\n",
        "\t\t\t}\n",
        "\t\t}\n",
        "\t}\n",
        "}\n",
    });
}

/// Materializes the built-in theme so that the normal template and asset
/// scanners find it.
///
/// When `mermaid_local` points at a vendored bundle or dist directory, it is
/// copied into the theme's asset directory. That way it is installed by the
/// existing asset pipeline — a site asset is copied to the output only when
/// something links it, and the generated loader does exactly that.
///
/// `override_dir` customizes the theme file by file. A file present there is
/// used instead of the built-in one, and a file absent falls back to the
/// built-in, so overriding `zdoc.css` does not require copying the layouts
/// too. Everything still lands in `.zdoc-theme/`, which is what keeps a single
/// code path through the scanners and the renderer.
///
/// Returns the vendored mermaid asset paths that must be installed even though
/// no template links them: the loader resolves the bundle at runtime, and the
/// bundle itself imports its sibling chunks.
pub fn installTheme(
    io: Io,
    gpa: std.mem.Allocator,
    base_dir_path: []const u8,
    content_dir_path: []const u8,
    mermaid_local: ?[]const u8,
    override_dir: ?[]const u8,
    keep_existing: bool,
    logo: []const u8,
) ![]const []const u8 {
    var base = Io.Dir.cwd().openDir(io, base_dir_path, .{}) catch |err| return err;
    defer base.close(io);

    const layouts = base.createDirPathOpen(
        io,
        theme_layouts_path,
        .{ .open_options = .{ .iterate = true } },
    ) catch |err| return err;
    defer layouts.close(io);

    const assets = base.createDirPathOpen(
        io,
        theme_assets_path,
        .{ .open_options = .{ .iterate = true } },
    ) catch |err| return err;
    defer assets.close(io);

    var overrides: ?Overrides = null;
    if (override_dir) |dir_path| {
        overrides = Overrides.open(io, base, dir_path) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => null,
            else => return err,
        };
    }

    for (theme_layout_files) |f| {
        if (overrides) |o| {
            if (o.read(io, f.path)) |src| {
                writeFile(io, layouts, f.path, src) catch |err| return err;
                continue;
            } else |_| {}
        }
        if (keep_existing and exists(io, layouts, f.path)) continue;
        writeFile(io, layouts, f.path, f.src) catch |err| return err;
    }
    for (theme_asset_files) |f| {
        if (overrides) |o| {
            if (o.read(io, f.path)) |src| {
                writeFile(io, assets, f.path, src) catch |err| return err;
                continue;
            } else |_| {}
        }
        if (keep_existing and exists(io, assets, f.path)) continue;
        writeFile(io, assets, f.path, f.src) catch |err| return err;
    }

    // `custom.css` is linked by the built-in theme after `zdoc.css`, so an
    // author can redeclare `--accent` and the other variables without copying
    // the stylesheet. The stub is what a fresh tree gets; an override, or a
    // file already on disk when `keep_existing` is set, wins.
    const custom_css_stub =
        \\/* Redeclare the variables from zdoc.css to change colors.
        \\   :root { --accent: #9a3412; }
        \\*/
        \\
    ;
    if (overrides) |o| {
        if (o.read(io, "custom.css")) |src| {
            writeFile(io, assets, "custom.css", src) catch |err| return err;
        } else |_| {
            if (!(keep_existing and exists(io, assets, "custom.css"))) {
                writeFile(io, assets, "custom.css", custom_css_stub) catch |err| return err;
            }
        }
    } else if (!(keep_existing and exists(io, assets, "custom.css"))) {
        writeFile(io, assets, "custom.css", custom_css_stub) catch |err| return err;
    }

    if (logo.len != 0) {
        const o = overrides orelse return error.FileNotFound;
        const src = o.read(io, logo) catch |err| switch (err) {
            error.FileNotFound => return error.FileNotFound,
            else => return err,
        };
        writeFile(io, assets, logo, src) catch |err| return err;
    }

    var installed: std.ArrayListUnmanaged([]const u8) = .empty;

    // Everything under `static/` is copied verbatim and installed at the
    // output root. This is how a docs site ships `CNAME`, `robots.txt`,
    // favicons, demo pages, and other files that nothing links to.
    //
    // It is `static/`, not `public/`: `public/` is the default *output*
    // directory, and treating it as input would copy a previous build into
    // the next one. The content-local directory wins; `static/` next to the
    // content tree is the fallback when `--base` points somewhere else.
    const content_static = try std.fs.path.join(gpa, &.{
        content_dir_path,
        "static",
    });
    if (!try copyStaticDir(gpa, io, base, assets, content_static, &installed)) {
        _ = try copyStaticDir(gpa, io, base, assets, "static", &installed);
    }

    var vendored = false;
    if (mermaid_local) |src_path| {
        vendored = try installVendoredMermaid(
            gpa,
            io,
            base,
            assets,
            src_path,
            &installed,
        );
    }

    const loader = try mermaidLoaderSrc(gpa, vendored);
    writeFile(io, assets, mermaid_loader_name, loader) catch |err| return err;

    return try installed.toOwnedSlice(gpa);
}

/// Copies a vendored mermaid distribution into the theme assets.
///
/// The published `mermaid.esm.min.mjs` is not self-contained: it imports
/// `./chunks/...`. Passing its `dist` directory therefore works, and so does
/// passing the entry file when the sibling `chunks` directory is present.
/// A truly self-contained single-file bundle keeps working as well.
///
/// Returns whether the loader should import the vendored copy rather than the
/// CDN. A missing path falls back to the CDN.
fn installVendoredMermaid(
    gpa: std.mem.Allocator,
    io: Io,
    base: Io.Dir,
    assets: Io.Dir,
    src_path: []const u8,
    installed: *std.ArrayListUnmanaged([]const u8),
) !bool {
    const stat = base.statFile(io, src_path, .{}) catch |err| switch (err) {
        error.FileNotFound, error.AccessDenied => return false,
        else => return err,
    };

    if (stat.kind == .directory) {
        const entry_path = try std.fs.path.join(gpa, &.{
            src_path,
            mermaid_bundle_name,
        });
        if (!try copyVendoredFile(gpa, io, base, assets, entry_path)) return false;
        try installed.append(gpa, mermaid_bundle_name);
        try copyMermaidChunks(gpa, io, base, assets, src_path, installed);
        return true;
    }

    if (!try copyVendoredFile(gpa, io, base, assets, src_path)) return false;
    try installed.append(gpa, mermaid_bundle_name);

    // The chunked ESM entry imports `./chunks/<entry-name>/...`; a
    // self-contained single-file bundle has no such directory and needs
    // nothing else.
    const dir_name = std.fs.path.dirname(src_path) orelse ".";
    try copyMermaidChunks(gpa, io, base, assets, dir_name, installed);

    return true;
}

/// Copies `src_path` (relative to `base`) to `dest` as the mermaid entry
/// bundle. Returns false when the source does not exist, which is how a site
/// without a vendored bundle falls back to the CDN.
fn copyVendoredFile(
    gpa: std.mem.Allocator,
    io: Io,
    base: Io.Dir,
    dest: Io.Dir,
    src_path: []const u8,
) !bool {
    const src = base.readFileAllocOptions(
        io,
        src_path,
        gpa,
        .limited(max_vendored_bytes),
        .of(u8),
        0,
    ) catch |err| switch (err) {
        error.FileNotFound, error.AccessDenied, error.IsDir => return false,
        else => return err,
    };
    defer gpa.free(src);

    try dest.writeFile(io, .{ .sub_path = mermaid_bundle_name, .data = src });
    return true;
}

/// Copies the chunk directory the entry bundle imports, when it exists.
///
/// Mermaid's published ESM entry is split by diagram, so only the directory
/// matching the entry name is needed. `mermaid.esm.min.mjs` imports
/// `chunks/mermaid.esm.min/`, for example.
fn copyMermaidChunks(
    gpa: std.mem.Allocator,
    io: Io,
    base: Io.Dir,
    assets: Io.Dir,
    dist_dir_path: []const u8,
    installed: *std.ArrayListUnmanaged([]const u8),
) !void {
    const stem = mermaid_bundle_name[0 .. mermaid_bundle_name.len - ".mjs".len];
    const chunks_path = try std.fs.path.join(gpa, &.{
        dist_dir_path,
        "chunks",
        stem,
    });

    var chunks = base.openDir(io, chunks_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir, error.AccessDenied => return,
        else => return err,
    };
    defer chunks.close(io);

    const prefix = try std.fs.path.join(gpa, &.{ "chunks", stem });
    try copyTree(gpa, io, chunks, assets, prefix, installed, true);
}

/// Copies a `static/` passthrough directory when it exists. Returns false
/// when the path is absent so the caller can try the next candidate.
fn copyStaticDir(
    gpa: std.mem.Allocator,
    io: Io,
    base: Io.Dir,
    assets: Io.Dir,
    path: []const u8,
    installed: *std.ArrayListUnmanaged([]const u8),
) !bool {
    var dir = base.openDir(io, path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir, error.AccessDenied => return false,
        else => return err,
    };
    defer dir.close(io);
    try copyTree(gpa, io, dir, assets, "", installed, false);
    return true;
}

/// Copies every file below `src` into `dest`, preserving relative paths.
///
/// `skip_non_runtime` is for mermaid bundles, where type declarations and
/// source maps would bloat the output. A user-supplied `static/` directory is
/// copied verbatim.
fn copyTree(
    gpa: std.mem.Allocator,
    io: Io,
    src: Io.Dir,
    dest: Io.Dir,
    prefix: []const u8,
    installed: *std.ArrayListUnmanaged([]const u8),
    skip_non_runtime: bool,
) !void {
    var it = src.iterateAssumeFirstIteration();
    while (try it.next(io)) |entry| {
        switch (entry.kind) {
            .file, .sym_link => {
                // Type declarations and source maps are not fetched by the
                // browser, and copying them would bloat the published site.
                if (skip_non_runtime and !isRuntimeFile(entry.name)) continue;

                const rel = if (prefix.len == 0)
                    try gpa.dupe(u8, entry.name)
                else
                    try std.fs.path.join(gpa, &.{ prefix, entry.name });

                const data = try src.readFileAllocOptions(
                    io,
                    entry.name,
                    gpa,
                    .limited(max_vendored_bytes),
                    .of(u8),
                    0,
                );
                defer gpa.free(data);
                try writeFile(io, dest, rel, data);
                try installed.append(gpa, rel);
            },
            .directory => {
                const rel = if (prefix.len == 0)
                    try gpa.dupe(u8, entry.name)
                else
                    try std.fs.path.join(gpa, &.{ prefix, entry.name });

                var sub = try src.openDir(io, entry.name, .{ .iterate = true });
                defer sub.close(io);
                var out = try dest.createDirPathOpen(io, rel, .{});
                defer out.close(io);
                try copyTree(gpa, io, sub, out, rel, installed, skip_non_runtime);
            },
            else => {},
        }
    }
}

fn isRuntimeFile(name: []const u8) bool {
    return !std.mem.endsWith(u8, name, ".map") and
        !std.mem.endsWith(u8, name, ".d.ts") and
        !std.mem.endsWith(u8, name, ".d.mts") and
        !std.mem.endsWith(u8, name, ".d.cts");
}

/// A directory of user-supplied replacements for theme files.
const Overrides = struct {
    dir: Io.Dir,

    fn open(io: Io, base: Io.Dir, dir_path: []const u8) !Overrides {
        return .{ .dir = try base.openDir(io, dir_path, .{}) };
    }

    /// Reads an override for `name`, or returns `error.FileNotFound` when the
    /// user did not supply one and the built-in should be used.
    ///
    /// The distinction matters: a theme file that exists but is empty is the
    /// author overriding it with nothing, which is their call to make.
    fn read(self: Overrides, io: Io, name: []const u8) ![]const u8 {
        return self.dir.readFileAllocOptions(
            io,
            name,
            std.heap.page_allocator,
            .limited(max_override_bytes),
            .of(u8),
            0,
        );
    }
};

const max_override_bytes: usize = 16 * 1024 * 1024;

const max_vendored_bytes: usize = 16 * 1024 * 1024;

/// Whether `name` already exists in `dir`, for the keep-existing theme mode.
fn exists(io: Io, dir: Io.Dir, name: []const u8) bool {
    dir.access(io, name, .{}) catch return false;
    return true;
}

fn writeFile(io: Io, dir: Io.Dir, name: []const u8, src: []const u8) !void {
    // `writeFile` will not create parent directories, and the layouts include
    // one nested under `templates/`.
    if (std.mem.lastIndexOfScalar(u8, name, '/')) |slash| {
        var sub = dir.createDirPathOpen(io, name[0..slash], .{}) catch |err| return err;
        defer sub.close(io);
    }
    dir.writeFile(io, .{ .sub_path = name, .data = src }) catch |err| return err;
}

/// Rewrites a link that could not be resolved so that it is emitted verbatim.
///
/// This is what makes downgrading a link error to a warning safe. When link
/// resolution fails, the link's `Src` is left with its `resolved` field
/// unassigned, and `printUrl` would then read uninitialised memory and emit a
/// garbage URL. Converting the source to a plain `url` makes the renderer emit
/// exactly what the author wrote.
///
/// Returns the original target, for use in the warning message.
pub fn passthroughLink(
    gpa: std.mem.Allocator,
    node: supermd.Node,
) std.mem.Allocator.Error![]const u8 {
    const dir = node.getDirective() orelse return "";

    switch (dir.kind) {
        .link => |*lnk| {
            const src = lnk.src orelse return "";
            const target = try sourceLiteral(gpa, src, lnk.ref);
            lnk.src = .{ .url = target };
            // The fragment is part of `target` now; the renderer must not
            // append it a second time.
            lnk.ref = null;
            return target;
        },
        // Asset directives must stop pointing at an unresolved asset: the
        // renderer would otherwise read `resolved`, which was never assigned.
        // Keep the directive kind so an image stays an image and a code block
        // stays a code block, and emit the author's literal path.
        .image => |*img| {
            const src = img.src orelse return "";
            const target = try sourceLiteral(gpa, src, null);
            img.src = .{ .url = target };
            return target;
        },
        .video => |*vid| {
            const src = vid.src orelse return "";
            const target = try sourceLiteral(gpa, src, null);
            vid.src = .{ .url = target };
            return target;
        },
        .audio => |*snd| {
            const src = snd.src orelse return "";
            const target = try sourceLiteral(gpa, src, null);
            snd.src = .{ .url = target };
            return target;
        },
        .code => |*code| {
            const src = code.src orelse return "";
            const target = try sourceLiteral(gpa, src, null);
            code.src = .{ .url = target };
            return target;
        },
        else => return "",
    }
}

/// Reconstructs the URL the author wrote for a source that failed to resolve.
fn sourceLiteral(
    gpa: std.mem.Allocator,
    src: supermd.context.Src,
    fragment: ?[]const u8,
) std.mem.Allocator.Error![]const u8 {
    if (fragment) |suffix| {
        const base = try sourcePath(gpa, src);
        // A query (optionally followed by a fragment) already carries its
        // leading `?`; a bare fragment still needs the `#`.
        if (suffix.len > 0 and suffix[0] == '?') {
            return std.fmt.allocPrint(gpa, "{s}{s}", .{ base, suffix });
        }
        return std.fmt.allocPrint(gpa, "{s}#{s}", .{ base, suffix });
    }
    return sourcePath(gpa, src);
}

fn pathOnly(ref: []const u8) []const u8 {
    const cut = std.mem.indexOfAny(u8, ref, "#?") orelse ref.len;
    return ref[0..cut];
}

fn sourcePath(
    gpa: std.mem.Allocator,
    src: supermd.context.Src,
) std.mem.Allocator.Error![]const u8 {
    return switch (src) {
        // An external URL keeps its own query; only internal refs are split.
        .url => |url| url,
        .page => |pg| switch (pg.kind) {
            .absolute => std.mem.concat(gpa, u8, &.{ "/", pathOnly(pg.ref) }),
            .sub => if (std.mem.startsWith(u8, pg.ref, "/"))
                restoreClimb(gpa, pathOnly(pg.ref))
            else
                std.mem.concat(gpa, u8, &.{ "./", pathOnly(pg.ref) }),
            .sibling => pathOnly(pg.ref),
        },
        .self_page => |alt| if (alt) |a| a else "",
        .page_asset => |a| pathOnly(a.ref),
        .site_asset => |a| pathOnly(a.ref),
        .build_asset => |b| pathOnly(b.ref),
    };
}

/// Puts back the `..` that SuperMD's link classification discards.
///
/// SuperMD classifies a link by its first character and then drops the first
/// two characters of the target, so `../AGENTS.md` reaches the renderer as
/// `/AGENTS.md` -- a different URL from the one in the source, published under
/// a warning that claimed the link had been left as written.
///
/// A target beginning with `/` is one whose climb was spent, so putting the
/// two discarded characters back recovers exactly what was written. The prefix
/// is `..` and not `../` because the ref still carries the separator: `..`
/// ++ `/AGENTS.md` is `../AGENTS.md` again.
fn restoreClimb(gpa: std.mem.Allocator, ref: []const u8) std.mem.Allocator.Error![]const u8 {
    if (ref.len == 0 or ref[0] != '/') return ref;
    return std.mem.concat(gpa, u8, &.{ "..", ref });
}

/// Runs every docs-mode transformation over a freshly parsed document and
/// returns the warnings that were tolerated. The caller owns the result.
///
/// Heading ids are registered first so `ast.ids` reflects the final document.
/// The parser flags every intra-page link before the generated slugs exist, so
/// its `invalid_ref` verdict is discarded here; link analysis later re-checks
/// the same refs against the completed id table.
pub fn postProcess(
    gpa: std.mem.Allocator,
    ast: *supermd.Ast,
) std.mem.Allocator.Error![]supermd.Ast.Error {
    try applyHeadingIds(gpa, ast);
    return filterParseErrors(gpa, ast);
}

/// Reserves a literal id, appending `-1`, `-2`, ... if an earlier heading
/// already used it. Explicit ids are not slugified: the author asked for this
/// exact spelling.
fn reserveExplicitId(
    strings: std.mem.Allocator,
    set: *slug.Set,
    id: []const u8,
) std.mem.Allocator.Error![]const u8 {
    var candidate = id;
    var suffix: usize = 1;
    while (set.map.contains(candidate)) : (suffix += 1) {
        candidate = try std.fmt.allocPrint(strings, "{s}-{d}", .{ id, suffix });
    }
    const gop = try set.map.getOrPut(strings, candidate);
    gop.value_ptr.* = {};
    return gop.key_ptr.*;
}

/// Removes the `{#id}` marker from the heading's last text node so it does not
/// show up in the rendered title or the TOC.
fn stripExplicitId(
    node: supermd.Node,
    strings: std.mem.Allocator,
    marker: []const u8,
) std.mem.Allocator.Error!void {
    var it = supermd.Ast.Iter.init(node);
    defer it.deinit();

    var last_text: ?supermd.Node = null;
    while (it.next()) |ev| {
        if (ev.dir == .enter and ev.node.nodeType() == .TEXT) last_text = ev.node;
    }
    const text = last_text orelse return;
    const lit = text.literal() orelse return;
    if (!std.mem.endsWith(u8, lit, marker)) return;

    const kept = std.mem.trimEnd(u8, lit[0 .. lit.len - marker.len], " \t");
    const copy = try std.mem.concatWithSentinel(strings, u8, &.{kept}, 0);
    _ = supermd.c.cmark_node_set_literal(text.n, copy.ptr);
}

/// Gives every heading in the document a GitHub-compatible anchor id.
///
/// SuperMD only emits `id` attributes for headings that carry an explicit
/// directive. The renderer and the TOC both read the id from that directive,
/// so this pass is what makes anchors, `$page.toc()` and `](#...)` links work
/// at all. A trailing `{#custom-id}` is honored verbatim; everything else is
/// slugified.
///
/// The ids are also registered in `ast.ids`, because that is the table SuperMD
/// validates `#anchor` references against.
pub fn applyHeadingIds(
    gpa: std.mem.Allocator,
    ast: *supermd.Ast,
) std.mem.Allocator.Error!void {
    // The generated ids are referenced by the heading directives and by
    // `ast.ids`, so they must live as long as the document. SuperMD gives us
    // its own arena, which is the natural owner. `State.promote` copies the
    // arena state by value, so it has to be written back or the allocations
    // are lost when this function returns.
    var ast_arena = ast.arena.promote(gpa);
    defer ast.arena = ast_arena.state;
    const strings = ast_arena.allocator();

    var set = slug.Set{};
    defer set.deinit(gpa);

    var it = supermd.Ast.Iter.init(ast.md.root);
    defer it.deinit();

    while (it.next()) |ev| {
        if (ev.dir != .enter) continue;
        const node = ev.node;
        if (node.nodeType() != .HEADING) continue;

        // A directive here could be a `section` (which wraps a heading) or a
        // `heading` with a hand-written id. Either way the author has been
        // explicit and we must not overwrite it.
        if (node.getDirective() != null) continue;

        const text = try node.renderPlaintext();

        if (explicitHeadingId(text)) |explicit| {
            const marker = text[explicit.start .. explicit.start + 3 + explicit.id.len];
            try stripExplicitId(node, strings, marker);

            const id = try reserveExplicitId(strings, &set, explicit.id);
            var d: supermd.Directive = .{ .kind = .{ .heading = .{} } };
            d.id = id;
            _ = try node.setDirective(strings, &d, true);

            const gop = try ast.ids.getOrPut(strings, id);
            gop.value_ptr.* = node;
            continue;
        }

        const id = try set.unique(strings, text);
        if (id.len == 0) continue;

        var d: supermd.Directive = .{ .kind = .{ .heading = .{} } };
        d.id = id;
        _ = try node.setDirective(strings, &d, true);

        // Registering in `ids` is what lets `#anchor` links resolve; without
        // it every intra-page link is reported as an unknown reference.
        const gop = try ast.ids.getOrPut(strings, id);
        if (!gop.found_existing) gop.value_ptr.* = node;
    }
}

/// Parse errors that documentation mode tolerates.
///
/// These are all opinionated SuperMD rules aimed at hand-authored content. A
/// document imported from a normal Markdown tree can legitimately trip them,
/// and the author has no way to fix them short of editing the tool's opinions,
/// so they are downgraded to warnings.
///
///   - `heading_skip`: `# A` followed by `### B`, skipping a level. Very common
///     in real documentation.
///   - `inline_html`: raw HTML in the body. Only a couple of lines in practice.
pub fn isToleratedParseError(kind: supermd.Ast.Error.Kind) bool {
    return switch (kind) {
        .heading_skip => true,
        else => false,
    };
}

/// Splits `ast.errors` into tolerated warnings and real errors, leaving only
/// the latter in the AST.
///
/// `ast.errors` lives in SuperMD's arena and is `[]const`, so the surviving
/// slice is rebuilt rather than filtered in place.
pub fn filterParseErrors(
    gpa: std.mem.Allocator,
    ast: *supermd.Ast,
) std.mem.Allocator.Error![]supermd.Ast.Error {
    var kept: std.ArrayList(supermd.Ast.Error) = .empty;
    errdefer kept.deinit(gpa);

    var warned: std.ArrayList(supermd.Ast.Error) = .empty;
    errdefer warned.deinit(gpa);

    for (ast.errors) |err| {
        // SuperMD validates `#anchor` references during parsing, before
        // `applyHeadingIds` has registered the slugs generated for ordinary
        // headings. Every intra-page link therefore arrives here as an
        // `invalid_ref`, working or not. The analysis pass re-checks these refs
        // against the completed id table, so the parser's verdict is dropped.
        //
        // `no_alt_in_links` fires for every standard Markdown link title.
        // Docs mode renders the title as a `title` attribute, so the warning
        // would only ask the author to rewrite valid Markdown.
        //
        // `inline_html` is ordinary documentation HTML. The renderer passes it
        // through (and applies the URL prefix to root-relative attributes), so
        // warning on every tag is noise.
        const kind = std.meta.activeTag(err.kind);
        if (kind == .invalid_ref or kind == .no_alt_in_links or kind == .inline_html) {
            continue;
        }

        if (isToleratedParseError(err.kind)) {
            try warned.append(gpa, err);
        } else {
            try kept.append(gpa, err);
        }
    }

    ast.errors = try kept.toOwnedSlice(gpa);
    return warned.toOwnedSlice(gpa);
}

/// Extension-based helpers used while scanning a content directory.
fn endsWithIgnoreCase(s: []const u8, suffix: []const u8) bool {
    return s.len >= suffix.len and std.ascii.eqlIgnoreCase(
        s[s.len - suffix.len ..],
        suffix,
    );
}

fn eqlIgnoreCase(lhs: []const u8, rhs: []const u8) bool {
    return lhs.len == rhs.len and std.ascii.eqlIgnoreCase(lhs, rhs);
}

pub const scan = struct {
    /// Returns true when the filename should become a page rather than an
    /// asset. `.smd` is Zine's own dialect; `.md` and `.markdown` are what
    /// everyone else writes.
    pub fn isPage(name: []const u8) bool {
        return endsWithIgnoreCase(name, ".smd") or
            endsWithIgnoreCase(name, ".md") or
            endsWithIgnoreCase(name, ".markdown");
    }

    /// Returns true when the filename is the index page of its directory.
    ///
    /// In blog mode only `index.smd` qualifies. In docs mode `README.md` does
    /// too, which is what makes `README.md` map to `/` and gives directories
    /// like `dev/` a section index without the author having to create one.
    pub fn isIndex(name: []const u8) bool {
        return eqlIgnoreCase(name, "index.smd") or
            eqlIgnoreCase(name, "index.md") or
            eqlIgnoreCase(name, "index.markdown") or
            eqlIgnoreCase(name, "README.smd") or
            eqlIgnoreCase(name, "README.md") or
            eqlIgnoreCase(name, "README.markdown");
    }

    /// Deterministic preference order when a directory contains more than one
    /// index candidate. `index.md` is the convention Markdown tools expect;
    /// `README.md` is the GitHub one. `.smd` is Zine's own dialect and loses
    /// to a plain Markdown file for the same directory.
    pub fn indexRank(name: []const u8) ?u8 {
        if (eqlIgnoreCase(name, "index.md")) return 0;
        if (eqlIgnoreCase(name, "index.markdown")) return 1;
        if (eqlIgnoreCase(name, "README.md")) return 2;
        if (eqlIgnoreCase(name, "README.markdown")) return 3;
        if (eqlIgnoreCase(name, "index.smd")) return 4;
        if (eqlIgnoreCase(name, "README.smd")) return 5;
        return null;
    }

    /// Strips a trailing Markdown extension from a link target so that
    /// `[x](OTHER.md)` resolves the same way `[x](OTHER)` does. Markdown
    /// documents almost always link with the extension, but Zine interns page
    /// URLs without it.
    pub fn stripMdExtension(ref: []const u8) ?[]const u8 {
        const exts = [_][]const u8{ ".markdown", ".smd", ".md" };
        for (exts) |ext| {
            if (endsWithIgnoreCase(ref, ext)) {
                return ref[0 .. ref.len - ext.len];
            }
        }
        return null;
    }

    /// Maps `dir/README.md` (or `dir/index.md`) onto `dir`, which is the url of
    /// a directory's index page. Returns null when the ref does not name a
    /// directory index.
    ///
    /// A bare `README.md` with no directory in front of it maps onto `/`; that
    /// form is what a link climbing back to the site root looks like.
    pub fn stripDirIndex(ref: []const u8) ?[]const u8 {
        if (std.mem.endsWith(u8, ref, "/")) return null;
        const sep = std.mem.lastIndexOfScalar(u8, ref, '/') orelse
            return if (isIndex(ref)) "/" else null;
        if (!isIndex(ref[sep + 1 ..])) return null;
        const dir = ref[0..sep];
        return if (dir.len == 0) "/" else dir;
    }

    /// A link target resolved against the page that wrote it.
    ///
    /// SuperMD classifies any link starting with `.` as relative to the
    /// current page but does not strip `..` components, so
    /// `[x](../../ref/X.md)` reaches us whole. Climbing out of a directory is
    /// ordinary Markdown and by far the most common way a docs tree links
    /// between sections, so it has to resolve.
    pub const Resolved = struct {
        /// The directory the target is relative to, one component shorter for
        /// each `..` the target climbed.
        prefix_len: usize,
        /// The target with its `..` and `./` components removed.
        rest: []const u8,
    };

    /// Splits `ref` into a climb count and the path underneath it.
    ///
    /// Returns null when the ref climbs above the content root, which no page
    /// can satisfy: a link out of the docs tree is not a page, and treating
    /// it as one would resolve it to something the author never wrote.
    pub fn resolveRelative(prefix_len: usize, ref: []const u8) ?Resolved {
        var remaining = prefix_len;
        var rest = ref;

        // SuperMD strips the first two characters of a dotted link and nothing
        // else. For `./x.md` that is the `./`, which is harmless, but it eats
        // one `../` out of every additional level: `../../x.md` arrives as
        // `/../x.md`. Each leading slash is therefore a climb the author
        // wrote and SuperMD dropped on the way here, and counting them is what
        // makes the link land on the page it names.
        while (rest.len > 0 and rest[0] == '/') {
            if (remaining == 0) return null;
            remaining -= 1;
            rest = rest[1..];
        }

        while (true) {
            if (std.mem.startsWith(u8, rest, "../")) {
                if (remaining == 0) return null;
                remaining -= 1;
                rest = rest["../".len..];
                continue;
            }
            if (std.mem.startsWith(u8, rest, "./")) {
                rest = rest["./".len..];
                continue;
            }
            break;
        }

        // A bare `..` or `../` addresses the parent directory itself, which
        // in this url space is a directory's index page.
        if (rest.len == 0 or std.mem.eql(u8, rest, "..")) return .{
            .prefix_len = remaining,
            .rest = "",
        };

        return .{ .prefix_len = remaining, .rest = rest };
    }

    /// Resolves a relative link target to an absolute content path, trying
    /// each of the forms documentation writes them in.
    ///
    /// Returns null when no form names an existing page, leaving the caller's
    /// fallback -- emit the link as written -- in charge.
    pub fn resolvePageRef(
        v: *const Variant,
        prefix: []const String,
        ref: []const u8,
    ) ?Path {
        const rel = resolveRelative(prefix.len, ref) orelse return null;
        const trimmed = prefix[0..rel.prefix_len];

        // Candidates, in the order documentation writes them: with the `.md`
        // extension, without it, and as a directory index.
        var candidates: [3][]const u8 = undefined;
        var count: usize = 0;
        if (stripMdExtension(rel.rest)) |stripped| {
            candidates[count] = stripped;
            count += 1;
        }
        if (stripDirIndex(rel.rest)) |dir_path| {
            candidates[count] = dir_path;
            count += 1;
        }
        candidates[count] = rel.rest;
        count += 1;

        for (candidates[0..count]) |cand| {
            if (v.path_table.getPathNoName(&v.string_table, trimmed, cand)) |path| {
                return path;
            }
        }
        return null;
    }
};

/// Resolves a frontmatter `layout` value to the file name Zine looks up.
///
/// Documentation is written against other tools, where `layout: home` is the
/// spelling and the extension is implicit. Zine stores layouts as files
/// alongside other templates, so it needs `home.shtml` to find one. Accepting
/// the bare name means an existing frontmatter keeps working as written,
/// which is the whole point of docs mode.
pub fn layoutName(gpa: std.mem.Allocator, ref: []const u8) std.mem.Allocator.Error![]const u8 {
    if (ref.len == 0) return ref;
    if (std.mem.endsWith(u8, ref, ".shtml") or std.mem.endsWith(u8, ref, ".xml")) return ref;
    return std.fmt.allocPrint(gpa, "{s}.shtml", .{ref});
}

/// What a page's title should be when the file has no frontmatter.
pub fn titleFromHeadings(
    gpa: std.mem.Allocator,
    ast: *const @import("supermd").Ast,
) std.mem.Allocator.Error!?[]const u8 {
    // The first level-1 heading is the page's de-facto title, which is how
    // documentation written for GitHub marks its title.
    var node = ast.md.root.firstChild() orelse return null;
    while (true) {
        switch (node.nodeType()) {
            .HEADING => if (node.headingLevel() == 1) {
                const text = try node.renderPlaintext();
                const trimmed = std.mem.trim(u8, text, " \t\r\n");
                if (trimmed.len == 0) return null;
                return try gpa.dupe(u8, trimmed);
            },
            else => {},
        }
        node = node.nextSibling() orelse return null;
    }
}

test "scan.isPage" {
    try std.testing.expect(scan.isPage("a.md"));
    try std.testing.expect(scan.isPage("a.smd"));
    try std.testing.expect(!scan.isPage("a.json"));
    try std.testing.expect(!scan.isPage("readme"));
}

test "scan.isIndex" {
    try std.testing.expect(scan.isIndex("index.smd"));
    try std.testing.expect(scan.isIndex("index.md"));
    try std.testing.expect(scan.isIndex("README.md"));
    try std.testing.expect(scan.isIndex("README.smd"));
    try std.testing.expect(!scan.isIndex("other.md"));
}

test "scan.stripMdExtension" {
    try std.testing.expectEqualStrings("OTHER", scan.stripMdExtension("OTHER.md").?);
    try std.testing.expectEqualStrings("a/b", scan.stripMdExtension("a/b.md").?);
    try std.testing.expect(scan.stripMdExtension("OTHER") == null);
    // An extensionless name that merely ends in "md" is left alone.
    try std.testing.expect(scan.stripMdExtension("cmd") == null);
}

test "scan.stripDirIndex" {
    try std.testing.expectEqualStrings("dev", scan.stripDirIndex("dev/README.md").?);
    try std.testing.expectEqualStrings("a/b", scan.stripDirIndex("a/b/index.md").?);
    try std.testing.expect(scan.stripDirIndex("dev/notes.md") == null);
    try std.testing.expect(scan.stripDirIndex("dev/") == null);
    // A bare index name carries no directory, and the only directory it can
    // mean is the content root -- which is what a link climbing all the way
    // back up resolves to.
    try std.testing.expectEqualStrings("/", scan.stripDirIndex("README.md").?);
}

test "scan.resolveRelative counts the levels SuperMD dropped" {
    // SuperMD strips the first two characters of a dotted link, so what
    // reaches us for `../../x.md` is `/../x.md`. Each leading slash is a climb
    // the author wrote and SuperMD discarded.
    const climbing = scan.resolveRelative(2, "/../ref/X.md").?;
    try std.testing.expectEqual(@as(usize, 0), climbing.prefix_len);
    try std.testing.expectEqualStrings("ref/X.md", climbing.rest);

    // Climbing to the root itself.
    const to_root = scan.resolveRelative(3, "/../README.md").?;
    try std.testing.expectEqual(@as(usize, 1), to_root.prefix_len);
    try std.testing.expectEqualStrings("README.md", to_root.rest);

    // A plain `./sibling.md` loses nothing and stays put.
    const sibling = scan.resolveRelative(2, "/sibling.md").?;
    try std.testing.expectEqual(@as(usize, 1), sibling.prefix_len);
    try std.testing.expectEqualStrings("sibling.md", sibling.rest);

    // Climbing above the content root names nothing that exists.
    try std.testing.expect(scan.resolveRelative(1, "/../X.md") == null);
    try std.testing.expect(scan.resolveRelative(0, "../X.md") == null);
}

const testing = std.testing;

test "restoreClimb puts back the level SuperMD discards" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const gpa = arena_state.allocator();

    // What the author wrote, and what the renderer would otherwise emit.
    try testing.expectEqualStrings(
        "../AGENTS.md",
        try restoreClimb(gpa, "/AGENTS.md"),
    );
    try testing.expectEqualStrings(
        "../../AGENTS.md",
        try restoreClimb(gpa, "/../AGENTS.md"),
    );
    try testing.expectEqualStrings(
        "../../../examples",
        try restoreClimb(gpa, "/../../examples"),
    );
}

test "restoreClimb leaves an in-tree target alone" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const gpa = arena_state.allocator();

    // A bare relative ref never lost a level, and adding one would send the
    // reader above the site root.
    try testing.expectEqualStrings("other.md", try restoreClimb(gpa, "other.md"));
    try testing.expectEqualStrings("", try restoreClimb(gpa, ""));

    // An absolute URL is a ref that happens to start with a scheme, and a
    // fragment-only self-link has no path to restore.
    try testing.expectEqualStrings("https://x.dev/a", try restoreClimb(gpa, "https://x.dev/a"));
}

test "writeNotFound uses the site prefix, language and title" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try writeNotFound(&aw.writer, "docs", "zh-CN", "A & B");
    const html = aw.written();
    try testing.expect(std.mem.indexOf(u8, html, "lang=\"zh-CN\"") != null);
    try testing.expect(std.mem.indexOf(u8, html, "href=\"/docs/zdoc.css\"") != null);
    try testing.expect(std.mem.indexOf(u8, html, "href=\"/docs/custom.css\"") != null);
    try testing.expect(std.mem.indexOf(u8, html, "href=\"/docs/\"") != null);
    try testing.expect(std.mem.indexOf(u8, html, "Back to A &amp; B") != null);
}

test "defaultLayout picks the reading layout for an ebook" {
    try std.testing.expectEqualStrings("ebook.shtml", defaultLayout(true));
    try std.testing.expectEqualStrings("doc.shtml", defaultLayout(false));
}

test "layoutName accepts a bare name" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const gpa = arena_state.allocator();

    // Documentation is written against tools where the extension is
    // implicit; requiring it would mean an existing `layout: home` still did
    // not work.
    try testing.expectEqualStrings("home.shtml", try layoutName(gpa, "home"));
    try testing.expectEqualStrings("doc.shtml", try layoutName(gpa, "doc"));
    // An explicit extension is already a file name.
    try testing.expectEqualStrings("home.shtml", try layoutName(gpa, "home.shtml"));
    try testing.expectEqualStrings("feed.xml", try layoutName(gpa, "feed.xml"));
    try testing.expectEqualStrings("", try layoutName(gpa, ""));
}
