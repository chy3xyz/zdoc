const std = @import("std");
const Writer = std.Io.Writer;
const supermd = @import("supermd");
const c = supermd.c;
const Ast = supermd.Ast;
const Iter = Ast.Iter;
const tracy = @import("tracy");
const root = @import("../root.zig");
const highlight = @import("../highlight.zig");
const context = @import("../context.zig");
const StringTable = @import("../StringTable.zig");
const PathTable = @import("../PathTable.zig");
const Path = PathTable.Path;
const PathName = PathTable.PathName;
const HtmlSafe = @import("superhtml").HtmlSafe;

/// Returns whether this list item is a GFM task list entry, and whether it is
/// checked.
///
/// cmark's tasklist extension consumes the `[ ]` / `[x]` marker and records the
/// state on the node, reachable only through the C API. Reading the flag alone
/// is not enough: it returns false both for an *unchecked* task item and for an
/// ordinary list item, and those need different markup.
///
/// The write side of the same API distinguishes them. cmark only accepts the
/// write for nodes the tasklist extension owns, so setting the flag and reading
/// it back is a reliable membership test. The original value is restored so
/// rendering has no side effect on the document.
const TaskState = struct {
    is_task: bool,
    checked: bool,
};

fn listHasTasks(node: supermd.Node) bool {
    var child = node.firstChild();
    while (child) |item| : (child = item.nextSibling()) {
        if (taskState(item).is_task) return true;
    }
    return false;
}

fn taskState(node: supermd.Node) TaskState {
    const checked = c.cmark_gfm_extensions_get_tasklist_item_checked(node.n);
    if (checked) return .{ .is_task = true, .checked = true };

    _ = c.cmark_gfm_extensions_set_tasklist_item_checked(node.n, true);
    const is_task = c.cmark_gfm_extensions_get_tasklist_item_checked(node.n);
    _ = c.cmark_gfm_extensions_set_tasklist_item_checked(node.n, false);

    return .{ .is_task = is_task, .checked = false };
}

const log = std.log.scoped(.render);

fn eqlIgnoreCase(lhs: []const u8, rhs: []const u8) bool {
    return lhs.len == rhs.len and std.ascii.eqlIgnoreCase(lhs, rhs);
}

fn dataUrlAllowed(rest: []const u8) bool {
    const kinds = [_][]const u8{ "image/", "audio/", "video/" };
    for (kinds) |kind| {
        if (rest.len >= kind.len and eqlIgnoreCase(rest[0..kind.len], kind)) {
            return true;
        }
    }
    return false;
}

/// Rejects URL schemes that execute code when followed or embedded.
///
/// Relative URLs, fragments and protocol-relative URLs have no scheme and are
/// always allowed. `data:` is only allowed for media, where the browser treats
/// it as an image/audio/video source rather than a document.
fn isUnsafeUrl(url: []const u8, allow_data: bool) bool {
    const s = std.mem.trimStart(u8, url, " \t\r\n");
    const colon = std.mem.indexOfScalar(u8, s, ':') orelse return false;
    const boundary = std.mem.indexOfAny(u8, s, "/?#") orelse s.len;
    // A colon after a path/query/fragment separator is part of the path, not
    // a scheme.
    if (colon >= boundary) return false;

    const scheme = s[0..colon];
    if (eqlIgnoreCase(scheme, "http") or
        eqlIgnoreCase(scheme, "https") or
        eqlIgnoreCase(scheme, "mailto") or
        eqlIgnoreCase(scheme, "tel") or
        eqlIgnoreCase(scheme, "ftp")) return false;

    if (allow_data and eqlIgnoreCase(scheme, "data")) {
        return !dataUrlAllowed(s[colon + 1 ..]);
    }
    return true;
}

/// Writes a URL into a double-quoted attribute, escaping it and refusing
/// executable schemes.
fn writeUrlAttribute(w: *Writer, url: []const u8, allow_data: bool) !void {
    if (isUnsafeUrl(url, allow_data)) {
        try w.writeAll("#");
        return;
    }
    try w.print("{f}", .{HtmlSafe{ .bytes = url }});
}

fn isHtmlNameStart(ch: u8) bool {
    return std.ascii.isAlphabetic(ch) or ch == '_' or ch == ':';
}

fn isHtmlNameChar(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == ':' or ch == '.';
}

fn isHtmlSpace(ch: u8) bool {
    return ch == ' ' or ch == '\t' or ch == '\r' or ch == '\n' or ch == '\x0c';
}

fn tagName(tag: []const u8) []const u8 {
    var i: usize = 1;
    if (i < tag.len and tag[i] == '/') i += 1;
    const start = i;
    while (i < tag.len and isHtmlNameChar(tag[i])) i += 1;
    return tag[start..i];
}

fn isRawTextTag(tag: []const u8) bool {
    const name = tagName(tag);
    return eqlIgnoreCase(name, "script") or eqlIgnoreCase(name, "style");
}

fn findCloseTag(src: []const u8, start: usize, name: []const u8) ?usize {
    var i = start;
    while (i + 2 + name.len <= src.len) : (i += 1) {
        if (src[i] != '<' or src[i + 1] != '/') continue;
        if (!eqlIgnoreCase(src[i + 2 .. i + 2 + name.len], name)) continue;
        var j = i + 2 + name.len;
        while (j < src.len and src[j] != '>') j += 1;
        return if (j < src.len) j + 1 else src.len;
    }
    return null;
}

/// Writes a URL found inside a raw HTML attribute. Root-relative paths get the
/// site's URL prefix; external, protocol-relative and relative URLs are left
/// untouched. Assets referenced this way are not analyzed, so they should live
/// under `static/`.
fn writeRawHtmlUrl(
    ctx: *const context.Root,
    page: *const context.Page,
    w: *Writer,
    url: []const u8,
) !void {
    if (url.len > 1 and url[0] == '/' and url[1] != '/') {
        try printAssetUrlPrefix(ctx, page, w);
        try w.writeAll(url[1..]);
    } else {
        try w.writeAll(url);
    }
}

/// Rewrites `href`/`src`/`poster` attributes of one tag. The tag text is
/// otherwise preserved byte for byte.
fn writeRawHtmlTag(
    ctx: *const context.Root,
    page: *const context.Page,
    w: *Writer,
    tag: []const u8,
) !void {
    var i: usize = 1;
    if (i < tag.len and tag[i] == '/') i += 1;
    while (i < tag.len and isHtmlNameChar(tag[i])) i += 1;
    try w.writeAll(tag[0..i]);

    while (i < tag.len) {
        if (!isHtmlNameStart(tag[i])) {
            try w.writeByte(tag[i]);
            i += 1;
            continue;
        }

        const start = i;
        while (i < tag.len and isHtmlNameChar(tag[i])) i += 1;
        const attr = tag[start..i];
        const rewrite = eqlIgnoreCase(attr, "href") or
            eqlIgnoreCase(attr, "src") or
            eqlIgnoreCase(attr, "poster");

        if (!rewrite) {
            try w.writeAll(attr);
            continue;
        }

        try w.writeAll(attr);
        while (i < tag.len and isHtmlSpace(tag[i])) : (i += 1) try w.writeByte(tag[i]);
        if (i >= tag.len or tag[i] != '=') continue;
        try w.writeByte('=');
        i += 1;
        while (i < tag.len and isHtmlSpace(tag[i])) : (i += 1) try w.writeByte(tag[i]);

        if (i < tag.len and (tag[i] == '"' or tag[i] == '\'')) {
            const quote = tag[i];
            try w.writeByte(quote);
            i += 1;
            const value_start = i;
            while (i < tag.len and tag[i] != quote) i += 1;
            try writeRawHtmlUrl(ctx, page, w, tag[value_start..i]);
            if (i < tag.len) {
                try w.writeByte(quote);
                i += 1;
            }
        } else {
            const value_start = i;
            while (i < tag.len and !isHtmlSpace(tag[i]) and tag[i] != '>') i += 1;
            try writeRawHtmlUrl(ctx, page, w, tag[value_start..i]);
        }
    }
}

/// Emits raw HTML, applying the site URL prefix to root-relative `href`/`src`
/// attributes. Script and style bodies, comments and declarations are copied
/// verbatim.
fn writeRawHtml(
    ctx: *const context.Root,
    page: *const context.Page,
    w: *Writer,
    src: []const u8,
) !void {
    var i: usize = 0;
    while (i < src.len) {
        if (src[i] != '<') {
            try w.writeByte(src[i]);
            i += 1;
            continue;
        }

        if (std.mem.startsWith(u8, src[i..], "<!--")) {
            const end = std.mem.indexOfPos(u8, src, i + 4, "-->") orelse src.len;
            const stop = if (end == src.len) end else end + 3;
            try w.writeAll(src[i..stop]);
            i = stop;
            continue;
        }

        var j = i + 1;
        var quote: u8 = 0;
        while (j < src.len) : (j += 1) {
            const ch = src[j];
            if (quote != 0) {
                if (ch == quote) quote = 0;
            } else switch (ch) {
                '"', '\'' => quote = ch,
                '>' => break,
                else => {},
            }
        }
        if (j >= src.len) {
            try w.writeAll(src[i..]);
            break;
        }

        const tag = src[i .. j + 1];
        if (tag.len >= 2 and (tag[1] == '!' or tag[1] == '?')) {
            try w.writeAll(tag);
            i = j + 1;
            continue;
        }

        if (isRawTextTag(tag)) {
            // Rewrite the opening tag (a `<script src="/...">` still needs
            // the prefix), then copy the script/style body and closing tag
            // verbatim.
            try writeRawHtmlTag(ctx, page, w, tag);
            const name = tagName(tag);
            const end = findCloseTag(src, j + 1, name) orelse src.len;
            try w.writeAll(src[j + 1 .. end]);
            i = end;
            continue;
        }

        try writeRawHtmlTag(ctx, page, w, tag);
        i = j + 1;
    }
}

/// Writes the part of a link URL after the path.
///
/// A plain fragment is stored without its `#`; a query string (optionally
/// followed by `#fragment`) is stored with its leading `?` so it lands before
/// the fragment in the output URL.
fn writeLinkSuffix(w: *Writer, suffix: []const u8) !void {
    if (suffix.len > 0 and suffix[0] == '?') {
        try w.print("{f}", .{HtmlSafe{ .bytes = suffix }});
    } else {
        try w.print("#{f}", .{HtmlSafe{ .bytes = suffix }});
    }
}

/// Escapes a path that was formatted into `fmt` before writing it.
fn writeFmtEscaped(w: *Writer, comptime fmt: []const u8, args: anytype) !void {
    var aw: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
    defer aw.deinit();
    try aw.writer.print(fmt, args);
    try w.print("{f}", .{HtmlSafe{ .bytes = aw.written() }});
}

fn writeAttrs(w: *Writer, attrs: []const []const u8) !void {
    try w.writeAll(" class=\"");
    for (attrs) |attr| try w.print("{f} ", .{HtmlSafe{ .bytes = attr }});
    try w.writeAll("\"");
}

/// Parsed metadata from a fenced code block info string.
const FenceMeta = struct {
    lang: []const u8,
    title: ?[]const u8 = null,
    /// The raw contents of a `{1,3-5}` line specification, without braces.
    highlight: ?[]const u8 = null,
};

/// Parses a code fence info string.
///
/// The first whitespace-separated token is the language. VitePress-style
/// metadata may follow it: `title="..."` (the quotes keep spaces in the
/// title together) or `title=name`, plus a `{1,3-5}` line specification.
/// Unknown tokens are ignored so other tools' metadata never breaks a page.
fn parseFenceMeta(info: []const u8) FenceMeta {
    var meta: FenceMeta = .{ .lang = "" };
    var i: usize = 0;
    var first = true;

    while (i < info.len) {
        while (i < info.len and std.ascii.isWhitespace(info[i])) i += 1;
        if (i >= info.len) break;

        const start = i;
        var quote: u8 = 0;
        while (i < info.len) : (i += 1) {
            const ch = info[i];
            if (quote != 0) {
                if (ch == '\\' and i + 1 < info.len) {
                    i += 1;
                } else if (ch == quote) {
                    quote = 0;
                }
            } else if (ch == '"' or ch == '\'') {
                quote = ch;
            } else if (std.ascii.isWhitespace(ch)) {
                break;
            }
        }

        const token = info[start..i];
        if (first) {
            meta.lang = token;
            first = false;
            continue;
        }

        if (std.mem.startsWith(u8, token, "title=")) {
            meta.title = unquoteFenceValue(token["title=".len..]);
        } else if (token.len >= 2 and token[0] == '{' and token[token.len - 1] == '}') {
            meta.highlight = token[1 .. token.len - 1];
        }
    }

    return meta;
}

fn unquoteFenceValue(value: []const u8) []const u8 {
    if (value.len >= 2) {
        const q = value[0];
        if ((q == '"' or q == '\'') and value[value.len - 1] == q) {
            return value[1 .. value.len - 1];
        }
    }
    return value;
}

/// Writes TeX destined for a `<script type="math/tex">` element. The HTML
/// parser ends the element at `</script`, even inside script data, so that
/// sequence must not appear verbatim.
fn writeMathTex(w: *Writer, code: []const u8) !void {
    var i: usize = 0;
    while (i < code.len) {
        if (i + 8 <= code.len and code[i] == '<' and code[i + 1] == '/' and
            eqlIgnoreCase(code[i + 2 .. i + 8], "script"))
        {
            try w.writeAll("<\\/");
            i += 2;
            continue;
        }
        try w.writeByte(code[i]);
        i += 1;
    }
}

pub fn html(
    gpa: std.mem.Allocator,
    ctx: *const context.Root,
    page: *const context.Page,
    start: supermd.Node,
    w: *Writer,
) !void {
    const zone = tracy.traceNamed(@src(), "html");
    defer zone.end();

    const ast = page._parse.ast;

    // Footnotes are disconnected from the main ast tree so we cannot
    // start an iterator from the document's root node when rendering
    // one (which happens on-demand by pointing `start` at a footnote node).
    const root_node = if (start.nodeType() == .FOOTNOTE_DEFINITION) start else ast.md.root;
    var it = Iter.init(root_node);

    const full_page = start.n == ast.md.root.n;
    var event: ?Iter.Event = if (!full_page) blk: {
        it.reset(start, .enter);
        break :blk .{ .node = start, .dir = .enter };
    } else it.next();

    var open_div = false;
    var table_in_header = false;
    var table_alignments: []const u8 = &.{};
    var table_cell_id: usize = 0;
    var table_head_open = false;
    var table_body_open = false;
    while (event) |ev| : (event = it.next()) {
        // const loop_zone = tracy.traceNamed(@src(), "html-event");
        // defer loop_zone.end();

        const node = ev.node;
        const node_is_section = if (node.getDirective()) |d|
            d.kind == .section and node.nodeType() != .LINK
        else
            false;

        // var buf: [1024]u8 = undefined;
        // tracy.messageCopy(std.fmt.bufPrint(&buf, "{} {s}", .{
        //     node.nodeType(),
        //     @tagName(ev.dir),
        // }) catch unreachable);

        log.debug("node ({}, {s}, {?s}) = {} {s} \n({*} == {*} {})", .{
            node_is_section,
            if (node.getDirective()) |d| @tagName(d.kind) else "<>",
            if (node.getDirective()) |d| d.id else null,
            node.nodeType(),
            @tagName(ev.dir),
            node.n,
            start.n,
            node.n != start.n,
        });

        if (!full_page and node_is_section and node.n != start.n) {
            log.debug("done, breaking", .{});
            break;
        }

        switch (node.nodeType()) {
            .DOCUMENT => {},
            .BLOCK_QUOTE => switch (ev.dir) {
                .enter => {
                    const d = node.getDirective() orelse {
                        try w.print("<blockquote>", .{});
                        continue;
                    };

                    if (d.kind.block.collapsible) |collap| {
                        try w.writeAll("<details");
                        if (collap) try w.writeAll(" open");
                    } else {
                        try w.writeAll("<div");
                    }

                    if (d.id) |id| try w.print(" id=\"{f}\"", .{HtmlSafe{ .bytes = id }});
                    try w.print(" class=\"block", .{});
                    if (d.attrs) |attrs| {
                        for (attrs) |attr| try w.print(" {f}", .{HtmlSafe{ .bytes = attr }});
                    }
                    try w.print("\">", .{});
                },
                .exit => {
                    if (node.getDirective()) |d| {
                        if (d.kind.block.collapsible != null) {
                            try w.print("</details>", .{});
                        } else {
                            try w.print("</div>", .{});
                        }
                    } else {
                        try w.print("</blockquote>", .{});
                        continue;
                    }
                },
            },
            .LIST => switch (ev.dir) {
                .enter => {
                    if (node.listType() == .ol) {
                        const list_start = c.cmark_node_get_list_start(node.n);
                        if (list_start > 1) {
                            try w.print("<ol start=\"{d}\"", .{list_start});
                        } else {
                            try w.writeAll("<ol");
                        }
                    } else {
                        try w.writeAll("<ul");
                    }
                    if (listHasTasks(node)) try w.writeAll(" class=\"contains-task-list\"");
                    try w.writeAll(">");
                },
                .exit => try w.print("</{s}>", .{
                    @tagName(node.listType()),
                }),
            },
            .ITEM => switch (ev.dir) {
                .enter => {
                    // A task list item carries its state on the node rather
                    // than in its text, so render the checkbox here.
                    const task = taskState(node);
                    if (task.is_task) {
                        try w.print(
                            "<li class=\"task-list-item\"><input class=\"task-list-item-checkbox\" type=\"checkbox\" disabled{s}> ",
                            .{if (task.checked) " checked" else ""},
                        );
                    } else {
                        try w.print("<li>", .{});
                    }
                },
                .exit => try w.print("</li>", .{}),
            },
            .HTML_BLOCK => switch (ev.dir) {
                .enter => try writeRawHtml(
                    ctx,
                    page,
                    w,
                    node.literal() orelse "",
                ),
                .exit => {},
            },
            .CUSTOM_BLOCK => switch (ev.dir) {
                .enter => {},
                .exit => {},
            },
            .PARAGRAPH => {
                if (node.parent()) |p|
                    if (p.parent()) |gp|
                        if (gp.listIsTight()) continue;

                switch (ev.dir) {
                    .enter => {
                        if (node.getDirective()) |d| {
                            if (open_div) {
                                try w.print("</div>", .{});
                            }
                            open_div = true;
                            try w.print("<div", .{});
                            if (d.id) |id| try w.print(" id=\"{f}\"", .{HtmlSafe{ .bytes = id }});
                            if (d.attrs) |attrs| try writeAttrs(w, attrs);

                            try w.print(">", .{});
                            _ = it.next();
                            _ = it.next();
                            if (node.firstChild().?.nextSibling() == null) {
                                continue;
                            }
                        }

                        try w.print("<p>", .{});
                    },
                    .exit => {
                        if (node.getDirective() != null) {
                            if (node.firstChild().?.nextSibling() == null) {
                                continue;
                            }
                        }
                        try w.print("</p>", .{});
                    },
                }
            },
            .HEADING => switch (ev.dir) {
                .enter => {
                    if (node.parent()) |p| if (p.getDirective()) |pd| switch (pd.kind) {
                        else => {},
                        .block => |b| {
                            if (b.collapsible != null and node.prevSibling() == null) {
                                try w.writeAll("<summary>");
                                continue;
                            }
                        },
                    };
                    if (node.getDirective()) |d| switch (d.kind) {
                        else => {},
                        .heading => {
                            const lvl = node.headingLevel() + @intFromBool(ctx._meta.build.cfg.supermd.headings_h2);
                            try w.print("<h{}", .{lvl});
                            if (d.id) |id| try w.print(" id=\"{f}\"", .{HtmlSafe{ .bytes = id }});
                            if (d.attrs) |attrs| try writeAttrs(w, attrs);

                            try w.print(">", .{});
                            continue;
                        },
                        .section => {
                            if (open_div) {
                                try w.print("</div>", .{});
                            }
                            open_div = true;
                            try w.print("<div", .{});
                            if (d.id) |id| try w.print(" id=\"{f}\"", .{HtmlSafe{ .bytes = id }});
                            if (d.attrs) |attrs| try writeAttrs(w, attrs);

                            try w.print(">", .{});
                        },
                    };

                    const lvl = node.headingLevel() + @intFromBool(ctx._meta.build.cfg.supermd.headings_h2);
                    try w.print("<h{}>", .{lvl});
                },
                .exit => {
                    if (node.parent()) |p| if (p.getDirective()) |pd| switch (pd.kind) {
                        else => {},
                        .block => |b| {
                            if (b.collapsible != null and node.prevSibling() == null) {
                                try w.writeAll("</summary>");
                                continue;
                            }
                        },
                    };
                    const lvl = node.headingLevel() + @intFromBool(ctx._meta.build.cfg.supermd.headings_h2);
                    try w.print("</h{}>", .{lvl});
                },
            },
            .THEMATIC_BREAK => switch (ev.dir) {
                .enter => try w.print("<hr>", .{}),
                .exit => {},
            },
            .FOOTNOTE_REFERENCE => switch (ev.dir) {
                .enter => {
                    const literal = node.literal().?;
                    const def_idx = ast.footnotes.getIndex(literal).?;
                    const footnote = ast.footnotes.values()[def_idx];
                    try w.print("<sup class=\"footnote-ref\"><a href=\"#{s}\" id=\"{s}\">{d}</a></sup>", .{
                        footnote.def_id,
                        footnote.ref_ids[@intCast(node.footnoteRefIx() - 1)],
                        def_idx + 1,
                    });
                },
                .exit => {},
            },
            .FOOTNOTE_DEFINITION => switch (ev.dir) {
                .enter => {
                    if (start.nodeType() != .FOOTNOTE_DEFINITION) {
                        it.reset(node, .exit);
                    }
                },
                .exit => {},
            },
            .HTML_INLINE => switch (ev.dir) {
                .enter => try writeRawHtml(
                    ctx,
                    page,
                    w,
                    node.literal() orelse "",
                ),
                // cmark emits HTML_INLINE as a leaf; there is no exit event.
                .exit => {},
            },
            .CUSTOM_INLINE => switch (ev.dir) {
                .enter => @panic("custom inline"),
                .exit => {},
            },
            .TEXT => switch (ev.dir) {
                .enter => try w.print("{f}", .{
                    HtmlSafe{ .bytes = node.literal() orelse "" },
                }),
                .exit => {},
            },
            .SOFTBREAK => switch (ev.dir) {
                .enter => try w.print(" ", .{}),
                .exit => {},
            },
            .LINEBREAK => switch (ev.dir) {
                .enter => try w.print("<br>", .{}),
                .exit => {},
            },
            .CODE => switch (ev.dir) {
                .enter => try w.print("<code>{f}</code>", .{
                    HtmlSafe{ .bytes = node.literal() orelse "" },
                }),
                .exit => {},
            },
            .EMPH => switch (ev.dir) {
                .enter => try w.print("<em>", .{}),
                .exit => try w.print("</em>", .{}),
            },
            .STRONG => switch (ev.dir) {
                .enter => try w.print("<strong>", .{}),
                .exit => try w.print("</strong>", .{}),
            },
            .LINK, .IMAGE => {
                // SuperMD attaches an image directive to top-level images,
                // but it does not analyze the children of a LINK, so an image
                // inside a link (`[![alt](img)](url)`) has no directive at
                // all. Both forms are ordinary Markdown images: render them
                // the same way and skip the alt-text child node.
                if (node.nodeType() == .IMAGE) {
                    if (ev.dir == .enter) {
                        try renderMarkdownImage(ctx, page, node, w);
                        it.reset(node, .exit);
                    }
                    continue;
                }
                try renderDirective(gpa, ctx, page, ast, ev, w);
            },
            .CODE_BLOCK => switch (ev.dir) {
                .exit => {},
                .enter => {
                    if (node.literal()) |code| {
                        const fence_info = node.fenceInfo() orelse "";
                        if (std.mem.trim(u8, fence_info, " \t\r\n").len == 0) {
                            try w.print("<pre><code>{f}</code></pre>", .{
                                HtmlSafe{ .bytes = code },
                            });
                        } else {
                            const meta = parseFenceMeta(fence_info);
                            const lang_name = meta.lang;

                            if (std.mem.eql(u8, lang_name, "=html")) {
                                try writeRawHtml(ctx, page, w, code);
                                continue;
                            } else if (std.mem.eql(u8, lang_name, "=mathtex")) {
                                try w.writeAll("<script type=\"math/tex\">");
                                try writeMathTex(w, code);
                                try w.writeAll("</script>");
                                continue;
                            } else if (std.mem.eql(u8, lang_name, "mermaid")) {
                                // Diagrams are drawn by mermaid.js in the
                                // browser, so emit the source as a plain block
                                // rather than trying to highlight it here.
                                if (meta.title) |title| {
                                    try w.writeAll("<figure class=\"code-block\">\n");
                                    try w.print("<figcaption>{f}</figcaption>\n", .{
                                        HtmlSafe{ .bytes = title },
                                    });
                                }
                                try w.print("<pre class=\"mermaid\">{f}</pre>", .{
                                    HtmlSafe{ .bytes = code },
                                });
                                if (meta.title != null) try w.writeAll("</figure>\n");
                                continue;
                            }

                            if (meta.title) |title| {
                                try w.writeAll("<figure class=\"code-block\">\n");
                                try w.print("<figcaption>{f}</figcaption>\n", .{
                                    HtmlSafe{ .bytes = title },
                                });
                            }

                            try w.writeAll("<pre");
                            if (meta.highlight) |hl| {
                                try w.print(" data-highlight=\"{f}\"", .{
                                    HtmlSafe{ .bytes = hl },
                                });
                            }
                            try w.print("><code class=\"{f}\">", .{
                                HtmlSafe{ .bytes = lang_name },
                            });

                            if (std.mem.eql(u8, lang_name, "console")) {
                                try highlight.runConsole(w, code);
                            } else {
                                highlight.run(
                                    ctx._meta.io,
                                    gpa,
                                    lang_name,
                                    code,
                                    w,
                                ) catch |err| switch (err) {
                                    error.OutOfMemory,
                                    error.WriteFailed,
                                    => |e| return e,
                                    // No grammar is behind this language, so
                                    // there is nothing to highlight with.
                                    // `highlight.run` returns before writing
                                    // anything in that case, so emitting the
                                    // source here cannot duplicate it.
                                    //
                                    // Emitting the code unhighlighted is what
                                    // every other Markdown renderer does, and
                                    // it is the difference between a document
                                    // rendered without colours and a document
                                    // with holes in it. This handler used to
                                    // discard the block, so a ```text fence
                                    // lost its contents entirely.
                                    error.NoLanguage, error.Unknown => {
                                        try w.print("{f}", .{HtmlSafe{ .bytes = code }});
                                    },
                                };
                            }

                            try w.writeAll("</code></pre>\n");
                            if (meta.title != null) try w.writeAll("</figure>\n");
                        }
                    }
                },
            },

            else => |nt| if (@backingInt(nt) == c.CMARK_NODE_STRIKETHROUGH) switch (ev.dir) {
                .enter => try w.writeAll("<del>"),
                .exit => try w.writeAll("</del>"),
            } else if (@backingInt(nt) == c.CMARK_NODE_TABLE) switch (ev.dir) {
                .enter => {
                    table_alignments = node.getTableAlignments();
                    table_head_open = false;
                    table_body_open = false;
                    try w.writeAll("<table>");
                },
                .exit => {
                    if (table_body_open) {
                        try w.writeAll("</tbody>");
                    } else if (table_head_open) {
                        try w.writeAll("</thead>");
                    }
                    table_alignments = &.{};
                    table_head_open = false;
                    table_body_open = false;
                    try w.writeAll("</table>");
                },
            } else if (@backingInt(nt) == c.CMARK_NODE_TABLE_ROW) switch (ev.dir) {
                .enter => {
                    table_in_header = node.isTableHeader();
                    if (table_in_header) {
                        if (!table_head_open) {
                            try w.writeAll("<thead>");
                            table_head_open = true;
                        }
                    } else if (!table_body_open) {
                        if (table_head_open) try w.writeAll("</thead>");
                        try w.writeAll("<tbody>");
                        table_body_open = true;
                    }
                    try w.writeAll("<tr>");
                },
                .exit => {
                    table_in_header = false;
                    table_cell_id = 0;
                    try w.writeAll("</tr>");
                },
            } else if (@backingInt(nt) == c.CMARK_NODE_TABLE_CELL) switch (ev.dir) {
                .enter => {
                    if (table_in_header) {
                        try w.writeAll("<th scope=\"col\"");
                    } else {
                        try w.writeAll("<td");
                    }

                    if (table_cell_id < table_alignments.len) {
                        const char = table_alignments[table_cell_id];
                        if (char != 0) try w.print(" style=\"text-align:{s}\"", .{
                            switch (char) {
                                else => unreachable,
                                'l' => "left",
                                'c' => "center",
                                'r' => "right",
                            },
                        });
                    }
                    table_cell_id += 1;

                    try w.writeAll(">");
                },
                .exit => {
                    if (table_in_header) {
                        try w.writeAll("</th>");
                    } else {
                        try w.writeAll("</td>");
                    }
                },
            } else std.debug.panic(
                "TODO: implement support for {x}",
                .{node.nodeType()},
            ),
        }
    }
    if (open_div) {
        try w.writeAll("</div>");
    }
}

/// Renders a standard Markdown image. The image's child node is its alt text,
/// not a caption, so it is deliberately not rendered as body content.
fn renderMarkdownImage(
    ctx: *const context.Root,
    page: *const context.Page,
    node: supermd.Node,
    w: *Writer,
) !void {
    const fallback_src = node.link() orelse "";

    try w.writeAll("<img src=\"");
    if (node.getDirective()) |d| switch (d.kind) {
        .image => |img| if (img.src) |src| {
            try printUrl(ctx, page, src, w, true);
        } else {
            try writeUrlAttribute(w, fallback_src, true);
        },
        else => try writeUrlAttribute(w, fallback_src, true),
    } else try writeUrlAttribute(w, fallback_src, true);
    try w.writeAll("\"");

    const alt = std.mem.trim(u8, node.renderPlaintext() catch "", " \t\r\n");
    if (alt.len != 0) try w.print(" alt=\"{f}\"", .{HtmlSafe{ .bytes = alt }});
    if (node.title()) |t| try w.print(" title=\"{f}\"", .{HtmlSafe{ .bytes = t }});

    if (node.getDirective()) |d| switch (d.kind) {
        .image => |img| if (img.size) |size| {
            if (size.w > 0) try w.print(" width=\"{d}\"", .{size.w});
            if (size.h > 0) try w.print(" height=\"{d}\"", .{size.h});
        },
        else => {},
    };

    try w.writeAll(">");
}

fn renderDirective(
    gpa: std.mem.Allocator,
    ctx: *const context.Root,
    page: *const context.Page,
    ast: Ast,
    ev: Iter.Event,
    w: *Writer,
) !void {
    const zone = tracy.trace(@src());
    defer zone.end();
    _ = ast;
    const node = ev.node;
    const directive = node.getDirective() orelse return renderLink(ev, ctx, w);
    switch (directive.kind) {
        .section, .block, .heading => {},
        .mathtex => |katek| switch (ev.dir) {
            .enter => {
                try w.writeAll("<script type=\"math/tex\"");
                if (directive.id) |id| try w.print(" id=\"{f}\"", .{HtmlSafe{ .bytes = id }});
                if (directive.attrs) |attrs| {
                    try w.writeAll(" class=\"");
                    for (attrs) |attr| try w.print("{f} ", .{HtmlSafe{ .bytes = attr }});
                    try w.writeAll("\"");
                }
                if (directive.title) |t| try w.print(" title=\"{f}\"", .{HtmlSafe{ .bytes = t }});
                try w.writeAll(">");
                try writeMathTex(w, katek.formula);
            },
            .exit => {
                try w.writeAll("</script>");
            },
        },
        .text => switch (ev.dir) {
            .enter => {
                try w.print("<span", .{});
                if (directive.id) |id| try w.print(" id=\"{f}\"", .{HtmlSafe{ .bytes = id }});
                if (directive.attrs) |attrs| {
                    try w.print(" class=\"", .{});
                    for (attrs) |attr| try w.print("{f} ", .{HtmlSafe{ .bytes = attr }});
                    try w.print("\"", .{});
                }
                if (directive.title) |t| try w.print(" title=\"{f}\"", .{HtmlSafe{ .bytes = t }});
                try w.print(">", .{});
            },
            .exit => {
                try w.print("</span>", .{});
            },
        },
        .image => |img| switch (ev.dir) {
            .enter => {
                // A standard `![alt](src)` image carries its alt text as a
                // child. SuperMD's `[caption]($image...)` link also has a
                // child, but there it is a visible caption. The node type is
                // what tells the two syntaxes apart.
                const is_markdown_image = node.nodeType() == .IMAGE;
                const caption = if (is_markdown_image) null else node.firstChild();
                if (caption != null) try w.writeAll("<figure>");
                if (img.linked) |l| if (l) {
                    try w.writeAll("<a href=\"");
                    try printUrl(ctx, page, img.src.?, w, true);
                    try w.writeAll("\">");
                };

                try w.writeAll("<img");
                if (directive.id) |id| try w.print(" id=\"{f}\"", .{HtmlSafe{ .bytes = id }});
                if (directive.attrs) |attrs| {
                    try w.writeAll(" class=\"");
                    for (attrs) |attr| try w.print("{f} ", .{HtmlSafe{ .bytes = attr }});
                    try w.writeAll("\"");
                }
                if (directive.title) |t| try w.print(" title=\"{f}\"", .{HtmlSafe{ .bytes = t }});
                try w.writeAll(" src=\"");
                try printUrl(ctx, page, img.src.?, w, true);
                try w.writeAll("\"");

                if (is_markdown_image) {
                    const alt = node.renderPlaintext() catch "";
                    if (alt.len != 0) try w.print(" alt=\"{f}\"", .{HtmlSafe{ .bytes = alt }});
                    if (node.title()) |t| try w.print(" title=\"{f}\"", .{HtmlSafe{ .bytes = t }});
                } else if (img.alt) |alt| {
                    try w.print(" alt=\"{f}\"", .{HtmlSafe{ .bytes = alt }});
                }
                if (img.size) |size| {
                    if (size.w > 0) try w.print(" width=\"{d}\"", .{size.w});
                    if (size.h > 0) try w.print(" height=\"{d}\"", .{size.h});
                }
                try w.writeAll(">");
                if (img.linked) |l| if (l) try w.writeAll("</a>");
                if (caption != null) try w.writeAll("\n<figcaption>");
            },
            .exit => {
                const is_markdown_image = node.nodeType() == .IMAGE;
                const caption = if (is_markdown_image) null else node.firstChild();
                if (caption != null) {
                    try w.writeAll("</figcaption></figure>");
                }
            },
        },
        .video => |vid| switch (ev.dir) {
            .enter => {
                const caption = node.firstChild();
                if (caption != null) try w.writeAll("<figure>");
                try w.writeAll("<video");
                if (directive.id) |id| try w.print(" id=\"{f}\"", .{HtmlSafe{ .bytes = id }});
                if (directive.attrs) |attrs| {
                    try w.writeAll(" class=\"");
                    for (attrs) |attr| try w.print("{f} ", .{HtmlSafe{ .bytes = attr }});
                    try w.writeAll("\"");
                }
                if (directive.title) |t| try w.print(" title=\"{f}\"", .{HtmlSafe{ .bytes = t }});
                if (vid.loop) |val| if (val) try w.writeAll(" loop");
                if (vid.autoplay) |val| if (val) try w.writeAll(" autoplay");
                if (vid.muted) |val| if (val) try w.writeAll(" muted");
                if (vid.controls) |val| if (val) try w.writeAll(" controls");
                if (vid.pip) |val| if (!val) {
                    try w.writeAll(" disablepictureinpicture");
                };
                try w.writeAll(">\n<source src=\"");
                try printUrl(ctx, page, vid.src.?, w, true);
                try w.writeAll("\">\n</video>");
                if (caption != null) try w.writeAll("\n<figcaption>");
            },
            .exit => {
                const caption = node.firstChild();
                if (caption != null) {
                    try w.writeAll("</figcaption></figure>");
                }
            },
        },
        .audio => |snd| switch (ev.dir) {
            .enter => {
                const caption = node.firstChild();
                if (caption != null) try w.writeAll("<figure>");
                try w.writeAll("<audio");
                if (directive.id) |id| try w.print(" id=\"{f}\"", .{HtmlSafe{ .bytes = id }});
                if (directive.attrs) |attrs| {
                    try w.writeAll(" class=\"");
                    for (attrs) |attr| try w.print("{f} ", .{HtmlSafe{ .bytes = attr }});
                    try w.writeAll("\"");
                }
                if (directive.title) |t| try w.print(" title=\"{f}\"", .{HtmlSafe{ .bytes = t }});
                if (snd.loop) |val| if (val) try w.writeAll(" loop");
                if (snd.autoplay) |val| if (val) try w.writeAll(" autoplay");
                if (snd.muted) |val| if (val) try w.writeAll(" muted");
                if (snd.hide_controls == null or !snd.hide_controls.?) {
                    try w.writeAll(" controls");
                }
                try w.writeAll(">\n<source src=\"");
                try printUrl(ctx, page, snd.src.?, w, true);
                try w.writeAll("\">\n</audio>");
                if (caption != null) try w.writeAll("\n<figcaption>");
            },
            .exit => {
                const caption = node.firstChild();
                if (caption != null) {
                    try w.writeAll("</figcaption></figure>");
                }
            },
        },
        .link => |lnk| switch (ev.dir) {
            .enter => {
                try w.writeAll("<a");
                if (directive.id) |id| try w.print(" id=\"{f}\"", .{HtmlSafe{ .bytes = id }});
                if (directive.attrs) |attrs| {
                    try w.writeAll(" class=\"");
                    for (attrs) |attr| try w.print("{f} ", .{HtmlSafe{ .bytes = attr }});
                    try w.writeAll("\"");
                }

                if (directive.title orelse node.title()) |t| {
                    try w.print(" title=\"{f}\"", .{HtmlSafe{ .bytes = t }});
                }
                try w.writeAll(" href=\"");
                try printUrl(ctx, page, lnk.src.?, w, false);
                if (lnk.ref) |r| try writeLinkSuffix(w, r);
                try w.writeAll("\"");

                if (lnk.new orelse false) {
                    try w.writeAll(" target=\"_blank\" rel=\"noopener noreferrer\"");
                }

                try w.writeAll(">");
            },
            .exit => try w.writeAll("</a>"),
        },
        .code => |code| switch (ev.dir) {
            .enter => {
                const caption = node.firstChild();
                if (caption != null) try w.writeAll("<figure>");
                if (std.mem.eql(u8, code.language orelse "", "=html")) {
                    try w.writeAll(code.src.?.url);
                } else if (std.mem.eql(u8, code.language orelse "", "=mathtex")) {
                    try w.writeAll("<script type=\"math/tex\"");
                    if (directive.id) |id| try w.print(" id=\"{f}\"", .{HtmlSafe{ .bytes = id }});
                    if (directive.attrs) |attrs| {
                        if (code.language == null) try w.writeAll(" class=\"");
                        for (attrs) |attr| try w.print("{f} ", .{HtmlSafe{ .bytes = attr }});
                    }

                    if (directive.title) |t| try w.print(" title=\"{f}\"", .{HtmlSafe{ .bytes = t }});
                    try w.writeAll(">");
                    try w.writeAll(code.src.?.url);
                    try w.writeAll("</script>");
                } else {
                    try w.writeAll("<pre");
                    if (directive.id) |id| try w.print(" id=\"{f}\"", .{HtmlSafe{ .bytes = id }});
                    if (directive.attrs) |attrs| {
                        if (code.language == null) try w.writeAll(" class=\"");
                        for (attrs) |attr| try w.print("{f} ", .{HtmlSafe{ .bytes = attr }});
                    }

                    if (directive.title) |t| try w.print(" title=\"{f}\"", .{HtmlSafe{ .bytes = t }});
                    try w.print("><code class=\"{?s}\">", .{code.language});

                    if (code.language) |lang| {
                        if (std.mem.eql(u8, lang, "console")) {
                            try highlight.runConsole(w, code.src.?.url);
                        } else {
                            highlight.run(
                                ctx._meta.io,
                                gpa,
                                lang,
                                code.src.?.url,
                                w,
                            ) catch |err| switch (err) {
                                error.OutOfMemory,
                                error.WriteFailed,
                                => |e| return e,
                                // We assert success because the language code was
                                // validated during the page analysis phase.
                                error.NoLanguage => unreachable,
                                error.Unknown => unreachable,
                            };
                        }
                    } else {
                        try w.print("{f}", .{HtmlSafe{ .bytes = code.src.?.url }});
                    }

                    try w.writeAll("</code></pre>");
                }
                if (caption != null) try w.writeAll("\n<figcaption>");
            },
            .exit => {
                const caption = node.firstChild();
                if (caption != null) {
                    try w.writeAll("</figcaption></figure>");
                }
            },
        },
    }
}

fn printUrl(
    ctx: *const context.Root,
    page: *const context.Page,
    src: supermd.context.Src,
    w: *Writer,
    allow_data: bool,
) !void {
    switch (src) {
        .url => |url| try writeUrlAttribute(w, url, allow_data),
        .self_page => |alt| if (alt) |a| {
            try ctx.printLinkPrefix(
                w,
                page._scan.variant_id,
                // We are not checking the variant id so two different pages
                // might have the same id in different variant arrays, but we
                // don't care because, when the variant is different, the full
                // host url will be printed anyway.
                // NOTE: `p.resolved.page_id` is not the same as `page._scan.page_id`
                page != ctx.page,
            );

            if (a[0] != '/') {
                const v = ctx._meta.build.variants[page._scan.variant_id];
                try writeFmtEscaped(w, "{f}", .{page._scan.url.fmt(
                    &v.string_table,
                    &v.path_table,
                    null,
                    true,
                )});
            }

            try w.print("{f}", .{
                HtmlSafe{ .bytes = std.mem.trimStart(u8, a, "/") },
            });
        },
        .page => |p| {
            try ctx.printLinkPrefix(
                w,
                p.resolved.variant_id,
                // We are not checking the variant id so two different pages
                // might have the same id in different variant arrays, but we
                // don't care because, when the variant is different, the full
                // host url will be printed anyway.
                // NOTE: `p.resolved.page_id` is not the same as `page._scan.page_id`
                page != ctx.page,
            );

            const path: Path = @fromBackingInt(@intCast(p.resolved.path));
            const v = ctx._meta.build.variants[p.resolved.variant_id];
            if (p.resolved.alt) |a| {
                if (a[0] != '/') {
                    try writeFmtEscaped(w, "{f}", .{path.fmt(
                        &v.string_table,
                        &v.path_table,
                        null,
                        true,
                    )});
                }
                try w.print("{f}", .{HtmlSafe{ .bytes = a }});
            } else {
                try writeFmtEscaped(w, "{f}", .{path.fmt(
                    &v.string_table,
                    &v.path_table,
                    null,
                    true,
                )});
            }
        },
        .page_asset => |pa| {
            try ctx.printLinkPrefix(
                w,
                page._scan.variant_id,
                page != ctx.page,
            );

            const pn: PathName = .{
                .path = @fromBackingInt(@intCast(pa.resolved.path)),
                .name = @fromBackingInt(@intCast(pa.resolved.name)),
            };

            const v = ctx._meta.build.variants[page._scan.variant_id];
            try writeFmtEscaped(w, "{f}", .{pn.fmt(
                &v.string_table,
                &v.path_table,
                null,
                "/",
            )});
        },
        .site_asset => |sa| {
            try printAssetUrlPrefix(ctx, page, w);

            const pn: PathName = .{
                .path = @fromBackingInt(@intCast(sa.resolved.path)),
                .name = @fromBackingInt(@intCast(sa.resolved.name)),
            };

            try writeFmtEscaped(w, "{f}", .{pn.fmt(
                &ctx._meta.build.st,
                &ctx._meta.build.pt,
                null,
                "/",
            )});
        },
        .build_asset => |ba| {
            try printAssetUrlPrefix(ctx, page, w);
            try w.print("{f}", .{HtmlSafe{ .bytes = ba.ref }});
        },
    }
}

pub fn printAssetUrlPrefix(
    ctx: *const context.Root,
    page: *const context.Page,
    w: *Writer,
) !void {
    switch (ctx.site._meta.kind) {
        .simple => |url_prefix_path| {
            if (ctx.page != page) {
                try w.print("{f}/", .{
                    root.fmtJoin('/', &.{
                        ctx.site.host_url,
                        url_prefix_path,
                    }),
                });
            } else if (url_prefix_path.len > 0) {
                try w.print("/{s}/", .{url_prefix_path});
            } else {
                try w.writeAll("/");
            }
        },
        .multi => |locale| {
            const assets_prefix_path = ctx._meta.build.cfg.site.multilingual.assets_prefix_path orelse "";
            if (ctx.page != page or locale.host_url_override != null) {
                try w.print("{f}", .{
                    root.fmtJoin('/', &.{
                        ctx.site.host_url,
                        assets_prefix_path,
                    }),
                });
            } else {
                try w.writeAll("/");
                if (assets_prefix_path.len > 0) {
                    try w.print("{s}/", .{assets_prefix_path});
                }
            }
        },
    }
}
fn renderLink(
    ev: Iter.Event,
    ctx: *const context.Root,
    w: *Writer,
) !void {
    _ = ctx;
    const node = ev.node;
    switch (ev.dir) {
        .enter => {
            try w.writeAll("<a href=\"");
            try writeUrlAttribute(w, node.link() orelse "", false);
            try w.writeAll("\"");
            if (node.title()) |t| {
                try w.print(" title=\"{f}\"", .{HtmlSafe{ .bytes = t }});
            }
            try w.writeAll(">");
        },
        .exit => try w.print("</a>", .{}),
    }
}

pub fn htmlToc(ast: Ast, w: *Writer) !void {
    try w.print("<ul>\n", .{});
    var lvl: i32 = 1;
    var first_item = true;
    var node: ?supermd.Node = ast.md.root.firstChild();
    while (node) |n| : (node = n.nextSibling()) {
        if (n.nodeType() != .HEADING) continue;
        defer first_item = false;

        const new_lvl = n.headingLevel();
        if (new_lvl > lvl) {
            if (first_item) {
                try w.print("<li>\n", .{});
            }
            while (new_lvl > lvl) : (lvl += 1) {
                try w.print("<ul><li>\n", .{});
            }

            try tocRenderHeading(n, w, true);
        } else if (new_lvl < lvl) {
            try w.print("</li>", .{});
            while (new_lvl < lvl) : (lvl -= 1) {
                try w.print("</ul></li>", .{});
            }
            try w.print("<li>", .{});
            try tocRenderHeading(n, w, true);
        } else {
            if (first_item) {
                try w.print("<li>", .{});
                try tocRenderHeading(n, w, true);
            } else {
                try w.print("</li><li>", .{});
                try tocRenderHeading(n, w, true);
            }
        }
    }

    while (lvl > 1) : (lvl -= 1) {
        try w.print("</li></ul>", .{});
    }

    try w.print("</ul>", .{});
}

/// Writes the text content of a raw inline HTML fragment, dropping tags.
///
/// TOC labels are plain text, so `<kbd>Ctrl</kbd>` should contribute `Ctrl`
/// rather than the literal markup.
fn writeStrippedHtml(w: *Writer, fragment: []const u8) !void {
    var in_tag = false;
    for (fragment) |ch| {
        switch (ch) {
            '<' => in_tag = true,
            '>' => in_tag = false,
            else => if (!in_tag) try w.writeByte(ch),
        }
    }
}

fn tocRenderHeading(heading: supermd.Node, w: *Writer, link: bool) !void {
    var it = Iter.init(heading);
    while (it.next()) |ev| {
        const node = ev.node;
        switch (node.nodeType()) {
            .HEADING => switch (ev.dir) {
                .enter => {
                    const dir = node.getDirective() orelse continue;
                    if (dir.id) |id| {
                        std.debug.assert(id.len > 0);
                        std.debug.assert(std.mem.trim(u8, id, "\t\n\r ").len > 0);
                        if (link) try w.print("<a href=\"#{f}\">", .{
                            HtmlSafe{ .bytes = id },
                        });
                    }
                },
                .exit => {
                    const dir = node.getDirective() orelse continue;
                    if (dir.id != null) {
                        if (link) try w.print("</a>", .{});
                    }
                },
            },
            .TEXT => switch (ev.dir) {
                .enter => try w.print("{f}", .{
                    HtmlSafe{ .bytes = node.literal() orelse "" },
                }),
                .exit => {},
            },
            .SOFTBREAK => switch (ev.dir) {
                .enter => try w.print(" ", .{}),
                .exit => {},
            },
            .LINEBREAK => switch (ev.dir) {
                .enter => try w.print("<br>", .{}),
                .exit => {},
            },
            .CODE => switch (ev.dir) {
                .enter => try w.print("<code>{f}</code>", .{
                    HtmlSafe{ .bytes = node.literal() orelse "" },
                }),
                .exit => {},
            },
            .EMPH => switch (ev.dir) {
                .enter => try w.print("<em>", .{}),
                .exit => try w.print("</em>", .{}),
            },
            .STRONG => switch (ev.dir) {
                .enter => try w.print("<strong>", .{}),
                .exit => try w.print("</strong>", .{}),
            },
            .LINK => {},
            .HTML_INLINE => switch (ev.dir) {
                .enter => if (node.literal()) |fragment| try writeStrippedHtml(w, fragment),
                .exit => {},
            },
            .IMAGE => {},
            .FOOTNOTE_REFERENCE => switch (ev.dir) {
                .enter => try w.print("[{d}]", .{node.footnoteRefIx()}),
                .exit => {},
            },
            // Extension nodes (strikethrough and friends) may carry an enum
            // value this switch does not know. Do not call `@tagName` on it:
            // render their text children instead, and fall back to the
            // literal for leaf nodes.
            else => switch (ev.dir) {
                .enter => if (node.literal()) |lit| try w.print("{f}", .{
                    HtmlSafe{ .bytes = lit },
                }),
                .exit => {},
            },
        }
    }
}

pub fn htmlTocDetails(ast: Ast, w: *Writer) !void {
    var lvl: i32 = 1;
    var first_item = true;
    var node: ?supermd.Node = ast.md.root.firstChild();
    while (node) |n| : (node = n.nextSibling()) {
        if (n.nodeType() != .HEADING) continue;
        defer first_item = false;

        const new_lvl = n.headingLevel();
        if (new_lvl > lvl) {
            // if (lvl == 1) {
            //     try w.print("<details>\n", .{});
            //     lvl += 1;
            // }
            while (new_lvl > lvl) : (lvl += 1) {
                try w.print("<ul><li>\n", .{});
            }

            // if (lvl == 1) try w.print("<summary>\n", .{});
            try tocRenderHeading(n, w, true);
            // if (lvl == 1) try w.print("</summary>\n", .{});
        } else if (new_lvl < lvl) {
            try w.print("</li>", .{});
            while (new_lvl < lvl) : (lvl -= 1) {
                try w.print("</ul></li>", .{});
            }
            if (lvl == 1) {
                try w.print("</details><details><summary>", .{});
                try tocRenderHeading(n, w, false);
                try w.print("</summary>", .{});
            } else {
                try w.print("<li>", .{});
                try tocRenderHeading(n, w, true);
            }
        } else {
            if (first_item) {
                if (lvl == 1) {
                    try w.print("<details><summary>", .{});
                    try tocRenderHeading(n, w, false);
                    try w.print("</summary>", .{});
                } else {
                    try w.print("<li>", .{});
                    try tocRenderHeading(n, w, true);
                }
            } else {
                if (lvl == 1) {
                    try w.print("</details><details><summary>", .{});
                    try tocRenderHeading(n, w, false);
                    try w.print("</summary>", .{});
                } else {
                    try w.print("</li><li>", .{});
                    try tocRenderHeading(n, w, true);
                }
            }
        }
    }

    while (lvl > 1) : (lvl -= 1) {
        try w.print("</li></ul>", .{});
    }
}
