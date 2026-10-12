//! Keeping pages out of a documentation site.
//!
//! A docs tree usually holds more than it should publish. Design notes,
//! meeting minutes, an `archive/` of last quarter's plans -- these belong in
//! version control and not on the website, but the sidebar is derived from
//! the directory tree and has no way to know that.
//!
//! Two ways to say so, matching how the rest of docs mode is configured:
//!
//!   - `exclude: true` in a page's frontmatter. On a directory's index page
//!     it removes the whole section. This is the convention-over-config
//!     answer: the intent lives next to the thing it applies to, so a new
//!     contributor sees it by opening the file.
//!   - `--exclude <glob>` on the command line, repeatable, for a site that
//!     would rather not edit its own content -- building someone else's
//!     repository, or previewing a subset of a large tree.
//!
//! Both remove a page entirely: no HTML, no sitemap entry, no search record,
//! no sidebar entry. That is the difference from `hidden`, which keeps a page
//! reachable by URL and only takes it out of the sidebar.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Variant = @import("../Variant.zig");
const PathTable = @import("../PathTable.zig");
const context = @import("../context.zig");
const Page = context.Page;

/// What a build was told to leave out.
pub const Rules = struct {
    /// Globs from `--exclude`, matched against a page's path relative to the
    /// content directory, with `/` separators.
    globs: []const []const u8 = &.{},

    pub fn isEmpty(rules: Rules) bool {
        return rules.globs.len == 0;
    }
};

/// Marks every page that should not be built as inactive.
///
/// A page is excluded when its own frontmatter says so, when a glob matches
/// it, or when a directory above it is excluded -- which is what makes
/// `exclude: true` on a section index remove the whole section.
///
/// Returns the number of pages excluded, for the build summary.
pub fn apply(
    gpa: Allocator,
    v: *Variant,
    rules: Rules,
) error{ OutOfMemory, WriteFailed }!usize {
    var excluded: usize = 0;

    for (v.pages.items) |*p| {
        if (!p._parse.active) continue;

        var drop = p.exclude;

        if (!drop and !rules.isEmpty()) {
            const src = try p.sourcePath(gpa, v);
            defer gpa.free(src);
            for (rules.globs) |g| {
                if (try matches(gpa, g, src)) {
                    drop = true;
                    break;
                }
            }
        }

        if (!drop and try hasExcludedAncestor(gpa, v, p)) drop = true;

        if (drop) {
            p._parse.active = false;
            excluded += 1;
        }
    }

    return excluded;
}

/// Whether any directory index above `p` is excluded.
///
/// Walks the page's own path rather than following parent pointers, because
/// the scanner does not keep them and a docs tree is shallow.
fn hasExcludedAncestor(
    gpa: Allocator,
    v: *const Variant,
    p: *const Page,
) Allocator.Error!bool {
    // The prefix buffer is a plain list of interned components.
    const components = p._scan.url.slice(&v.path_table);
    // One component is the page's own name, so there is nothing above it.
    if (components.len < 2) return false;

    const dir = components[0 .. components.len - 1];
    var prefix: std.ArrayListUnmanaged(@import("../StringTable.zig").String) = .empty;
    defer prefix.deinit(gpa);

    for (0..dir.len) |n| {
        prefix.clearRetainingCapacity();
        try prefix.appendSlice(gpa, dir[0 .. n + 1]);
        const path = v.path_table.get(prefix.items) orelse continue;
        if (indexPageOf(v, path)) |i| {
            if (v.pages.items[i].exclude) return true;
        }
    }
    return false;
}

/// The page that serves as `path`'s index, if it has one.
///
/// A page whose URL is a directory *is* that directory's index, which is how
/// `dev/README.md` becomes `/dev/`.
fn indexPageOf(v: *const Variant, path: PathTable.Path) ?usize {
    for (v.pages.items, 0..) |p, i| {
        if (p._scan.subsection_id == 0) continue;
        if (v.sections.items[p._scan.subsection_id].index != p._scan.page_id) continue;
        if (p._scan.url == path) return i;
    }
    return null;
}

/// Whether `path` matches a glob, anchored at both ends.
///
/// Matching is per path segment, which is what makes the patterns behave the
/// way people expect from an ignore file: `*` and `?` stop at a `/`, so `dev/*`
/// covers `dev/notes.md` but not `dev/sub/notes.md`, and only `**` crosses
/// directories. A pattern must cover the whole path, so `dev` does not exclude
/// `device/`.
pub fn matches(
    gpa: Allocator,
    pattern: []const u8,
    path: []const u8,
) Allocator.Error!bool {
    var pats: std.ArrayListUnmanaged([]const u8) = .empty;
    defer pats.deinit(gpa);
    var segs: std.ArrayListUnmanaged([]const u8) = .empty;
    defer segs.deinit(gpa);

    var it = std.mem.splitScalar(u8, pattern, '/');
    while (it.next()) |seg| try pats.append(gpa, seg);
    var pit = std.mem.splitScalar(u8, path, '/');
    while (pit.next()) |seg| try segs.append(gpa, seg);

    return matchSegs(pats.items, 0, segs.items, 0);
}

fn matchSegs(pats: []const []const u8, pi: usize, segs: []const []const u8, si: usize) bool {
    if (pi == pats.len) return si == segs.len;
    if (pats[pi].len == 2 and pats[pi][0] == '*' and pats[pi][1] == '*') {
        // `**` matches any number of segments, including none.
        var n = si;
        while (true) {
            if (matchSegs(pats, pi + 1, segs, n)) return true;
            if (n == segs.len) return false;
            n += 1;
        }
    }

    if (si == segs.len) return false;
    if (!matchSeg(pats[pi], segs[si])) return false;
    return matchSegs(pats, pi + 1, segs, si + 1);
}

/// Single-segment glob: `*` and `?` match any run or single character.
fn matchSeg(pat: []const u8, seg: []const u8) bool {
    var p: usize = 0;
    var s: usize = 0;
    var star: ?usize = null;
    var star_s: usize = 0;

    while (s < seg.len) {
        if (p < pat.len and (pat[p] == '?' or pat[p] == seg[s])) {
            p += 1;
            s += 1;
            continue;
        }
        if (p < pat.len and pat[p] == '*') {
            star = p;
            star_s = s;
            p += 1;
            continue;
        }
        if (star) |sp| {
            // Let the last `*` swallow one more character and retry.
            p = sp + 1;
            star_s += 1;
            s = star_s;
            continue;
        }
        return false;
    }

    while (p < pat.len and pat[p] == '*') p += 1;
    return p == pat.len;
}

const testing = std.testing;

fn yes(comptime pattern: []const u8, comptime path: []const u8) !void {
    try testing.expect(try matches(testing.allocator, pattern, path));
}

fn no(comptime pattern: []const u8, comptime path: []const u8) !void {
    try testing.expect(!try matches(testing.allocator, pattern, path));
}

test "a literal pattern is anchored at both ends" {
    try yes("dev", "dev");
    // `dev` is a prefix of `device`, and a pattern that merely starts
    // matching would quietly exclude directories it was never meant to.
    try no("dev", "device");
    try no("dev", "a/dev");
    try no("dev", "dev/notes.md");
}

test "star stays inside one segment" {
    try yes("dev/*.md", "dev/notes.md");
    try no("dev/*.md", "dev/sub/notes.md");
    try yes("*.md", "notes.md");
}

test "double star crosses directories" {
    try yes("dev/**", "dev/sub/notes.md");
    try yes("dev/**", "dev/notes.md");
    try yes("**/notes.md", "a/b/notes.md");
}

test "a directory name alone does not exclude its contents" {
    // `dev` names the page `dev/README.md`. Removing the section needs the
    // explicit `dev/**` or `exclude: true` on the index, so that excluding one
    // page never takes a section with it by accident.
    try no("dev", "dev/notes.md");
    try yes("dev/**", "dev/notes.md");
}

test "question mark matches exactly one character" {
    try yes("?.md", "a.md");
    try no("?.md", "ab.md");
}

test "matchSeg backtracks across multiple stars" {
    try testing.expect(matchSeg("a*b*c", "axxbyyc"));
    try testing.expect(!matchSeg("a*b*c", "axxbyy"));
    try testing.expect(matchSeg("*.md", "readme.md"));
    try testing.expect(matchSeg("*", ""));
    try testing.expect(matchSeg("**", "anything"));
}
