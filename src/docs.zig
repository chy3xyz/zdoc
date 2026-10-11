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

/// The layout used by pages that do not declare one.
pub const default_layout = "doc.shtml";

/// Files that make up the built-in documentation theme.
///
/// In docs mode the configured `layouts_dir_path` and `assets_dir_path` are
/// overridden with these two directories, and the files are materialized into
/// them before the build starts. That keeps rendering on a single code path:
/// the templates and assets are discovered by the ordinary scanning code
/// whether they came from the binary or from the user.
const theme_layout_files = [_]struct { path: []const u8, src: []const u8 }{
    .{ .path = "doc.shtml", .src = @embedFile("docs/theme/layouts/doc.shtml") },
    .{
        .path = "templates/base.shtml",
        .src = @embedFile("docs/theme/layouts/templates/base.shtml"),
    },
};

const theme_asset_files = [_]struct { path: []const u8, src: []const u8 }{
    .{ .path = "zdoc.css", .src = @embedFile("docs/theme/assets/zdoc.css") },
    .{ .path = "zdoc.js", .src = @embedFile("docs/theme/assets/zdoc.js") },
};

/// Directory the built-in theme is materialized into, relative to the base
/// directory. Dot-prefixed so it never shows up in a content scan.
pub const theme_dir = ".zdoc-theme";
pub const theme_layouts_path = ".zdoc-theme/layouts";
pub const theme_assets_path = ".zdoc-theme/assets";

/// Materializes the built-in theme so that the normal template and asset
/// scanners find it. Writes are skipped when a file already matches, so
/// repeated builds stay cheap.
pub fn installTheme(io: Io, base_dir_path: []const u8) !void {
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

    for (theme_layout_files) |f| {
        writeFile(io, layouts, f.path, f.src) catch |err| return err;
    }
    for (theme_asset_files) |f| {
        writeFile(io, assets, f.path, f.src) catch |err| return err;
    }
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

    // Reconstruct what the author wrote. Page links keep their fragment in
    // `Link.ref` rather than in the path, so both halves are needed.
    const target = switch (dir.kind) {
        .link => |lnk| blk: {
            const src = lnk.src orelse break :blk "";
            switch (src) {
                .page => |pg| {
                    if (lnk.ref) |frag| {
                        break :blk try std.fmt.allocPrint(
                            gpa,
                            "{s}#{s}",
                            .{ pg.ref, frag },
                        );
                    }
                    break :blk pg.ref;
                },
                .self_page => {
                    if (lnk.ref) |frag| break :blk try std.fmt.allocPrint(gpa, "#{s}", .{frag});
                    break :blk "";
                },
                else => break :blk "",
            }
        },
        else => "",
    };

    dir.kind = .{ .link = .{ .src = .{ .url = target } } };
    return target;
}

/// Runs every docs-mode transformation over a freshly parsed document and
/// returns the warnings that were tolerated. The caller owns the result.
///
/// Order matters: heading ids must be registered *before* parse errors are
/// filtered, because the `invalid_ref` errors were computed against an id table
/// that did not yet contain our generated slugs.
pub fn postProcess(
    gpa: std.mem.Allocator,
    ast: *supermd.Ast,
) std.mem.Allocator.Error![]supermd.Ast.Error {
    try applyHeadingIds(gpa, ast);
    return filterParseErrors(gpa, ast);
}

/// Gives every heading in the document a GitHub-compatible anchor id.
///
/// SuperMD only emits `id` attributes for headings that carry an explicit
/// directive (`# Title {#custom-id}`), which no imported Markdown uses. The
/// renderer and the TOC both read the id from that directive, so this pass is
/// what makes anchors, `$page.toc()` and `](#...)` links work at all.
///
/// The ids are also registered in `ast.ids`, because that is the table SuperMD
/// validates `#anchor` references against.
///
/// Headings that already carry a directive are left alone, so an author's
/// explicit `{#id}` always wins.
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
///   - `invalid_ref`: an `](#anchor)` whose heading does not exist. Often a
///     stale anchor left behind by an edit.
///   - `heading_skip`: `# A` followed by `### B`, skipping a level. Very common
///     in real documentation.
///   - `inline_html`: raw HTML in the body. Only a couple of lines in practice.
///   - `no_alt_in_links`: a reference-style link written as `[text][1]`, which
///     supermd requires to be spelled `.alt()` instead. This is ordinary
///     Markdown that a documentation author never chose against.
pub fn isToleratedParseError(kind: supermd.Ast.Error.Kind) bool {
    return switch (kind) {
        .invalid_ref, .heading_skip, .inline_html, .no_alt_in_links => true,
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
pub const scan = struct {
    /// Returns true when the filename should become a page rather than an
    /// asset. `.smd` is Zine's own dialect; `.md` is what everyone else writes.
    pub fn isPage(name: []const u8) bool {
        if (std.mem.endsWith(u8, name, ".smd")) return true;
        if (std.mem.endsWith(u8, name, ".md")) return true;
        return false;
    }

    /// Returns true when the filename is the index page of its directory.
    ///
    /// In blog mode only `index.smd` qualifies. In docs mode `README.md` does
    /// too, which is what makes `README.md` map to `/` and gives directories
    /// like `dev/` a section index without the author having to create one.
    pub fn isIndex(name: []const u8) bool {
        return std.mem.eql(u8, name, "index.smd") or
            std.mem.eql(u8, name, "index.md") or
            std.mem.eql(u8, name, "README.smd") or
            std.mem.eql(u8, name, "README.md");
    }

    /// Strips a trailing `.md` from a link target so that `[x](OTHER.md)`
    /// resolves the same way `[x](OTHER)` does. Markdown documents almost
    /// always link with the extension, but Zine interns page URLs without it.
    pub fn stripMdExtension(ref: []const u8) ?[]const u8 {
        if (!std.mem.endsWith(u8, ref, ".md")) return null;
        return ref[0 .. ref.len - ".md".len];
    }

    /// Maps `dir/README.md` (or `dir/index.md`) onto `dir`, which is the url of
    /// a directory's index page. Returns null when the ref does not name a
    /// directory index.
    pub fn stripDirIndex(ref: []const u8) ?[]const u8 {
        if (std.mem.endsWith(u8, ref, "/")) return null;
        const sep = std.mem.lastIndexOfScalar(u8, ref, '/') orelse return null;
        if (!isIndex(ref[sep + 1 ..])) return null;
        const dir = ref[0..sep];
        return if (dir.len == 0) "/" else dir;
    }
};

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
    try std.testing.expect(scan.stripDirIndex("README.md") == null);
    try std.testing.expect(scan.stripDirIndex("dev/") == null);
}