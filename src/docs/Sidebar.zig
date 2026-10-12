//! Builds the documentation sidebar from the content tree.
//!
//! VitePress derives its sidebar from the directory structure, so this does
//! too: every page's URL path determines where it sits in the tree, and
//! directories become groups. There is no configuration to read.
//!
//! The result is a *flat* list annotated with a depth rather than a nested
//! structure. SuperHTML has no recursion, so a flat list rendered with
//! indentation is what the template can actually express, and it keeps the
//! template to a single `:loop`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const context = @import("../context.zig");
const Page = context.Page;
const Variant = @import("../Variant.zig");
const PathTable = @import("../PathTable.zig");
const Path = PathTable.Path;
const StringTable = @import("../StringTable.zig");
const Value = context.Value;
const String = context.String;
const Optional = context.Optional;
const Signature = context.Signature;

/// One entry in the sidebar: either a link to a page, or a heading for a
/// directory that has no index page to link to.
pub const Item = struct {
    title: []const u8,
    /// The page this entry links to, if any. A directory without a
    /// `README.md`/`index.md` has none and renders as a plain label.
    page: ?*const Page,
    /// Nesting level, 0 for entries directly under the content root.
    depth: u16,
    /// True when this entry links somewhere. A directory with no
    /// `README.md`/`index.md` has no page and renders as a plain label.
    is_link: bool,
    is_dir: bool,
    /// CSS class carrying the entry's kind and its indentation.
    ///
    /// Precomputed in full because the template language cannot concatenate:
    /// `class="sidebar__section--$loop.it.depth"` does not parse, so the whole
    /// value has to be chosen here.
    class: []const u8,

    /// A section heading, a section with no page to link to, and a page are
    /// three different things visually, and a flat list carrying only an
    /// indent cannot tell a reader which is which.
    const Class = struct {
        const section = [_][]const u8{
            "sidebar__section sidebar__section--d0",
            "sidebar__section sidebar__section--d1",
            "sidebar__section sidebar__section--d2",
            "sidebar__section sidebar__section--d3",
        };
        const label = [_][]const u8{
            "sidebar__label sidebar__label--d0",
            "sidebar__label sidebar__label--d1",
            "sidebar__label sidebar__label--d2",
            "sidebar__label sidebar__label--d3",
        };
        const item = [_][]const u8{
            "sidebar__item sidebar__item--d0",
            "sidebar__item sidebar__item--d1",
            "sidebar__item sidebar__item--d2",
            "sidebar__item sidebar__item--d3",
        };
    };

    fn init(title: []const u8, page: ?*const Page, depth: u16, is_dir: bool) Item {
        // Deeper levels clamp so the theme needs no unbounded class list.
        const slot = @min(depth, 3);
        return .{
            .title = title,
            .page = page,
            .depth = depth,
            .is_link = page != null,
            .is_dir = is_dir,
            .class = if (is_dir)
                (if (page != null) Class.section[slot] else Class.label[slot])
            else
                Class.item[slot],
        };
    }

    // ---- SuperHTML type interface ----

    pub const Dot = true;

    pub const Fields = struct {
        pub const title =
            \\The label shown for this sidebar entry.
        ;
        pub const depth =
            \\Nesting level, 0 for entries directly under the content root.
        ;
        pub const is_dir =
            \\True when this entry is a directory rather than a page.
        ;
        pub const is_link =
            \\True when this entry links to a page. Directories without an
            \\index page render as a plain label instead.
        ;
        pub const class =
            \\CSS classes for this entry, including the indentation level.
        ;
    };

    pub const Builtins = struct {
        pub const link = struct {
            pub const signature: Signature = .{ .ret = .String };
            pub const docs_description =
                \\The URL of the page this entry links to.
                \\
                \\Only meaningful for entries that have a page.
            ;
            pub const examples =
                \\<a href="$loop.it.link()" :text="$loop.it.title"></a>
            ;
            pub fn call(
                item: Item,
                gpa: Allocator,
                ctx: *const context.Root,
                args: []const Value,
            ) context.CallError!Value {
                if (args.len != 0) return .{ .err = "expected 0 arguments" };
                const page = item.page orelse {
                    return .{ .err = "this sidebar entry has no page" };
                };
                const v = &ctx._meta.build.variants[page._scan.variant_id];

                var aw: Writer.Allocating = .init(gpa);
                ctx.printLinkPrefix(&aw.writer, page._scan.variant_id, false) catch
                    return error.OutOfMemory;
                aw.writer.print("{f}", .{page._scan.url.fmt(
                    &v.string_table,
                    &v.path_table,
                    null,
                    true,
                )}) catch return error.OutOfMemory;
                return String.init(aw.written());
            }
        };
    };
};

/// A directory in the content tree, used only while building.
const Dir = struct {
    path: Path,
    name: []const u8,
    /// The `README.md`/`index.md` page for this directory, when it has one.
    index_page: ?*const Page = null,
    pages: std.ArrayListUnmanaged(*const Page) = .empty,
    dirs: std.ArrayListUnmanaged(Path) = .empty,
};

/// Builds the sidebar for one variant, using `arena` for the result.
pub fn build(
    arena: Allocator,
    v: *const Variant,
) Allocator.Error![]Item {
    // Map every directory path that exists to its node. Directories are
    // discovered as parents of page URLs, so a folder holding only
    // subfolders still shows up.
    var dirs: std.AutoHashMapUnmanaged(Path, *Dir) = .empty;
    const root_dir = try arena.create(Dir);
    root_dir.* = .{ .path = @enumFromInt(0), .name = "" };
    try dirs.put(arena, @as(Path, @enumFromInt(0)), root_dir);

    for (v.pages.items) |*p| {
        if (!p._parse.active) continue;

        const components = p._scan.url.slice(&v.path_table);
        if (components.len == 0) continue; // the root index is the sidebar root

        // All but the last component is the containing directory.
        const parent_components = components[0 .. components.len - 1];
        const parent = try ensureDir(arena, v, &dirs, parent_components);

        // A page whose URL equals the directory it lives in is that
        // directory's index page (`dev/README.md` is the index of `dev/`),
        // not an extra leaf.
        const is_index = blk: {
            const sid = p._scan.subsection_id;
            if (sid == 0) break :blk false;
            break :blk v.sections.items[sid].index == p._scan.page_id;
        };

        if (is_index) {
            const dir = try ensureDir(arena, v, &dirs, components);
            dir.index_page = p;
        } else {
            try parent.pages.append(arena, p);
        }
    }

    var out: std.ArrayList(Item) = .empty;
    try flatten(arena, v, &dirs, root_dir, 0, &out);
    return out.toOwnedSlice(arena);
}

/// Finds or creates the directory node for `components`, creating any missing
/// ancestors along the way.
fn ensureDir(
    arena: Allocator,
    v: *const Variant,
    dirs: *std.AutoHashMapUnmanaged(Path, *Dir),
    components: []const StringTable.String,
) Allocator.Error!*Dir {
    // Every directory we care about is the URL of some page, so all of these
    // paths are already interned; look them up rather than creating new ones.
    var prefix: std.ArrayListUnmanaged(StringTable.String) = .empty;
    defer prefix.deinit(arena);

    var path: Path = @enumFromInt(0);
    for (components) |comp| {
        try prefix.append(arena, comp);
        path = v.path_table.get(prefix.items) orelse return error.OutOfMemory;

        const gop = try dirs.getOrPut(arena, path);
        if (!gop.found_existing) {
            const dir = try arena.create(Dir);
            dir.* = .{
                .path = path,
                .name = comp.slice(&v.string_table),
            };
            gop.value_ptr.* = dir;

            // Link it into its parent so the walk can find it. The parent is
            // the entry for the prefix without the last component, which was
            // created on the previous iteration (or is the root).
            const parent_path = if (prefix.items.len == 1)
                @as(Path, @enumFromInt(0))
            else
                v.path_table.get(prefix.items[0 .. prefix.items.len - 1]) orelse
                    return error.OutOfMemory;
            const parent_dir = dirs.get(parent_path) orelse return error.OutOfMemory;
            try parent_dir.dirs.append(arena, path);
        }
    }

    return dirs.get(path) orelse return error.OutOfMemory;
}

/// Ordering state for a directory's children.
///
/// The comparator needs both the variant (to read names) and the directory map
/// (to find the index page that carries `order`), and `std.mem.sort` takes a
/// single context, so they are bundled here.
const SectionSort = struct {
    v: *const Variant,
    dirs: *const std.AutoHashMapUnmanaged(Path, *Dir),

    /// A section's sort position. Sections that set no `order` sort after
    /// every section that does, so adding one never reshuffles the rest of
    /// the sidebar into an arbitrary arrangement.
    fn orderOf(ctx: *const SectionSort, path: Path) i64 {
        const d = ctx.dirs.get(path) orelse return no_section_order;
        const index = d.index_page orelse return no_section_order;

        // A page that never set `order` carries the type's sentinel, which is
        // the *smallest* integer -- so returning it directly would put every
        // unordered section at the top of the sidebar rather than the bottom.
        if (index.order == Page.no_order) return no_section_order;
        return index.order;
    }
};

/// Sort position for a section that declares no `order` of its own.
///
/// Sections that set an order come first, in the order given; the rest follow
/// alphabetically. That way setting `order` on one section moves it without
/// forcing every other section to be numbered too.
const no_section_order: i64 = std.math.maxInt(i64);

/// The last component of a directory path, which is its display name.
fn dirName(v: *const Variant, path: Path) []const u8 {
    const components = path.slice(&v.path_table);
    if (components.len == 0) return "";
    return components[components.len - 1].slice(&v.string_table);
}

/// Emits one directory and everything under it, depth-first.
fn flatten(
    arena: Allocator,
    v: *const Variant,
    dirs: *std.AutoHashMapUnmanaged(Path, *Dir),
    dir: *Dir,
    depth: u16,
    out: *std.ArrayList(Item),
) Allocator.Error!void {
    // Scan order is whatever the filesystem yielded, which is not something a
    // reader can navigate, so sort each group by the label that is shown.
    //
    // A numeric prefix orders the group the way the author wrote it --
    // `01-guide/` before `02-api/` -- so the sort has to read it as a number.
    // Byte order would put `10-` before `2-`, which is exactly the outcome the
    // prefix was written to avoid.
    // A section's position comes from its index page's `order` when it sets
    // one, and from its name otherwise.
    //
    // This is the escape hatch for a site that cannot rename its
    // directories. The numeric-prefix convention also orders sections, but
    // adopting it means `guide/` becomes `01-guide/`, which changes the
    // directory's URL and breaks every link to it. `order` costs nothing that
    // is already published.
    const sort_ctx: SectionSort = .{ .v = v, .dirs = dirs };
    std.mem.sort(Path, dir.dirs.items, &sort_ctx, struct {
        fn lessThan(ctx: *const SectionSort, lhs: Path, rhs: Path) bool {
            const l = ctx.orderOf(lhs);
            const r = ctx.orderOf(rhs);
            if (l != r) return l < r;
            return naturalLess(dirName(ctx.v, lhs), dirName(ctx.v, rhs));
        }
    }.lessThan);

    std.mem.sort(*const Page, dir.pages.items, v, struct {
        fn lessThan(ctx: *const Variant, lhs: *const Page, rhs: *const Page) bool {
            _ = ctx;
            // `order` is the one thing a frontmatter can say about order; when
            // it is absent the title decides, as it always did.
            if (lhs.order != rhs.order) return lhs.order < rhs.order;
            if (std.mem.eql(u8, lhs.title, rhs.title)) {
                return lhs._scan.page_id < rhs._scan.page_id;
            }
            return naturalLess(lhs.title, rhs.title);
        }
    }.lessThan);

    // Directories first: readers look for the section, then the page.
    for (dir.dirs.items) |child_path| {
        const child = dirs.get(child_path) orelse continue;

        // A section whose index page is hidden leaves the sidebar entirely,
        // children included. Hiding only the index would leave a section
        // label with no page behind it, which reads as a broken link rather
        // than as an author hiding a draft.
        //
        // This is the difference from `exclude`, which also stops the pages
        // being built: `hidden` is for something still worth publishing at a
        // URL, `exclude` is for something that should not be published at all.
        if (child.index_page) |ip| {
            if (ip.hidden) continue;
        }

        // A directory's index page titles the section far better than the
        // directory name does: `ai/` holds a README whose H1 explains what the
        // section is for. Only fall back to the directory name when there is
        // no index page to ask.
        const label = if (child.index_page) |ip| ip.title else child.name;
        try out.append(arena, Item.init(label, child.index_page, depth, true));
        try flatten(arena, v, dirs, child, depth + 1, out);
    }

    for (dir.pages.items) |p| {
        if (p.hidden) continue;
        try out.append(arena, Item.init(p.title, p, depth, false));
    }
}

/// Compares two labels the way a reader expects a list of them to read.
///
/// Leading digit runs compare as numbers, so `2-foo` precedes `10-foo`. Only
/// the leading run is numeric -- an author writing `01-guide/` means to order
/// the directory, not to renumber the words after it.
fn naturalLess(lhs: []const u8, rhs: []const u8) bool {
    const l_digits = digitRun(lhs);
    const r_digits = digitRun(rhs);

    if (l_digits > 0 and r_digits > 0) {
        // Skip leading zeros so `01` and `1` order the same, then compare by
        // length first: fewer digits is the smaller number.
        const l_trim = trimZeros(lhs[0..l_digits]);
        const r_trim = trimZeros(rhs[0..r_digits]);
        if (l_trim.len != r_trim.len) return l_trim.len < r_trim.len;
        if (std.mem.order(u8, l_trim, r_trim) == .lt) return true;
        if (std.mem.order(u8, l_trim, r_trim) == .gt) return false;
    }

    return std.mem.lessThan(u8, lhs, rhs);
}

fn digitRun(s: []const u8) usize {
    var i: usize = 0;
    while (i < s.len and std.ascii.isDigit(s[i])) i += 1;
    return i;
}

fn trimZeros(s: []const u8) []const u8 {
    var i: usize = 0;
    while (i + 1 < s.len and s[i] == '0') i += 1;
    return s[i..];
}

const testing = std.testing;

test "Item.class encodes the nesting depth" {
    try testing.expectEqualStrings(
        "sidebar__item sidebar__item--d0",
        Item.init("a", null, 0, false).class,
    );
    try testing.expectEqualStrings(
        "sidebar__item sidebar__item--d2",
        Item.init("a", null, 2, false).class,
    );
    // Deeper levels clamp so the theme needs no unbounded class list.
    try testing.expectEqualStrings(
        "sidebar__item sidebar__item--d3",
        Item.init("a", null, 9, false).class,
    );
}

test "naturalLess reads a numeric prefix as a number" {
    // The whole point of the convention: byte order gets this backwards.
    try testing.expect(naturalLess("02-api", "10-operations"));
    try testing.expect(!naturalLess("10-operations", "02-api"));

    // Leading zeros do not change the value, so `01` and `1` tie and the
    // remaining bytes decide.
    try testing.expect(naturalLess("01-guide", "02-api"));

    // Differing digit counts compare by magnitude.
    try testing.expect(naturalLess("2-foo", "10-foo"));
    try testing.expect(!naturalLess("10-foo", "2-foo"));

    // Plain labels still sort alphabetically.
    try testing.expect(naturalLess("apple", "banana"));
    try testing.expect(!naturalLess("banana", "apple"));

    // A label with no digits at the front sorts after one that has them,
    // rather than being compared digit-run against nothing.
    try testing.expect(naturalLess("1-a", "b"));
}
