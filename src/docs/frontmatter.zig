//! A minimal YAML-subset frontmatter reader for documentation mode.
//!
//! Documentation written for GitHub or VitePress carries YAML frontmatter, so
//! a docs-mode page that starts with `---` almost always has YAML in it.
//! Rejecting that would be catastrophic rather than merely inconvenient: a
//! single unparseable page aborts the whole build, taking every other page
//! down with it.
//!
//! This parser therefore never fails. It reads the handful of shapes that
//! carry meaning for a documentation site and silently skips everything else,
//! recording a warning for the constructs it did not understand. A construct
//! it skips is a construct the author gets to keep as prose, not a build
//! break.
//!
//! Supported:
//!   - `key: value` scalars, with optional single or double quotes
//!   - `key:` followed by a `- item` list
//!   - `key:` followed by an indented block, folded into one string
//!   - `#` comments and blank lines
//!
//! Deliberately skipped, and never fatal: anchors (`&x`), aliases (`*x`), flow
//! collections (`{a, b}`, `[a, b]`), and tab indentation.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Signature = @import("../context/doctypes.zig").Signature;
const Value = @import("../context.zig").Value;

/// One entry of a `hero.actions` list.
pub const Action = struct {
    text: []const u8 = "",
    link: []const u8 = "",
    theme: []const u8 = "alt",

    pub const Dot = true;

    pub const Fields = struct {
        pub const text =
            \\The label on the button.
        ;
        pub const theme =
            \\Either 'brand' or 'alt', selecting the button's emphasis.
        ;
    };

    pub const Builtins = struct {
        pub const link = struct {
            pub const signature: Signature = .{ .ret = .String };

            pub const docs_description =
                \\The URL the button points at.
                \\
                \\A link into the docs tree is resolved to the page it names,
                \\and anything else is emitted as written, so both a page
                \\reference and an external URL work here.
            ;

            pub const examples =
                \\<a href="$loop.it.link()">Read the docs</a>
            ;

            pub fn call(
                a: Action,
                gpa: Allocator,
                ctx: *const @import("../context.zig").Root,
                args: []const Value,
            ) @import("../context.zig").CallError!Value {
                if (args.len != 0) return .{ .err = "expected 0 arguments" };

                var aw: std.Io.Writer.Allocating = .init(gpa);

                // A hero link is written by hand and may point at another page
                // in the docs, or at anything on the web. An absolute URL is
                // emitted exactly as written -- prefixing one would corrupt it.
                if (isAbsoluteUrl(a.link)) {
                    aw.writer.writeAll(a.link) catch return error.OutOfMemory;
                    return String.init(aw.written());
                }

                // Resolve a link into the docs tree against the content. A
                // link that names no page is emitted as the path it was
                // written as, so a stale reference reads as a broken path
                // rather than as a doubled slash.
                if (resolveHeroPage(ctx, a.link)) |p| {
                    ctx.printLinkPrefix(&aw.writer, ctx.site._meta.variant_id, false) catch
                        return error.OutOfMemory;
                    const v = &ctx._meta.build.variants[ctx.site._meta.variant_id];
                    aw.writer.print("{f}", .{p._scan.url.fmt(
                        &v.string_table,
                        &v.path_table,
                        null,
                        true,
                    )}) catch return error.OutOfMemory;
                    return String.init(aw.written());
                }

                aw.writer.writeAll(a.link) catch return error.OutOfMemory;
                return String.init(aw.written());
            }
        };
    };
};

/// Whether `link` is a URL in its own right, rather than a path into the docs
/// tree.
///
/// The distinction matters twice over: an absolute URL must not be prefixed
/// with the site's URL path, and it must not be looked up in the content tree
/// either. The awkward case is a leading `//`, which is a protocol-relative
/// URL in a browser but is far more often here a docs path written with a
/// doubled slash, so it counts as absolute only when a host follows it.
fn isAbsoluteUrl(link: []const u8) bool {
    if (std.mem.startsWith(u8, link, "//")) {
        const after = link["//".len..];
        const host_len = std.mem.indexOfAny(u8, after, "/?#") orelse after.len;
        return host_len > 0;
    }

    if (std.mem.indexOf(u8, link, "://")) |i| {
        // `://` only introduces a scheme when the text before it is a scheme:
        // a path is allowed to contain `:` and `/` without being a URL.
        for (link[0..i]) |c| {
            if (!std.ascii.isAlphanumeric(c) and c != '+' and c != '-' and c != '.') return false;
        }
        return i > 0;
    }

    // A single-letter scheme has no `//` to find, so check the common ones
    // by name rather than guessing at a colon.
    for ([_][]const u8{ "mailto:", "tel:", "data:", "ftp:" }) |scheme| {
        if (std.mem.startsWith(u8, link, scheme)) return true;
    }

    return false;
}

/// Finds the content page a hero action's `link:` names, if any.
///
/// Hero links are written as paths into the docs tree -- `/README`,
/// `/guide/QUICK-START` -- matching how a VitePress home page spells them. The
/// leading slash is the site's root, not a filesystem root, so it is stripped
/// before the lookup.
///
/// `README` and `index` name the site root, whose URL is `/` and whose interned
/// path is empty. Nothing else resolves to it, so it is matched by name here
/// rather than by path.
fn resolveHeroPage(
    ctx: *const @import("../context.zig").Root,
    link: []const u8,
) ?*const PageT {
    const v = &ctx._meta.build.variants[ctx.site._meta.variant_id];
    const index_html: STString = @enumFromInt(11);
    std.debug.assert(v.string_table.get("index.html") == index_html);

    const ref = std.mem.trim(u8, std.mem.trimStart(u8, link, "/"), "/");
    if (ref.len == 0) return null;

    if (std.mem.eql(u8, ref, "README") or std.mem.eql(u8, ref, "README.md") or
        std.mem.eql(u8, ref, "index") or std.mem.eql(u8, ref, "index.md"))
    {
        return &v.pages.items[v.root_index];
    }

    const path = v.path_table.getPathNoName(&v.string_table, &.{}, ref) orelse return null;
    const pn: PathName = .{ .path = path, .name = index_html };
    const hint = v.urls.get(pn) orelse return null;
    if (hint.kind != .page_main) return null;
    return &v.pages.items[hint.id];
}

const String = @import("../context.zig").String;
const PageT = @import("../context.zig").Page;
const STString = @import("../StringTable.zig").String;
const PathName = @import("../PathTable.zig").PathName;

/// The `hero` block of a home page.
pub const Hero = struct {
    name: []const u8 = "",
    text: []const u8 = "",
    tagline: []const u8 = "",
    image: ?[]const u8 = null,
    actions: []const Action = &.{},

    /// True when the document actually spelled out a `hero` block. A page may
    /// legitimately declare an empty one, and the template needs to tell that
    /// apart from having no hero at all.
    present: bool = false,

    pub const Dot = true;

    pub const Fields = struct {
        pub const name =
            \\The product or project name shown as the hero headline.
        ;
        pub const text =
            \\The one-line pitch shown under the name.
        ;
        pub const tagline =
            \\The longer description shown under the pitch.
        ;
        pub const present =
            \\True when the frontmatter declared a hero block at all.
        ;
    };

    /// The hero's call-to-action buttons. Defined here rather than on the
    /// template side because this is the only place that knows what an action
    /// is; the layout just loops over them.
    pub const Builtins = struct {
        pub const actions = struct {
            pub const signature: Signature = .{ .ret = .{ .Many = .Value } };

            pub const docs_description =
                \\The call-to-action buttons of a home page hero, each with
                \\a `text`, a `link()` and a `theme` of 'brand' or 'alt'.
            ;

            pub const examples =
                \\<a :loop="$page.hero.actions()"
                \\   class="hero__action hero__action--$loop.it.theme"
                \\   href="$loop.it.link()"
                \\   :text="$loop.it.text"></a>
            ;

            pub fn call(
                h: Hero,
                gpa: Allocator,
                ctx: *const @import("../context.zig").Root,
                args: []const Value,
            ) @import("../context.zig").CallError!Value {
                _ = ctx;
                if (args.len != 0) return .{ .err = "expected 0 arguments" };

                const list = try gpa.alloc(Value, h.actions.len);
                for (h.actions, 0..) |a, i| list[i] = .{ .hero_action = a };
                return @import("../context.zig").Array.init(gpa, Value, list);
            }
        };
    };
};

/// One entry of a `features` list.
pub const Feature = struct {
    title: []const u8 = "",
    details: []const u8 = "",
    icon: ?[]const u8 = null,

    pub const Dot = true;

    pub const Fields = struct {
        pub const title =
            \\The card's heading.
        ;
        pub const details =
            \\The card's body text.
        ;
    };

    // A feature card is plain data; there is nothing to compute from it.
    pub const Builtins = struct {};
};

/// A construct the parser saw but did not read.
pub const Skipped = struct {
    /// 1-based line within the frontmatter block. Approximate when the
    /// construct spanned several lines: it points at the last one.
    line: usize,
    construct: Construct,

    pub const Construct = enum {
        anchor,
        alias,
        flow_collection,
        tab_indent,
        unterminated_quote,
        document_marker,
        nested_under_scalar,
    };

    pub fn explain(c: Construct) []const u8 {
        return switch (c) {
            .anchor => "frontmatter anchor (&name) was ignored",
            .alias => "frontmatter alias (*name) was ignored",
            .flow_collection => "frontmatter inline collection ({...} / [...]) was ignored",
            .tab_indent => "frontmatter line is indented with a tab, which YAML does not allow",
            .unterminated_quote => "frontmatter value has an unterminated quote",
            .document_marker => "frontmatter contains a '---' line, which ends the block early",
            .nested_under_scalar => "frontmatter scalar has an indented block under it, which was ignored",
        };
    }
};

/// Everything documentation mode understands from a frontmatter block.
///
/// Every field is optional, which is the point: a page is expected to have no
/// frontmatter at all and to fall back to its first H1 for a title.
pub const Fields = struct {
    title: ?[]const u8 = null,
    description: ?[]const u8 = null,
    layout: ?[]const u8 = null,
    draft: ?bool = null,
    order: ?i64 = null,
    hidden: ?bool = null,
    /// When true the page is not built at all. On a directory's index page
    /// this also removes the whole section below it.
    exclude: ?bool = null,
    nav: ?bool = null,
    tags: []const []const u8 = &.{},
    hero: Hero = .{},
    features: []const Feature = &.{},

    pub fn has(_: Fields, key: []const u8) bool {
        const known = [_][]const u8{
            "title",  "description", "layout", "draft",
            "order",  "hidden",      "exclude", "nav",   "tags",
        };
        for (known) |k| {
            if (std.mem.eql(u8, key, k)) return true;
        }
        return false;
    }
};

pub const Result = struct {
    fields: Fields,
    skipped: []const Skipped,
};

/// One non-blank, non-comment source line with its indentation measured.
const Line = struct {
    indent: usize,
    /// Content with indentation and any trailing comment removed.
    text: []const u8,
};

/// Splits `src` into lines, dropping blanks and comments.
///
/// Comments are stripped the way YAML strips them: `#` starts a comment at
/// the beginning of the content or after whitespace, and never inside a
/// quoted string.
const Reader = struct {
    src: []const u8,
    pos: usize = 0,
    /// One line of lookahead. The parser has to see whether a block continues
    /// before deciding whether to consume it, and a block's contents are
    /// consumed by the same loop that has to look at them.
    held: ?Line = null,
    skipped: std.ArrayList(Skipped) = .empty,
    arena: Allocator,

    fn warn(self: *Reader, construct: Skipped.Construct) Allocator.Error!void {
        // The reader has already advanced past the offending line, so this
        // points at the line after it. Close enough for a warning about a
        // construct that was skipped wholesale.
        try self.skipped.append(self.arena, .{
            .line = std.mem.countScalar(u8, self.src[0..@min(self.pos, self.src.len)], '\n'),
            .construct = construct,
        });
    }

    fn peek(self: *Reader) Allocator.Error!?Line {
        if (self.held == null) self.held = try self.read();
        return self.held;
    }

    fn next(self: *Reader) Allocator.Error!?Line {
        if (self.held) |line| {
            self.held = null;
            return line;
        }
        return self.read();
    }

    fn read(self: *Reader) Allocator.Error!?Line {
        while (self.pos < self.src.len) {
            const start = self.pos;
            const nl = std.mem.indexOfScalarPos(u8, self.src, start, '\n');
            const end = if (nl) |p| p else self.src.len;
            self.pos = if (nl) |p| p + 1 else self.src.len;

            var raw = self.src[start..end];
            if (raw.len > 0 and raw[raw.len - 1] == '\r') raw = raw[0 .. raw.len - 1];

            var indent: usize = 0;
            while (indent < raw.len and raw[indent] == ' ') indent += 1;

            // A tab cannot be YAML indentation, and the spacing rules around
            // it are ambiguous. Skip the line rather than guess.
            if (indent < raw.len and raw[indent] == '\t') {
                try self.warn(.tab_indent);
                continue;
            }

            const text = std.mem.trim(u8, stripComment(raw[indent..]), " \t");
            if (text.len == 0) continue;

            return .{ .indent = indent, .text = text };
        }
        return null;
    }
};

fn stripComment(s: []const u8) []const u8 {
    var quote: u8 = 0;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (quote != 0) {
            if (c == quote) quote = 0;
            continue;
        }
        switch (c) {
            '"', '\'' => quote = c,
            '#' => if (i == 0 or s[i - 1] == ' ' or s[i - 1] == '\t') return s[0..i],
            else => {},
        }
    }
    return s;
}

/// A `key: value` split, where `rest` may be empty.
const Pair = struct { key: []const u8, rest: []const u8 };

/// Splits a mapping line at its first `:` that is followed by a space or ends
/// the line.
///
/// Scanning for the first *qualified* colon rather than the first colon is
/// what keeps `link: https://example.com` intact.
fn splitKey(text: []const u8) ?Pair {
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] != ':') continue;
        if (i + 1 == text.len) return .{ .key = std.mem.trim(u8, text[0..i], " \t"), .rest = "" };
        if (text[i + 1] == ' ' or text[i + 1] == '\t') {
            return .{
                .key = std.mem.trim(u8, text[0..i], " \t"),
                .rest = std.mem.trim(u8, text[i + 1 ..], " \t"),
            };
        }
    }
    return null;
}

/// Strips a leading `- ` list marker. A bare `-` is not a marker: `-1` is a
/// number and `-inf` is a scalar.
fn listItem(text: []const u8) struct { is_item: bool, rest: []const u8 } {
    if (text.len >= 2 and text[0] == '-' and (text[1] == ' ' or text[1] == '\t')) {
        return .{ .is_item = true, .rest = std.mem.trim(u8, text[2..], " \t") };
    }
    return .{ .is_item = false, .rest = text };
}

/// True for a block scalar indicator: `|`, `>`, with optional chomping (`-`,
/// `+`) and explicit indentation digits.
fn isBlockIndicator(s: []const u8) bool {
    if (s.len == 0 or (s[0] != '|' and s[0] != '>')) return false;
    for (s[1..]) |c| {
        if (c == '-' or c == '+') continue;
        if (std.ascii.isDigit(c)) continue;
        return false;
    }
    return true;
}

fn boolean(raw: []const u8) ?bool {
    if (std.ascii.eqlIgnoreCase(raw, "true") or std.mem.eql(u8, raw, "yes")) return true;
    if (std.ascii.eqlIgnoreCase(raw, "false") or std.mem.eql(u8, raw, "no")) return false;
    return null;
}

const Parser = struct {
    arena: Allocator,
    r: Reader,
    f: Fields = .{},

    fn next(self: *Parser) Allocator.Error!?Line {
        return self.r.next();
    }

    /// Returns the next line when it is indented deeper than `indent`, which
    /// is how a block belonging to a key is recognized.
    fn child(self: *Parser, indent: usize) Allocator.Error!?Line {
        const line = (try self.r.peek()) orelse return null;
        if (line.indent <= indent) return null;
        return self.r.next();
    }

    /// Reads a scalar value, returning null for anything outside the subset.
    ///
    /// The result aliases `src` unless quotes had to come off, in which case
    /// it is copied into the arena.
    fn scalar(self: *Parser, raw: []const u8) Allocator.Error!?[]const u8 {
        if (raw.len == 0) return "";
        switch (raw[0]) {
            '&' => {
                try self.r.warn(.anchor);
                return null;
            },
            '*' => {
                try self.r.warn(.alias);
                return null;
            },
            '{', '[' => {
                try self.r.warn(.flow_collection);
                return null;
            },
            else => {},
        }
        if (raw.len >= 2 and (raw[0] == '"' or raw[0] == '\'') and raw[raw.len - 1] == raw[0]) {
            return try self.arena.dupe(u8, raw[1 .. raw.len - 1]);
        }
        if (raw[0] == '"' or raw[0] == '\'') {
            try self.r.warn(.unterminated_quote);
            return null;
        }
        return raw;
    }

    /// Reads a value that is either inline or an indented block below it.
    ///
    /// Returning null means "this turned out not to be a scalar", in which
    /// case the block has been consumed and the caller must not read it
    /// again.
    fn value(self: *Parser, indent: usize, head: []const u8) Allocator.Error!?[]const u8 {
        // `|`, `|-`, `>`, `>-` are block scalar indicators: they mark the
        // value as the indented block below rather than being the value. The
        // difference between literal and folded is newlines versus spaces, and
        // the chomping indicators are cosmetic here, so they all fold the same
        // way.
        if (head.len == 0 or isBlockIndicator(head)) {
            const line = (try self.r.peek()) orelse return "";
            if (line.indent <= indent) return "";

            // A mapping or a list of mappings under a key is not a scalar.
            if (splitKey(listItem(line.text).rest) != null) {
                try self.r.warn(.nested_under_scalar);
                return null;
            }

            return try self.blockScalar(indent);
        }

        return try self.scalar(head);
    }

    /// Consumes the indented lines below a key and folds them into one string.
    fn blockScalar(self: *Parser, indent: usize) Allocator.Error!?[]const u8 {
        var parts: std.ArrayList([]const u8) = .empty;
        defer parts.deinit(self.arena);

        while (try self.child(indent)) |line| {
            const item = listItem(line.text);
            // A list of mappings here means this is not a scalar after all.
            if (item.is_item and splitKey(item.rest) != null) {
                try self.r.warn(.nested_under_scalar);
                return null;
            }
            try parts.append(self.arena, (try self.scalar(line.text)) orelse continue);
        }

        if (parts.items.len == 0) return "";
        return try std.mem.join(self.arena, " ", parts.items);
    }

/// Reports the constructs that `scalar` would reject, without reading the
/// value.
///
/// An unknown key never reaches `scalar`, so without this an author writing
/// `anchor: &base` under a key zdoc does not use would get no indication that
/// anything was dropped.
fn noteConstructs(self: *Parser, raw: []const u8) Allocator.Error!void {
    if (raw.len == 0) return;
    switch (raw[0]) {
        '&' => try self.r.warn(.anchor),
        '*' => try self.r.warn(.alias),
        '{', '[' => try self.r.warn(.flow_collection),
        else => {},
    }
}

/// Drops every line indented under `indent`, so an unrecognized block is
    /// consumed as a unit rather than leaking keys back to the top level.
    fn skipBlock(self: *Parser, indent: usize) Allocator.Error!void {
        while (try self.r.peek()) |line| {
            if (line.indent <= indent) break;
            _ = try self.r.next();
        }
    }

    fn parse(self: *Parser) Allocator.Error!void {
        while (try self.next()) |line| {
            // The caller already isolated the block, so a `---` here means the
            // author's frontmatter ran longer than the closing delimiter we
            // found. Keep going rather than truncating the document.
            if (std.mem.eql(u8, line.text, "---")) {
                try self.r.warn(.document_marker);
                continue;
            }

            const pair = splitKey(line.text) orelse {
                try self.r.warn(.flow_collection);
                continue;
            };

            try self.field(line.indent, pair);
        }
    }

    fn field(self: *Parser, indent: usize, pair: Pair) Allocator.Error!void {
        // These own their blocks, so they have to be dispatched before the
        // value is read -- reading the value would consume the block out from
        // under them.
        if (std.mem.eql(u8, pair.key, "hero")) return self.hero(indent);
        if (std.mem.eql(u8, pair.key, "features")) return self.features(indent);
        if (std.mem.eql(u8, pair.key, "tags")) return self.tags(indent, pair.rest);

        // An unknown key is skipped as a whole. The check has to come before
        // the value is read: `value` consumes a nested block, and for a key we
        // do not use there is nothing to assign it to.
        if (!self.f.has(pair.key)) {
            try self.noteConstructs(pair.rest);
            return self.skipBlock(indent);
        }

        const v = (try self.value(indent, pair.rest)) orelse return;

        if (std.mem.eql(u8, pair.key, "title")) {
            self.f.title = v;
        } else if (std.mem.eql(u8, pair.key, "description")) {
            self.f.description = v;
        } else if (std.mem.eql(u8, pair.key, "layout")) {
            self.f.layout = v;
        } else if (std.mem.eql(u8, pair.key, "draft")) {
            self.f.draft = boolean(v);
        } else if (std.mem.eql(u8, pair.key, "hidden")) {
            self.f.hidden = boolean(v);
        } else if (std.mem.eql(u8, pair.key, "exclude")) {
            self.f.exclude = boolean(v);
        } else if (std.mem.eql(u8, pair.key, "nav")) {
            self.f.nav = boolean(v);
        } else if (std.mem.eql(u8, pair.key, "order")) {
            self.f.order = std.fmt.parseInt(i64, v, 10) catch null;
        }
    }

    fn tags(self: *Parser, indent: usize, head: []const u8) Allocator.Error!void {
        var list: std.ArrayList([]const u8) = .empty;

        if (head.len != 0) {
            // `tags: a, b` is not YAML, but it is a common slip and harmless
            // to accept as a convenience.
            var it = std.mem.splitScalar(u8, head, ',');
            while (it.next()) |raw| {
                const t = std.mem.trim(u8, raw, " \t");
                if (t.len == 0) continue;
                try list.append(self.arena, try self.arena.dupe(u8, t));
            }
        } else {
            while (try self.child(indent)) |line| {
                const item = listItem(line.text);
                if (!item.is_item) break;
                try list.append(self.arena, (try self.scalar(item.rest)) orelse continue);
            }
        }

        self.f.tags = try list.toOwnedSlice(self.arena);
    }

    fn hero(self: *Parser, indent: usize) Allocator.Error!void {
        var hero_actions: std.ArrayList(Action) = .empty;
        var result: Hero = .{ .present = true };

        while (try self.child(indent)) |line| {
            const pair = splitKey(line.text) orelse continue;
            if (std.mem.eql(u8, pair.key, "actions")) {
                try self.actions(&hero_actions, line.indent, pair.rest);
                continue;
            }

            const v = (try self.value(line.indent, pair.rest)) orelse continue;
            if (std.mem.eql(u8, pair.key, "name")) {
                result.name = v;
            } else if (std.mem.eql(u8, pair.key, "text")) {
                result.text = v;
            } else if (std.mem.eql(u8, pair.key, "tagline")) {
                result.tagline = v;
            } else if (std.mem.eql(u8, pair.key, "image")) {
                result.image = v;
            } else {
                try self.skipBlock(line.indent);
            }
        }

        result.actions = try hero_actions.toOwnedSlice(self.arena);
        self.f.hero = result;
    }

    fn setAction(a: *Action, key: []const u8, v: []const u8) void {
        if (std.mem.eql(u8, key, "text")) {
            a.text = v;
        } else if (std.mem.eql(u8, key, "link")) {
            a.link = v;
        } else if (std.mem.eql(u8, key, "theme")) {
            a.theme = v;
        }
    }

    /// Reads `actions:` as a `- ` list of mappings.
    ///
    /// VitePress also allows the whole list inline as a flow sequence, which
    /// is outside the subset; those are reported and dropped rather than
    /// half-read.
    fn actions(
        self: *Parser,
        out: *std.ArrayList(Action),
        indent: usize,
        head: []const u8,
    ) Allocator.Error!void {
        if (head.len != 0) {
            try self.r.warn(.flow_collection);
            return;
        }

        while (try self.child(indent)) |line| {
            const item = listItem(line.text);
            if (!item.is_item) break;

            var action: Action = .{};
            if (splitKey(item.rest)) |kv| {
                setAction(&action, kv.key, (try self.scalar(kv.rest)) orelse "");
            }

            // Continuation lines of the same mapping sit two columns in.
            while (try self.r.peek()) |cont| {
                if (cont.indent <= line.indent + 1) break;
                _ = try self.r.next();
                const kv = splitKey(cont.text) orelse continue;
                setAction(&action, kv.key, (try self.scalar(kv.rest)) orelse "");
            }

            try out.append(self.arena, action);
        }
    }

    fn features(self: *Parser, indent: usize) Allocator.Error!void {
        var list: std.ArrayList(Feature) = .empty;

        while (try self.child(indent)) |line| {
            const item = listItem(line.text);
            if (!item.is_item) break;

            var feature: Feature = .{};
            if (splitKey(item.rest)) |kv| {
                try self.setFeature(&feature, line.indent, kv);
            }

            while (try self.r.peek()) |cont| {
                if (cont.indent <= line.indent + 1) break;
                _ = try self.r.next();
                const kv = splitKey(cont.text) orelse continue;
                try self.setFeature(&feature, cont.indent, kv);
            }

            try list.append(self.arena, feature);
        }

        self.f.features = try list.toOwnedSlice(self.arena);
    }

    fn setFeature(self: *Parser, f: *Feature, indent: usize, kv: Pair) Allocator.Error!void {
        if (std.mem.eql(u8, kv.key, "title")) {
            f.title = (try self.scalar(kv.rest)) orelse "";
        } else if (std.mem.eql(u8, kv.key, "icon")) {
            f.icon = (try self.scalar(kv.rest)) orelse null;
        } else if (std.mem.eql(u8, kv.key, "details")) {
            f.details = (try self.value(indent, kv.rest)) orelse "";
        }
    }
};

/// Parses a frontmatter block.
///
/// `src` is the text between the delimiters. The result borrows from `src`
/// and from `arena`, so both must outlive it.
pub fn parse(arena: Allocator, src: []const u8) Allocator.Error!Result {
    var p: Parser = .{ .arena = arena, .r = .{ .src = src, .arena = arena } };
    try p.parse();
    return .{ .fields = p.f, .skipped = try p.r.skipped.toOwnedSlice(arena) };
}

const testing = std.testing;


test "scalars, quoted and bare" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const r = try parse(arena_state.allocator(),
        \\title: Hello World
        \\description: "A quoted description"
        \\draft: true
        \\order: 3
        \\hidden: false
    );
    try testing.expectEqualStrings("Hello World", r.fields.title.?);
    try testing.expectEqualStrings("A quoted description", r.fields.description.?);
    try testing.expectEqual(true, r.fields.draft.?);
    try testing.expectEqual(@as(i64, 3), r.fields.order.?);
    try testing.expectEqual(false, r.fields.hidden.?);
    try testing.expectEqual(@as(usize, 0), r.skipped.len);
}

test "a colon inside a value does not split the key" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const r = try parse(arena_state.allocator(),
        \\link: https://example.com/x
    );
    try testing.expect(r.fields.title == null);
    try testing.expectEqual(@as(usize, 0), r.skipped.len);
}

test "an unknown key's block cannot leak into the top level" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const r = try parse(arena_state.allocator(),
        \\unknown_block:
        \\  title: Wrong
        \\  description: Wrong
        \\title: Right
    );
    try testing.expectEqualStrings("Right", r.fields.title.?);
    try testing.expect(r.fields.description == null);
}

test "list of scalars" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const r = try parse(arena_state.allocator(),
        \\tags:
        \\  - alpha
        \\  - beta
    );
    try testing.expectEqual(@as(usize, 2), r.fields.tags.len);
    try testing.expectEqualStrings("alpha", r.fields.tags[0]);
    try testing.expectEqualStrings("beta", r.fields.tags[1]);
}

test "hero with actions" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const r = try parse(arena_state.allocator(),
        \\layout: home
        \\hero:
        \\  name: ZigModu
        \\  text: A modular framework for Zig
        \\  tagline: Build services as modules.
        \\  actions:
        \\    - theme: brand
        \\      text: Read the documentation
        \\      link: /README
        \\    - theme: alt
        \\      text: Source
        \\      link: https://example.com
    );
    try testing.expectEqualStrings("home", r.fields.layout.?);
    try testing.expect(r.fields.hero.present);
    try testing.expectEqualStrings("ZigModu", r.fields.hero.name);
    try testing.expectEqualStrings("A modular framework for Zig", r.fields.hero.text);
    try testing.expectEqualStrings("Build services as modules.", r.fields.hero.tagline);
    try testing.expectEqual(@as(usize, 2), r.fields.hero.actions.len);
    try testing.expectEqualStrings("brand", r.fields.hero.actions[0].theme);
    try testing.expectEqualStrings("Read the documentation", r.fields.hero.actions[0].text);
    try testing.expectEqualStrings("/README", r.fields.hero.actions[0].link);
    try testing.expectEqualStrings("https://example.com", r.fields.hero.actions[1].link);
}

test "features list" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const r = try parse(arena_state.allocator(),
        \\features:
        \\  - title: Fast
        \\    details: Compiles quickly.
        \\  - title: Small
        \\    details: No runtime.
    );
    try testing.expectEqual(@as(usize, 2), r.fields.features.len);
    try testing.expectEqualStrings("Fast", r.fields.features[0].title);
    try testing.expectEqualStrings("Compiles quickly.", r.fields.features[0].details);
    try testing.expectEqualStrings("No runtime.", r.fields.features[1].details);
}

test "comments and blank lines are ignored" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const r = try parse(arena_state.allocator(),
        \\# a comment
        \\title: Kept  # trailing comment
        \\
        \\# another
    );
    try testing.expectEqualStrings("Kept", r.fields.title.?);
}

test "a hash inside a quoted string is not a comment" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const r = try parse(arena_state.allocator(),
        \\title: "a # b"
    );
    try testing.expectEqualStrings("a # b", r.fields.title.?);
}

test "unsupported constructs are skipped, never fatal" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const r = try parse(arena_state.allocator(),
        \\anchor: &base
        \\flow: {a, b}
        \\title: Still Here
    );
    try testing.expectEqualStrings("Still Here", r.fields.title.?);
    try testing.expect(r.skipped.len >= 2);
}

test "block scalar folds indented lines" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const r = try parse(arena_state.allocator(),
        \\description: |
        \\  first line
        \\  second line
        \\title: T
    );
    try testing.expectEqualStrings("first line second line", r.fields.description.?);
    try testing.expectEqualStrings("T", r.fields.title.?);
}

test "empty block yields nothing, not a failure" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const r = try parse(arena_state.allocator(), "");
    try testing.expect(r.fields.title == null);
    try testing.expectEqual(@as(usize, 0), r.skipped.len);
}

test "the real shape that used to abort the build" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const r = try parse(arena_state.allocator(),
        \\layout: home
        \\
        \\hero:
        \\  name: ZigModu
        \\  text: A modular framework for Zig
        \\  tagline: Build services as modules — compose, route, observe, evolve.
        \\  actions:
        \\    - theme: brand
        \\      text: Read the documentation
        \\      link: /README
        \\    - theme: alt
        \\      text: GitHub
        \\      link: https://github.com/
        \\
        \\features:
        \\  - title: Modular
        \\    icon: 🧩
        \\    details: Compose services from independently deployable modules.
        \\  - title: Observable
        \\    details: Every module reports through the same interface.
    );
    try testing.expectEqualStrings("home", r.fields.layout.?);
    try testing.expectEqualStrings("ZigModu", r.fields.hero.name);
    try testing.expectEqualStrings(
        "Build services as modules — compose, route, observe, evolve.",
        r.fields.hero.tagline,
    );
    try testing.expectEqual(@as(usize, 2), r.fields.hero.actions.len);
    try testing.expectEqual(@as(usize, 2), r.fields.features.len);
    try testing.expectEqualStrings("Modular", r.fields.features[0].title);
}