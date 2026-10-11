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
    /// CSS class carrying the indentation. Precomputed so the theme can
    /// apply it with a plain `class="$loop.it.class"` attribute instead of
    /// needing string interpolation.
    class: []const u8,

    const Class = struct {
        const d0 = "sidebar__item sidebar__item--d0";
        const d1 = "sidebar__item sidebar__item--d1";
        const d2 = "sidebar__item sidebar__item--d2";
        const d3 = "sidebar__item sidebar__item--d3";
    };

    fn init(title: []const u8, page: ?*const Page, depth: u16, is_dir: bool) Item {
        return .{
            .title = title,
            .page = page,
            .depth = depth,
            .is_link = page != null,
            .is_dir = is_dir,
            // Deeper levels clamp so the theme needs no unbounded class list.
            .class = switch (depth) {
                0 => Class.d0,
                1 => Class.d1,
                2 => Class.d2,
                else => Class.d3,
            },
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
    std.mem.sort(Path, dir.dirs.items, v, struct {
        fn lessThan(ctx: *const Variant, lhs: Path, rhs: Path) bool {
            return std.mem.lessThan(
                u8,
                dirName(ctx, lhs),
                dirName(ctx, rhs),
            );
        }
    }.lessThan);

    std.mem.sort(*const Page, dir.pages.items, v, struct {
        fn lessThan(ctx: *const Variant, lhs: *const Page, rhs: *const Page) bool {
            _ = ctx;
            if (std.mem.eql(u8, lhs.title, rhs.title)) {
                return lhs._scan.page_id < rhs._scan.page_id;
            }
            return std.mem.lessThan(u8, lhs.title, rhs.title);
        }
    }.lessThan);

    // Directories first: readers look for the section, then the page.
    for (dir.dirs.items) |child_path| {
        const child = dirs.get(child_path) orelse continue;
        try out.append(arena, Item.init(child.name, child.index_page, depth, true));
        try flatten(arena, v, dirs, child, depth + 1, out);
    }

    for (dir.pages.items) |p| {
        try out.append(arena, Item.init(p.title, p, depth, false));
    }
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
