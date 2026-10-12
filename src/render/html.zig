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

fn taskState(node: supermd.Node) TaskState {
    const checked = c.cmark_gfm_extensions_get_tasklist_item_checked(node.n);
    if (checked) return .{ .is_task = true, .checked = true };

    _ = c.cmark_gfm_extensions_set_tasklist_item_checked(node.n, true);
    const is_task = c.cmark_gfm_extensions_get_tasklist_item_checked(node.n);
    _ = c.cmark_gfm_extensions_set_tasklist_item_checked(node.n, false);

    return .{ .is_task = is_task, .checked = false };
}

const log = std.log.scoped(.render);

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

                    if (d.id) |id| try w.print(" id=\"{s}\"", .{id});
                    try w.print(" class=\"block", .{});
                    if (d.attrs) |attrs| {
                        for (attrs) |attr| try w.print(" {s}", .{attr});
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
                .enter => try w.print("<{s}>", .{
                    @tagName(node.listType()),
                }),
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
                            "<li class=\"task-list-item\"><input type=\"checkbox\" disabled{s}>",
                            .{if (task.checked) " checked" else ""},
                        );
                    } else {
                        try w.print("<li>", .{});
                    }
                },
                .exit => try w.print("</li>", .{}),
            },
            .HTML_BLOCK => switch (ev.dir) {
                .enter => try w.print(
                    "{s}",
                    .{node.literal() orelse ""},
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
                            if (d.id) |id| try w.print(" id=\"{s}\"", .{id});
                            if (d.attrs) |attrs| {
                                try w.print(" class=\"", .{});
                                for (attrs) |attr| try w.print("{s} ", .{attr});
                                try w.print("\"", .{});
                            }

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
                            if (d.id) |id| try w.print(" id=\"{s}\"", .{id});
                            if (d.attrs) |attrs| {
                                try w.print(" class=\"", .{});
                                for (attrs) |attr| try w.print("{s} ", .{attr});
                                try w.print("\"", .{});
                            }

                            try w.print(">", .{});
                            continue;
                        },
                        .section => {
                            if (open_div) {
                                try w.print("</div>", .{});
                            }
                            open_div = true;
                            try w.print("<div", .{});
                            if (d.id) |id| try w.print(" id=\"{s}\"", .{id});
                            if (d.attrs) |attrs| {
                                try w.print(" class=\"", .{});
                                for (attrs) |attr| try w.print("{s} ", .{attr});
                                try w.print("\"", .{});
                            }

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
                .enter => try w.print(
                    "{s}",
                    .{node.literal() orelse ""},
                ),
                .exit => @panic("custom inline"),
            },
            .CUSTOM_INLINE => switch (ev.dir) {
                .enter => @panic("custom inline"),
                .exit => {},
            },
            .TEXT => switch (ev.dir) {
                .enter => try w.print("{s}", .{
                    node.literal() orelse "",
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
            .LINK, .IMAGE => try renderDirective(gpa, ctx, page, ast, ev, w),
            .CODE_BLOCK => switch (ev.dir) {
                .exit => {},
                .enter => {
                    if (node.literal()) |code| {
                        const fence_info = node.fenceInfo() orelse "";
                        if (std.mem.trim(u8, fence_info, " \n").len == 0) {
                            try w.print("<pre><code>{f}</code></pre>", .{
                                HtmlSafe{ .bytes = code },
                            });
                        } else {
                            var fence_it = std.mem.tokenizeScalar(u8, fence_info, ' ');
                            const lang_name = fence_it.next().?;

                            if (std.mem.eql(u8, lang_name, "=html")) {
                                try w.writeAll(code);
                                continue;
                            } else if (std.mem.eql(u8, lang_name, "=mathtex")) {
                                try w.writeAll("<script type=\"math/tex\">");
                                try w.writeAll(code);
                                try w.writeAll("</script>");
                                continue;
                            } else if (std.mem.eql(u8, lang_name, "mermaid")) {
                                // Diagrams are drawn by mermaid.js in the
                                // browser, so emit the source as a plain block
                                // rather than trying to highlight it here.
                                try w.print("<pre class=\"mermaid\">{f}</pre>", .{
                                    HtmlSafe{ .bytes = code },
                                });
                                continue;
                            }

                            try w.print("<pre><code class=\"{s}\">", .{lang_name});

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
                        }
                    }
                },
            },

            else => |nt| if (@intFromEnum(nt) == c.CMARK_NODE_STRIKETHROUGH) switch (ev.dir) {
                .enter => try w.writeAll("<del>"),
                .exit => try w.writeAll("</del>"),
            } else if (@intFromEnum(nt) == c.CMARK_NODE_TABLE) switch (ev.dir) {
                .enter => {
                    table_alignments = node.getTableAlignments();
                    try w.writeAll("<table>");
                },
                .exit => {
                    table_alignments = &.{};
                    try w.writeAll("</table>");
                },
            } else if (@intFromEnum(nt) == c.CMARK_NODE_TABLE_ROW) switch (ev.dir) {
                .enter => {
                    table_in_header = node.isTableHeader();
                    try w.writeAll("<tr>");
                },
                .exit => {
                    table_in_header = !node.isTableHeader();
                    table_cell_id = 0;
                    try w.writeAll("</tr>");
                },
            } else if (@intFromEnum(nt) == c.CMARK_NODE_TABLE_CELL) switch (ev.dir) {
                .enter => {
                    if (table_in_header) {
                        try w.writeAll("<th");
                    } else {
                        try w.writeAll("<td");
                    }

                    if (table_cell_id < table_alignments.len) {
                        const char = table_alignments[table_cell_id];
                        if (char != 0) try w.print(" align='{s}'", .{
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
                if (directive.id) |id| try w.print(" id=\"{s}\"", .{id});
                if (directive.attrs) |attrs| {
                    try w.writeAll(" class=\"");
                    for (attrs) |attr| try w.print("{s} ", .{attr});
                    try w.writeAll("\"");
                }
                if (directive.title) |t| try w.print(" title=\"{s}\"", .{t});
                try w.writeAll(">");
                try w.writeAll(katek.formula);
            },
            .exit => {
                try w.writeAll("</script>");
            },
        },
        .text => switch (ev.dir) {
            .enter => {
                try w.print("<span", .{});
                if (directive.id) |id| try w.print(" id=\"{s}\"", .{id});
                if (directive.attrs) |attrs| {
                    try w.print(" class=\"", .{});
                    for (attrs) |attr| try w.print("{s} ", .{attr});
                    try w.print("\"", .{});
                }
                if (directive.title) |t| try w.print(" title=\"{s}\"", .{t});
                try w.print(">", .{});
            },
            .exit => {
                try w.print("</span>", .{});
            },
        },
        .image => |img| switch (ev.dir) {
            .enter => {
                const caption = node.firstChild();
                if (caption != null) try w.writeAll("<figure>");
                if (img.linked) |l| if (l) {
                    try w.writeAll("<a href=\"");
                    try printUrl(ctx, page, img.src.?, w);
                    try w.writeAll("\">");
                };

                try w.writeAll("<img");
                if (directive.id) |id| try w.print(" id=\"{s}\"", .{id});
                if (directive.attrs) |attrs| {
                    try w.writeAll(" class=\"");
                    for (attrs) |attr| try w.print("{s} ", .{attr});
                    try w.writeAll("\"");
                }
                if (directive.title) |t| try w.print(" title=\"{s}\"", .{t});
                try w.writeAll(" src=\"");
                try printUrl(ctx, page, img.src.?, w);
                try w.writeAll("\"");

                if (img.alt) |alt| try w.print(" alt=\"{s}\"", .{alt});
                if (img.size) |size| {
                    if (size.w > 0) try w.print(" width=\"{d}\"", .{size.w});
                    if (size.h > 0) try w.print(" height=\"{d}\"", .{size.h});
                }
                try w.writeAll(">");
                if (img.linked) |l| if (l) try w.writeAll("</a>");
                if (caption != null) try w.writeAll("\n<figcaption>");
            },
            .exit => {
                const caption = node.firstChild();
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
                if (directive.id) |id| try w.print(" id=\"{s}\"", .{id});
                if (directive.attrs) |attrs| {
                    try w.writeAll(" class=\"");
                    for (attrs) |attr| try w.print("{s} ", .{attr});
                    try w.writeAll("\"");
                }
                if (directive.title) |t| try w.print(" title=\"{s}\"", .{t});
                if (vid.loop) |val| if (val) try w.writeAll(" loop");
                if (vid.autoplay) |val| if (val) try w.writeAll(" autoplay");
                if (vid.muted) |val| if (val) try w.writeAll(" muted");
                if (vid.controls) |val| if (val) try w.writeAll(" controls");
                if (vid.pip) |val| if (!val) {
                    try w.writeAll(" disablepictureinpicture");
                };
                try w.writeAll(">\n<source src=\"");
                try printUrl(ctx, page, vid.src.?, w);
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
                if (directive.id) |id| try w.print(" id=\"{s}\"", .{id});
                if (directive.attrs) |attrs| {
                    try w.writeAll(" class=\"");
                    for (attrs) |attr| try w.print("{s} ", .{attr});
                    try w.writeAll("\"");
                }
                if (directive.title) |t| try w.print(" title=\"{s}\"", .{t});
                if (snd.loop) |val| if (val) try w.writeAll(" loop");
                if (snd.autoplay) |val| if (val) try w.writeAll(" autoplay");
                if (snd.muted) |val| if (val) try w.writeAll(" muted");
                if (snd.hide_controls == null or !snd.hide_controls.?) {
                    try w.writeAll(" controls");
                }
                try w.writeAll(">\n<source src=\"");
                try printUrl(ctx, page, snd.src.?, w);
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
                if (directive.id) |id| try w.print(" id=\"{s}\"", .{id});
                if (directive.attrs) |attrs| {
                    try w.writeAll(" class=\"");
                    for (attrs) |attr| try w.print("{s} ", .{attr});
                    try w.writeAll("\"");
                }

                if (directive.title) |t| try w.print(" title=\"{s}\"", .{t});
                try w.writeAll(" href=\"");
                try printUrl(ctx, page, lnk.src.?, w);
                if (lnk.ref) |r| try w.print("#{s}", .{r});
                try w.writeAll("\"");

                if (lnk.new orelse false) {
                    try w.writeAll(" target=\"_blank\"");
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
                    if (directive.id) |id| try w.print(" id=\"{s}\"", .{id});
                    if (directive.attrs) |attrs| {
                        if (code.language == null) try w.writeAll(" class=\"");
                        for (attrs) |attr| try w.print("{s} ", .{attr});
                    }

                    if (directive.title) |t| try w.print(" title=\"{s}\"", .{t});
                    try w.writeAll(">");
                    try w.writeAll(code.src.?.url);
                    try w.writeAll("</script>");
                } else {
                    try w.writeAll("<pre");
                    if (directive.id) |id| try w.print(" id=\"{s}\"", .{id});
                    if (directive.attrs) |attrs| {
                        if (code.language == null) try w.writeAll(" class=\"");
                        for (attrs) |attr| try w.print("{s} ", .{attr});
                    }

                    if (directive.title) |t| try w.print(" title=\"{s}\"", .{t});
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
) !void {
    switch (src) {
        .url => |url| try w.writeAll(url),
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
                try w.print("{f}", .{page._scan.url.fmt(
                    &v.string_table,
                    &v.path_table,
                    null,
                    true,
                )});
            }

            try w.writeAll(std.mem.trimStart(u8, a, "/"));
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

            const path: Path = @enumFromInt(p.resolved.path);
            const v = ctx._meta.build.variants[p.resolved.variant_id];
            if (p.resolved.alt) |a| {
                if (a[0] != '/') {
                    try w.print("{f}", .{path.fmt(
                        &v.string_table,
                        &v.path_table,
                        null,
                        true,
                    )});
                }
                try w.writeAll(a);
            } else {
                try w.print("{f}", .{path.fmt(
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
                .path = @enumFromInt(pa.resolved.path),
                .name = @enumFromInt(pa.resolved.name),
            };

            const v = ctx._meta.build.variants[page._scan.variant_id];
            try w.print("{f}", .{pn.fmt(
                &v.string_table,
                &v.path_table,
                null,
                "/",
            )});
        },
        .site_asset => |sa| {
            try printAssetUrlPrefix(ctx, page, w);

            const pn: PathName = .{
                .path = @enumFromInt(sa.resolved.path),
                .name = @enumFromInt(sa.resolved.name),
            };

            try w.print("{f}", .{pn.fmt(
                &ctx._meta.build.st,
                &ctx._meta.build.pt,
                null,
                "/",
            )});
        },
        .build_asset => |ba| {
            try printAssetUrlPrefix(ctx, page, w);
            try w.print("{s}", .{ba.ref});
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
            try w.print("<a href=\"{s}\">", .{
                node.link() orelse "",
            });
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

fn tocRenderHeading(heading: supermd.Node, w: *Writer, link: bool) !void {
    var it = Iter.init(heading);
    while (it.next()) |ev| {
        const node = ev.node;
        switch (node.nodeType()) {
            else => std.debug.panic(
                "TODO: implement toc '{s}' inline rendering",
                .{@tagName(node.nodeType())},
            ),
            .HEADING => switch (ev.dir) {
                .enter => {
                    const dir = node.getDirective() orelse continue;
                    if (dir.id) |id| {
                        std.debug.assert(id.len > 0);
                        std.debug.assert(std.mem.trim(u8, id, "\t\n\r ").len > 0);
                        if (link) try w.print("<a href=\"#{s}\">", .{id});
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
                .enter => try w.print("{s}", .{
                    node.literal() orelse "",
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
