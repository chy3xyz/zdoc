const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Writer = std.Io.Writer;
const builtin = @import("builtin");
const options = @import("options");
const supermd = @import("supermd");
const superhtml = @import("superhtml");
const ziggy = @import("ziggy");
const tracy = @import("tracy");
const root = @import("root.zig");
const fatal = @import("fatal.zig");
const context = @import("context.zig");
const Page = context.Page;
const Build = @import("Build.zig");
const StringTable = @import("StringTable.zig");
const String = StringTable.String;
const PathTable = @import("PathTable.zig");
const Path = PathTable.Path;
const PathName = PathTable.PathName;
const Variant = @import("Variant.zig");
const Template = @import("Template.zig");
const highlight = @import("highlight.zig");
const main = @import("main.zig");
const gpa = main.gpa;
const wuffs = @import("wuffs.zig");
const docs = @import("docs.zig");
const Channel = @import("channel.zig").Channel;

const log = std.log.scoped(.worker);

// singleton
var ch_buf: [64]Job = undefined;
var ch: Channel(Job) = .init(&ch_buf);
var wg: @import("hacks/WaitGroup.zig") = undefined;
var threads: []std.Thread = &.{};

pub var started = false;
pub threadlocal var cmark: supermd.Ast.CmarkParser = undefined;
pub const extensions: [*]supermd.c.cmark_llist = undefined;

pub const Job = union(enum) {
    template_parse: struct {
        template: *Template,
        build: *const Build,
        pn: PathName,
    },
    scan: struct {
        variant: *Variant,
        base_dir: Io.Dir,
        content_dir_path: []const u8,
        variant_id: u32,
        multilingual: ?Variant.MultilingualScanParams,
        output_path_prefix: []const u8,
    },
    section_activate: struct {
        cfg: *const root.Config,
        drafts: bool,
        variant: *const Variant,
        section: *Variant.Section,
        page: *Page,
    },
    page_parse: struct {
        cfg: *const root.Config,
        drafts: bool,
        progress: std.Progress.Node,
        variant: *const Variant,
        page: *Page,
    },
    page_analyze: struct {
        progress: std.Progress.Node,
        build: *const Build,
        variant_id: u32,
        page: *Page,
    },
    page_render: struct {
        progress: std.Progress.Node,
        build: *Build,
        sites: *const std.StringArrayHashMapUnmanaged(context.Site),
        page: *Page,
        kind: RenderJobKind,
    },

    variant_assets_install: struct {
        progress: std.Progress.Node,
        variant: *const Variant,
        install_dir: Io.Dir,
    },

    leave,
};

pub fn start(io: Io) void {
    assert(!started);
    started = true;

    wg = .{ .io = io };

    supermd.c.cmark_gfm_core_extensions_ensure_registered();

    if (builtin.single_threaded) {
        cmark = supermd.Ast.CmarkParser.default();
        return;
    }

    const thread_count = @max(1, std.Thread.getCpuCount() catch 1);
    threads = gpa.alloc(std.Thread, thread_count) catch fatal.oom();

    for (0..thread_count) |idx| {
        const _cmark = supermd.Ast.CmarkParser.default();
        threads[idx] = std.Thread.spawn(
            .{ .allocator = gpa },
            workerFn,
            .{ io, _cmark },
        ) catch |err| fatal.msg("error: unable to spawn thread pool: {s}\n", .{
            @errorName(err),
        });
    }
}

pub fn stopWaitAndDeinit(io: Io) void {
    if (builtin.mode != .debug) return;
    if (builtin.single_threaded) addJob(io, .leave);

    for (threads) |_| addJob(io, .leave);
    for (threads) |t| t.join();
    gpa.free(threads);
}

var single_threaded_arena_state = std.heap.ArenaAllocator.init(gpa);
const single_threaded_arena = single_threaded_arena_state.allocator();
pub fn addJob(io: Io, job: Job) void {
    if (builtin.single_threaded) {
        const continue_ = runOneJob(io, single_threaded_arena, job);
        _ = single_threaded_arena_state.reset(.retain_capacity);

        if (builtin.mode == .debug and !continue_) {
            single_threaded_arena_state.deinit();
        }
    } else {
        wg.start();
        ch.put(io, job) catch unreachable;
    }
}

pub fn wait() void {
    if (builtin.single_threaded) return;

    wg.wait();
    wg.reset();
}

fn workerFn(
    io: Io,
    _cmark: supermd.Ast.CmarkParser,
) void {
    cmark = _cmark;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    const arena = arena_state.allocator();
    while (runOneJob(io, arena, ch.get(io) catch return)) {
        _ = arena_state.reset(.retain_capacity);
        wg.finish();
    }
}

inline fn runOneJob(
    io: Io,
    arena: Allocator,
    job: Job,
) bool {
    switch (job) {
        .leave => {
            supermd.c.cmark_parser_free(cmark.parser);
            return false;
        },
        .template_parse => |tp| tp.template.parse(
            io,
            gpa,
            arena,
            tp.build,
            tp.pn,
        ),
        .scan => |s| s.variant.scanContentDir(
            io,
            gpa,
            arena,
            s.base_dir,
            s.content_dir_path,
            s.variant_id,
            s.multilingual,
            s.output_path_prefix,
        ),
        .section_activate => |ap| ap.section.activate(
            io,
            gpa,
            ap.cfg,
            ap.drafts,
            ap.variant,
            ap.page,
        ),
        .page_parse => |pp| pp.page.parse(
            io,
            gpa,
            cmark,
            pp.cfg,
            pp.drafts,
            pp.progress,
            pp.variant,
        ),
        .page_render => |pr| renderPage(
            io,
            arena,
            pr.progress,
            pr.build,
            pr.sites,
            pr.page,
            pr.kind,
        ),
        .page_analyze => |pa| analyzePage(
            io,
            arena,
            pa.progress,
            pa.build,
            pa.variant_id,
            pa.page,
        ),

        .variant_assets_install => |vai| vai.variant.installAssets(
            io,
            vai.progress,
            vai.install_dir,
        ),
    }
    return true;
}

fn analyzePage(
    io: Io,
    arena: Allocator,
    progress: std.Progress.Node,
    build: *const Build,
    variant_id: u32,
    page: *Page,
) void {
    const zone = tracy.trace(@src());
    defer zone.end();

    assert(page._parse.status == .parsed);
    if (builtin.mode == .debug) {
        const last = page._debug.stage.swap(.analyzed, .monotonic);
        assert(last == .parsed);
    }

    const v = &build.variants[variant_id];
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const page_path = std.fmt.bufPrint(&buf, "{f}", .{
        page._scan.file.fmt(
            &v.string_table,
            &v.path_table,
            v.content_dir_path,
            "",
        ),
    }) catch unreachable;

    const p = progress.start(page_path, 1);
    defer p.end();

    // We do not set all of analysis because it might contain a missing
    // layout error put there by the main thread.
    // page._analysis = .{};

    var arena_state = page._parse.arena.promote(gpa);
    defer page._parse.arena = arena_state.state;
    const page_arena = arena_state.allocator();

    analyzeFrontmatter(page_arena, page) catch fatal.oom();
    analyzeContent(io, page_arena, arena, build, variant_id, page) catch fatal.oom();
}

fn analyzeFrontmatter(page_arena: Allocator, p: *Page) error{OutOfMemory}!void {
    // We don't validate layout because it will be validated
    // later on by the main function where we will also check
    // if the file exists or not. Leaving this check here
    // would result in duplicated error reporting.
    // if (p.layout.len == 0) try errors.append(gpa, .layout);

    const errors = &p._analysis.frontmatter;
    if (p._scan.subsection_id == 0 and p.forbid_subsections) {
        try errors.append(gpa, .forbid_subsections);
    }

    for (p.aliases, 0..) |a, aidx| {
        const is_ascii = for (a) |c| {
            if (!std.ascii.isAscii(c)) break false;
        } else true;

        if (a.len == 0 or !is_ascii) try errors.append(page_arena, .{
            .alias = @intCast(aidx),
        });
    }

    for (p.alternatives, 0..) |alt, aidx| {
        const is_ascii = for (alt.output) |c| {
            if (!std.ascii.isAscii(c)) break false;
        } else true;

        if (alt.output.len == 0 or !is_ascii) try errors.append(page_arena, .{
            .alternative = .{
                .id = @intCast(aidx),
                .kind = .output,
            },
        });

        if (alt.name.len == 0) try errors.append(page_arena, .{
            .alternative = .{
                .id = @intCast(aidx),
                .kind = .name,
            },
        });
    }
}

/// Windows-style separators are ordinary in imported documentation. Treat
/// them as `/` instead of asserting: a backslash is not a path component the
/// site generator can resolve.
fn normalizeAssetRef(arena: std.mem.Allocator, ref: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, ref, '\\') == null) return ref;
    return try std.mem.replaceOwned(u8, arena, ref, "\\", "/");
}

/// The fragment part of a link suffix. `?query#fragment` and `?query` are
/// valid suffix encodings now, so the id check must look past the query.
fn linkFragment(ref: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, ref, '#')) |i| return ref[i + 1 ..];
    if (ref.len > 0 and ref[0] == '?') return "";
    return ref;
}

fn hasUrlScheme(s: []const u8) bool {
    const colon = std.mem.indexOfScalar(u8, s, ':') orelse return false;
    const boundary = std.mem.indexOfAny(u8, s, "/?#") orelse s.len;
    if (colon >= boundary or colon == 0) return false;
    for (s[0..colon]) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '+' and byte != '-' and byte != '.') {
            return false;
        }
    }
    return true;
}

fn isHtmlTagNameByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or
        byte == '-' or byte == ':' or byte == '_' or byte == '.';
}

fn isHtmlAttrNameTerminator(byte: u8) bool {
    return std.ascii.isWhitespace(byte) or
        byte == '=' or byte == '/' or byte == '>' or byte == '<';
}

/// Finds the `</tag ...>` that ends a raw-text element, returning the index
/// just past its `>`. Returns null when the closing tag is not in this
/// literal; the caller then keeps the raw-text state for following nodes.
fn findRawTextClose(html: []const u8, from: usize, tag_name: []const u8) ?usize {
    var pos = from;
    while (std.mem.indexOfScalarPos(u8, html, pos, '<')) |lt| {
        const rest = html[lt..];
        if (rest.len > 2 + tag_name.len and rest[1] == '/' and
            std.ascii.eqlIgnoreCase(rest[2..][0..tag_name.len], tag_name))
        {
            const boundary = rest[2 + tag_name.len];
            if (std.ascii.isWhitespace(boundary) or boundary == '>' or boundary == '/') {
                const gt = std.mem.indexOfScalarPos(u8, html, lt, '>') orelse
                    return html.len;
                return gt + 1;
            }
        }
        pos = lt + 1;
    }
    return null;
}

/// Marks the asset a single URL refers to for installation. Raw HTML is
/// deliberately not rewritten, and a URL that resolves to nothing is not an
/// error: much of the HTML in imported documentation points at runtime URLs
/// or at files outside the content tree.
fn markAssetRef(
    scratch: Allocator,
    b: *const Build,
    variant: *const Variant,
    page: *const Page,
    raw_ref: []const u8,
) error{OutOfMemory}!void {
    var ref = std.mem.trim(u8, raw_ref, " \t\r\n\x0b\x0c");
    if (std.mem.indexOfAny(u8, ref, "?#")) |cut| ref = ref[0..cut];

    if (ref.len == 0) return;
    if (std.mem.startsWith(u8, ref, "//")) return;
    if (hasUrlScheme(ref)) return;

    if (ref[0] == '/') {
        // Site-root relative: content-root page assets and `static/` files
        // both live at the same output URL.
        const rel = ref[1..];
        if (rel.len == 0 or rel[rel.len - 1] == '/' or
            rel[rel.len - 1] == '\\') return;

        if (PathName.get(&variant.string_table, &variant.path_table, rel)) |pn| {
            if (variant.urls.getPtr(pn)) |hint| switch (hint.kind) {
                .page_asset => |*rc| _ = rc.fetchAdd(1, .acq_rel),
                else => {},
            };
        }

        if (PathName.get(&b.st, &b.pt, rel)) |pn| {
            if (b.site_assets.getPtr(pn)) |rc| _ = rc.fetchAdd(1, .acq_rel);
        }
        return;
    }

    // Relative to the Markdown file's directory, the same way Markdown asset
    // directives resolve in docs mode.
    if (ref[ref.len - 1] == '/') return;

    var buf: std.ArrayList(String) = .empty;
    try buf.appendSlice(scratch, page._scan.file.path.slice(&variant.path_table));

    var it = std.mem.tokenizeScalar(u8, ref, '/');
    while (it.next()) |component_bytes| {
        if (std.mem.eql(u8, component_bytes, ".")) continue;
        if (std.mem.eql(u8, component_bytes, "..")) {
            if (buf.items.len == 0) return;
            _ = buf.pop();
            continue;
        }

        const component = variant.string_table.get(component_bytes) orelse return;
        try buf.append(scratch, component);
    }

    if (buf.items.len == 0) return;
    const path_strings = buf.items[0 .. buf.items.len - 1];
    const name = buf.items[buf.items.len - 1];
    const path = variant.path_table.get(path_strings) orelse return;

    const pn: PathName = .{ .path = path, .name = name };
    if (variant.urls.getPtr(pn)) |hint| switch (hint.kind) {
        .page_asset => |*rc| _ = rc.fetchAdd(1, .acq_rel),
        else => {},
    };
}

/// Scans raw HTML for `href`, `src`, `poster` and `srcset` attributes.
///
/// `raw_text` carries `<script>`/`<style>` state across inline HTML nodes.
/// CommonMark splits inline raw HTML at tag boundaries, so the body of a
/// script can span several nodes; block HTML arrives as one literal and is
/// handled entirely within this call.
fn scanHtmlAssets(
    scratch: Allocator,
    b: *const Build,
    variant: *const Variant,
    page: *const Page,
    html: []const u8,
    raw_text: *?[]const u8,
) error{OutOfMemory}!void {
    var i: usize = 0;

    if (raw_text.*) |tag_name| {
        const next = findRawTextClose(html, 0, tag_name) orelse return;
        raw_text.* = null;
        i = next;
    }

    while (std.mem.indexOfScalarPos(u8, html, i, '<')) |lt| {
        i = lt;

        if (std.mem.startsWith(u8, html[i..], "<!--")) {
            const end = std.mem.indexOfPos(u8, html, i + 4, "-->") orelse return;
            i = end + 3;
            continue;
        }

        var j = i + 1;
        if (j >= html.len) return;
        if (html[j] == '/' or html[j] == '!' or html[j] == '?') {
            // Closing tags and declarations carry no asset attributes.
            const gt = std.mem.indexOfScalarPos(u8, html, j, '>') orelse return;
            i = gt + 1;
            continue;
        }

        const name_start = j;
        while (j < html.len and isHtmlTagNameByte(html[j])) j += 1;
        const tag_name = html[name_start..j];
        if (tag_name.len == 0) {
            i += 1;
            continue;
        }

        var self_closing = false;
        while (j < html.len) {
            while (j < html.len and std.ascii.isWhitespace(html[j])) j += 1;
            if (j >= html.len) break;
            if (html[j] == '>') {
                j += 1;
                break;
            }
            if (html[j] == '/') {
                j += 1;
                if (j < html.len and html[j] == '>') {
                    self_closing = true;
                    j += 1;
                    break;
                }
                continue;
            }

            const attr_start = j;
            while (j < html.len and !isHtmlAttrNameTerminator(html[j])) j += 1;
            const attr_name = html[attr_start..j];
            if (attr_name.len == 0) {
                j += 1;
                continue;
            }

            while (j < html.len and std.ascii.isWhitespace(html[j])) j += 1;
            if (j >= html.len or html[j] != '=') continue;
            j += 1;
            while (j < html.len and std.ascii.isWhitespace(html[j])) j += 1;
            if (j >= html.len) break;

            var value: []const u8 = "";
            if (html[j] == '"' or html[j] == '\'') {
                const quote = html[j];
                j += 1;
                const value_start = j;
                while (j < html.len and html[j] != quote) j += 1;
                value = html[value_start..j];
                if (j < html.len) j += 1;
            } else {
                const value_start = j;
                while (j < html.len and !std.ascii.isWhitespace(html[j]) and
                    html[j] != '>') j += 1;
                value = html[value_start..j];
                // In `<img src=foo.png/>` the slash belongs to the tag.
                if (j < html.len and html[j] == '>' and
                    value.len > 0 and value[value.len - 1] == '/')
                {
                    value = value[0 .. value.len - 1];
                }
            }

            if (value.len == 0) continue;
            if (std.ascii.eqlIgnoreCase(attr_name, "srcset")) {
                var candidates = std.mem.splitScalar(u8, value, ',');
                while (candidates.next()) |candidate| {
                    const desc = std.mem.trim(u8, candidate, " \t\r\n\x0b\x0c");
                    if (desc.len == 0) continue;
                    const url_end = std.mem.indexOfAny(
                        u8,
                        desc,
                        " \t\r\n\x0b\x0c",
                    ) orelse desc.len;
                    try markAssetRef(scratch, b, variant, page, desc[0..url_end]);
                }
            } else if (std.ascii.eqlIgnoreCase(attr_name, "href") or
                std.ascii.eqlIgnoreCase(attr_name, "src") or
                std.ascii.eqlIgnoreCase(attr_name, "poster"))
            {
                try markAssetRef(scratch, b, variant, page, value);
            }
        }

        i = j;
        if (!self_closing and
            (std.ascii.eqlIgnoreCase(tag_name, "script") or
                std.ascii.eqlIgnoreCase(tag_name, "style")))
        {
            if (findRawTextClose(html, i, tag_name)) |next| {
                i = next;
            } else {
                raw_text.* = tag_name;
                return;
            }
        }
    }
}

const LocalePage = struct {
    page: Page,
    path: Path,
    id: u32,
};

/// Resolves a page link that names another locale. A translation key wins
/// over the path, because localized pages often do not share a filename.
fn locateLocalePage(
    b: *const Build,
    linked: Page,
    ref: []const u8,
    locale: []const u8,
) ?LocalePage {
    const locales = switch (b.cfg.site) {
        .multilingual => |ml| ml.locales,
        .simple => return null,
    };
    const vidx: u32 = for (locales, 0..) |l, i| {
        if (std.mem.eql(u8, l.code, locale)) break @intCast(i);
    } else return null;

    const tv = &b.variants[vidx];
    if (linked.translation_key) |tk| {
        for (tv.pages.items) |candidate| {
            const other = candidate.translation_key orelse continue;
            if (!candidate._parse.active) continue;
            if (!std.mem.eql(u8, tk, other)) continue;
            return .{
                .page = candidate,
                .path = candidate._scan.url,
                .id = candidate._scan.page_id,
            };
        }
        return null;
    }

    const tpath = tv.path_table.getPathNoName(
        &tv.string_table,
        &.{},
        ref,
    ) orelse return null;
    const index_html = tv.string_table.get("index.html") orelse return null;
    const hint = tv.urls.get(.{ .path = tpath, .name = index_html }) orelse return null;
    if (hint.kind != .page_main) return null;
    const candidate = tv.pages.items[hint.id];
    if (!candidate._parse.active) return null;
    return .{
        .page = candidate,
        .path = tpath,
        .id = hint.id,
    };
}

fn analyzeContent(
    io: Io,
    page_arena: Allocator,
    scratch: Allocator,
    b: *const Build,
    variant_id: u32,
    page: *Page,
) error{OutOfMemory}!void {
    const ast = &page._parse.ast;
    const errors = &page._analysis.page;
    const warnings = &page._analysis.link_warnings;
    const variant = &b.variants[variant_id];
    const autosize = b.cfg.getImageAutosize();
    const docs_mode = b.cfg.isDocs();
    const index_smd: String = @fromBackingInt(@intCast(1));
    assert(variant.string_table.get("index.smd") == index_smd);
    const index_html: String = @fromBackingInt(@intCast(11));
    assert(variant.string_table.get("index.html") == index_html);

    // Tracks `<script>`/`<style>` bodies while traversing inline HTML nodes.
    var raw_text: ?[]const u8 = null;

    var current: ?supermd.Node = ast.md.root.firstChild();
    outer: while (current) |n| : (current = n.next(ast.md.root)) {
        if (docs_mode) {
            switch (n.nodeType()) {
                .HTML_BLOCK, .HTML_INLINE => {
                    if (n.literal()) |html| {
                        try scanHtmlAssets(scratch, b, variant, page, html, &raw_text);
                    }
                },
                else => {},
            }
        }

        if (n.nodeType() == .CODE_BLOCK) blk: {
            const fence_info = n.fenceInfo() orelse break :blk;
            var fence_it = std.mem.tokenizeScalar(u8, fence_info, ' ');
            const lang = fence_it.next() orelse break :blk;

            if (!languageExists(lang)) {
                try errors.append(page_arena, .{
                    .node = n,
                    .kind = .{
                        .unknown_language = .{
                            .lang = lang,
                        },
                    },
                });
            }

            continue :outer;
        }

        const directive = n.getDirective() orelse continue;

        switch (directive.kind) {
            .section, .block, .heading, .text, .mathtex => {},
            .code => |code| {
                const path, const base_dir = switch (code.src.?) {
                    else => unreachable,
                    .page_asset => |pa| blk: {
                        const ref = try normalizeAssetRef(page_arena, pa.ref);
                        var buf: std.ArrayList(String) = .empty;

                        // Docs mode resolves assets against the source file's
                        // directory. `guide/foo.md` writes `img.png` next to
                        // itself, not inside an imaginary `guide/foo/`.
                        const base = if (docs_mode)
                            page._scan.file.path.slice(&variant.path_table)
                        else
                            page._scan.url.slice(&variant.path_table);
                        try buf.appendSlice(scratch, base);

                        var it = std.mem.tokenizeScalar(u8, ref, '/');
                        while (it.next()) |component_bytes| {
                            if (std.mem.eql(u8, component_bytes, ".")) continue;
                            if (std.mem.eql(u8, component_bytes, "..")) {
                                if (buf.items.len == 0) {
                                    try errors.append(page_arena, .{
                                        .node = n,
                                        .kind = .{ .missing_asset = .{
                                            .ref = ref,
                                            .kind = .page,
                                        } },
                                    });
                                    continue :outer;
                                }
                                _ = buf.pop();
                                continue;
                            }

                            const component = variant.string_table.get(
                                component_bytes,
                            ) orelse {
                                try errors.append(page_arena, .{
                                    .node = n,
                                    .kind = .{
                                        .missing_asset = .{
                                            .ref = ref,
                                            .kind = .page,
                                        },
                                    },
                                });
                                continue :outer;
                            };
                            try buf.append(scratch, component);
                        }

                        const path_strings = buf.items[0 .. buf.items.len - 1];
                        const name = buf.items[buf.items.len - 1];
                        if (variant.path_table.get(path_strings)) |path| {
                            const pn: PathName = .{ .path = path, .name = name };
                            if (variant.urls.getPtr(pn)) |hint| {
                                switch (hint.kind) {
                                    .page_asset => {
                                        break :blk .{
                                            try std.fmt.allocPrint(scratch, "{f}", .{
                                                pn.fmt(
                                                    &variant.string_table,
                                                    &variant.path_table,
                                                    null,
                                                    "",
                                                ),
                                            }),
                                            variant.content_dir,
                                        };
                                    },
                                    else => {},
                                }
                            }
                        }

                        try errors.append(page_arena, .{
                            .node = n,
                            .kind = .{
                                .missing_asset = .{
                                    .ref = pa.ref,
                                    .kind = .page,
                                },
                            },
                        });
                        continue :outer;
                    },
                    .build_asset => |ba| blk: {
                        const asset = b.build_assets.get(ba.ref) orelse {
                            try errors.append(page_arena, .{
                                .node = n,
                                .kind = .{
                                    .missing_asset = .{
                                        .ref = ba.ref,
                                        .kind = .build,
                                    },
                                },
                            });
                            continue :outer;
                        };
                        break :blk .{ asset.input_path, Io.Dir.cwd() };
                    },
                    .site_asset => |*sa| blk: {
                        const ref = try normalizeAssetRef(page_arena, sa.ref);
                        if (PathName.get(&b.st, &b.pt, ref)) |pn| {
                            if (b.site_assets.contains(pn)) {
                                break :blk .{
                                    ref,
                                    // dir is not relevant because the path is
                                    // absolute
                                    b.site_assets_dir,
                                };
                            }
                        }

                        try errors.append(page_arena, .{
                            .node = n,
                            .kind = .{
                                .missing_asset = .{
                                    .ref = ref,
                                    .kind = .site,
                                },
                            },
                        });
                        continue :outer;
                    },
                };
                const src = base_dir.readFileAlloc(
                    io,
                    path,
                    page_arena,
                    .unlimited,
                ) catch |err| fatal.file(path, err);

                if (!languageExists(code.language)) {
                    try errors.append(page_arena, .{
                        .node = n,
                        .kind = .{
                            .unknown_language = .{
                                .lang = code.language.?,
                            },
                        },
                    });
                    continue :outer;
                }
                const snippet = if (code.lines) |lines| blk: {
                    var line_num: usize = 1;
                    var slice_start: usize = 0;

                    for (src, 0..) |byte, index| {
                        if (byte == '\n') {
                            line_num += 1;
                            if (line_num == lines.start) {
                                slice_start = index + 1;
                            }
                            if (line_num == lines.end + 1) {
                                break :blk src[slice_start .. index + 1];
                            }
                        }
                    }
                    break :blk src[slice_start..];
                } else src;

                directive.kind.code.src = .{ .url = snippet };
            },

            // Link, Image, Video, Audio directives
            inline else => |*val| {
                switch (val.src.?) {
                    .url => continue :outer,
                    .self_page => |*resolved_alt| {
                        // This value is only expected for Link directives.
                        if (@TypeOf(val.*) != supermd.context.Link) continue :outer;

                        if (val.alternative) |alt_name| {
                            for (page.alternatives) |alt| {
                                if (std.mem.eql(u8, alt.name, alt_name)) {
                                    resolved_alt.* = alt.output;
                                    break;
                                }
                            } else {
                                try errors.append(page_arena, .{
                                    .node = n,
                                    .kind = .{
                                        .unknown_alternative = .{
                                            .name = alt_name,
                                        },
                                    },
                                });
                                continue :outer;
                            }
                        }

                        if (val.ref) |ref| {
                            const frag = linkFragment(ref);
                            if (!val.ref_unsafe and frag.len > 0 and !ast.ids.contains(frag)) {
                                try errors.append(page_arena, .{
                                    .node = n,
                                    .kind = .{
                                        .unknown_ref = .{
                                            .ref = frag,
                                        },
                                    },
                                });
                                continue :outer;
                            }
                        }
                    },

                    .page => |*p| {
                        // This value is only expected for Link directives.
                        if (@TypeOf(val.*) != supermd.context.Link) continue :outer;

                        // `//host/path` is a protocol-relative URL. SuperMD
                        // classifies it as an absolute page link because it
                        // starts with `/`; leave it as a URL.
                        const raw_link = n.link() orelse "";
                        if (p.kind == .absolute and std.mem.startsWith(u8, raw_link, "//")) {
                            val.src = .{ .url = raw_link };
                            continue :outer;
                        }
                        // SuperMD only recognizes `mailto:` and `scheme://`
                        // as URLs. `tel:`, `data:`, and `javascript:` fall
                        // into the page branch and produce a spurious
                        // "unknown page" warning. Treat any RFC-3986 scheme
                        // as a URL; the renderer separately rejects schemes
                        // that execute code.
                        if (hasUrlScheme(raw_link)) {
                            val.src = .{ .url = raw_link };
                            continue :outer;
                        }

                        // Markdown almost always links with the file
                        // extension (`[x](OTHER.md)`), but Zine interns page
                        // URLs without it. Try the ref as written first, then
                        // again with a trailing `.md` removed.
                        var link_ref = p.ref;

                        // Sibling links keep `#fragment` and `?query` inside
                        // the ref. Resolve the path without them and give the
                        // suffix back to the directive so the renderer can
                        // append it after the resolved path. Absolute and `.`
                        // links already have their fragment in `lnk.ref`, so
                        // preserve that and merge any query into it.
                        var query: ?[]const u8 = null;
                        var fragment: ?[]const u8 = null;
                        if (@TypeOf(val.*) == supermd.context.Link) fragment = val.ref;

                        const q = std.mem.indexOfScalar(u8, link_ref, '?');
                        const h = std.mem.indexOfScalar(u8, link_ref, '#');
                        const cut = @min(
                            q orelse link_ref.len,
                            h orelse link_ref.len,
                        );
                        // Query strings come before fragments in a URL. A
                        // `?` after a `#` is part of the fragment text, not a
                        // query.
                        if (q) |qi| {
                            if (h == null or qi < h.?) {
                                query = link_ref[qi + 1 .. if (h) |hi| hi else link_ref.len];
                            }
                        }
                        if (h) |hi| {
                            fragment = link_ref[hi + 1 ..];
                        }
                        link_ref = link_ref[0..cut];

                        if (@TypeOf(val.*) == supermd.context.Link) {
                            val.ref = if (query) |qs| blk: {
                                if (fragment) |frag| {
                                    break :blk try std.fmt.allocPrint(
                                        page_arena,
                                        "?{s}#{s}",
                                        .{ qs, frag },
                                    );
                                }
                                break :blk try std.fmt.allocPrint(
                                    page_arena,
                                    "?{s}",
                                    .{qs},
                                );
                            } else fragment;
                        }

                        const path: Path = switch (p.kind) {
                            .absolute => blk: {
                                log.debug("absolute page link '{s}'", .{p.ref});
                                if (docs_mode) {
                                    if (docs.scan.resolvePageRef(
                                        variant,
                                        &.{},
                                        link_ref,
                                    )) |path| break :blk path;
                                }
                                if (variant.path_table.getPathNoName(
                                    &variant.string_table,
                                    &.{},
                                    link_ref,
                                )) |path| break :blk path;
                                if (docs_mode) {
                                    if (docs.scan.stripMdExtension(link_ref)) |stripped| {
                                        if (variant.path_table.getPathNoName(
                                            &variant.string_table,
                                            &.{},
                                            stripped,
                                        )) |path| {
                                            link_ref = stripped;
                                            break :blk path;
                                        }
                                    }
                                }
                                log.debug("page link '{s}': path not found", .{p.ref});
                                if (builtin.mode == .debug) {
                                    var it = std.mem.tokenizeScalar(u8, p.ref, '/');
                                    while (it.next()) |c| {
                                        log.debug("'{s}' -> [{?d}]", .{
                                            c, variant.string_table.get(c),
                                        });
                                    }
                                }

                                try errors.append(page_arena, .{
                                    .node = n,
                                    .kind = .{
                                        .unknown_page = .{
                                            .ref = p.ref,
                                        },
                                    },
                                });
                                continue :outer;
                            },
                            .sibling => blk: {
                                // Sibling means the path is rooted in the
                                // current page's section path. A section's own
                                // index is the exception: it lives at the
                                // section's path but is registered in its
                                // *parent's* page list, so resolving against
                                // the parent would look for its siblings in
                                // the wrong directory. In docs mode, resolve
                                // such a page against its own path.
                                //
                                // The root index is the one page with no
                                // parent section; its siblings are the other
                                // pages at the content root, which the empty
                                // prefix already handles.
                                const section_id = page._scan.parent_section_id;
                                if (section_id == 0 and !docs_mode) {
                                    try errors.append(page_arena, .{
                                        .node = n,
                                        .kind = .no_parent_section,
                                    });
                                    continue :outer;
                                }

                                const own_section: ?u32 = if (docs_mode and
                                    page._scan.subsection_id != 0)
                                    page._scan.subsection_id
                                else
                                    null;

                                const prefix: []const String = if (section_id == 0)
                                    &.{}
                                else if (own_section) |sid|
                                    variant.sections.items[sid]
                                        .content_sub_path
                                        .slice(&variant.path_table)
                                else
                                    variant.sections.items[section_id]
                                        .content_sub_path
                                        .slice(&variant.path_table);

                                if (docs_mode) {
                                    // Docs mode goes through the shared
                                    // resolver so that a sibling link written
                                    // with `../` climbs the same way a `.`
                                    // link does.
                                    if (docs.scan.resolvePageRef(
                                        variant,
                                        prefix,
                                        link_ref,
                                    )) |resolved| break :blk resolved;
                                } else if (variant.path_table.getPathNoName(
                                    &variant.string_table,
                                    prefix,
                                    link_ref,
                                )) |path| {
                                    break :blk path;
                                }

                                try errors.append(page_arena, .{
                                    .node = n,
                                    .kind = .{
                                        .unknown_page = .{
                                            .ref = p.ref,
                                        },
                                    },
                                });
                                continue :outer;
                            },
                            .sub => blk: {
                                // Subpage means that the final path is
                                // based on the current page's URL path.
                                //
                                // Docs mode resolves against the page's own
                                // directory rather than requiring an index
                                // page. The blog dialect has to insist on a
                                // section index, because that is what defines
                                // a section there; in a plain Markdown tree
                                // every page is a page, and gating on it
                                // rejected `./other.md` from any ordinary
                                // document -- 171 spurious warnings on the
                                // zigmodu corpus.
                                var buf: std.ArrayList(String) = .empty;
                                try buf.appendSlice(scratch, page._scan.file.path.slice(
                                    &variant.path_table,
                                ));

                                if (docs_mode) {
                                    // `docs/scan.resolvePageRef` also strips
                                    // the `..` components SuperMD leaves in
                                    // place, which is what makes
                                    // `[x](../../ref/Y.md)` work.
                                    if (docs.scan.resolvePageRef(
                                        variant,
                                        buf.items,
                                        link_ref,
                                    )) |resolved| break :blk resolved;
                                } else {
                                    const is_index_page = page._scan.file.name == index_smd;
                                    if (!is_index_page) {
                                        try errors.append(page_arena, .{
                                            .node = n,
                                            .kind = .not_a_section,
                                        });
                                        continue :outer;
                                    }

                                    if (variant.path_table.getPathNoName(
                                        &variant.string_table,
                                        buf.items,
                                        link_ref,
                                    )) |path| break :blk path;
                                }

                                try errors.append(page_arena, .{
                                    .node = n,
                                    .kind = .{
                                        .unknown_page = .{
                                            .ref = p.ref,
                                        },
                                    },
                                });
                                continue :outer;
                            },
                        };

                        const pn: PathName = .{ .path = path, .name = index_html };
                        const hint = variant.urls.get(pn) orelse {
                            log.debug("absolute page link '{s}': hint not found", .{
                                p.ref,
                            });
                            try errors.append(page_arena, .{
                                .node = n,
                                .kind = .{
                                    .unknown_page = .{
                                        .ref = p.ref,
                                    },
                                },
                            });
                            continue :outer;
                        };

                        log.debug("absolute page link '{s}' hint: {any}", .{ p.ref, hint });
                        switch (hint.kind) {
                            .page_main => {
                                // A link to a draft or excluded page resolves
                                // to a URL that is never written. Treat it as
                                // unresolved rather than emitting a 404.
                                if (!variant.pages.items[hint.id]._parse.active) {
                                    try errors.append(page_arena, .{
                                        .node = n,
                                        .kind = .{
                                            .unknown_page = .{
                                                .ref = p.ref,
                                            },
                                        },
                                    });
                                    continue :outer;
                                }
                            },
                            else => {
                                log.debug("absolute page link '{s}' wrong kint kind: {any}", .{ p.ref, hint.kind });
                                try errors.append(page_arena, .{
                                    .node = n,
                                    .kind = .{
                                        .resource_kind_mismatch = .{
                                            .expected = .page_main,
                                            .got = hint.kind,
                                        },
                                    },
                                });
                                continue :outer;
                            },
                        }

                        const other_page, const resolved_path, const resolved_id = if (p.locale) |loc| blk: {
                            const located = locateLocalePage(b, variant.pages.items[hint.id], link_ref, loc) orelse {
                                try errors.append(page_arena, .{
                                    .node = n,
                                    .kind = .{
                                        .unknown_page = .{
                                            .ref = p.ref,
                                        },
                                    },
                                });
                                continue :outer;
                            };
                            break :blk .{ located.page, located.path, located.id };
                        } else .{
                            variant.pages.items[hint.id],
                            path,
                            hint.id,
                        };

                        p.resolved = .{
                            .page_id = resolved_id,
                            .variant_id = other_page._scan.variant_id,
                            .path = @backingInt(resolved_path),
                        };

                        if (val.alternative) |alt_name| {
                            log.debug("absolute page link '{s}' has alternative: {s}", .{
                                p.ref,
                                alt_name,
                            });
                            for (other_page.alternatives) |alt| {
                                if (std.mem.eql(u8, alt.name, alt_name)) {
                                    p.resolved.alt = alt.output;
                                    break;
                                }
                            } else {
                                try errors.append(page_arena, .{
                                    .node = n,
                                    .kind = .{
                                        .unknown_alternative = .{
                                            .name = alt_name,
                                        },
                                    },
                                });
                                continue :outer;
                            }
                        }

                        if (val.ref) |ref| {
                            const frag = linkFragment(ref);
                            if (!val.ref_unsafe and frag.len > 0 and
                                !other_page._parse.ast.ids.contains(frag))
                            {
                                try errors.append(page_arena, .{
                                    .node = n,
                                    .kind = .{
                                        .unknown_ref = .{
                                            .ref = frag,
                                        },
                                    },
                                });
                                continue :outer;
                            }
                        }
                    },

                    .page_asset => |*pa| {
                        const ref = try normalizeAssetRef(page_arena, pa.ref);
                        var buf: std.ArrayList(String) = .empty;

                        // See the matching code-directive branch: docs assets
                        // live next to the Markdown file, not under the
                        // page's generated URL.
                        const base = if (docs_mode)
                            page._scan.file.path.slice(&variant.path_table)
                        else
                            page._scan.url.slice(&variant.path_table);
                        try buf.appendSlice(scratch, base);

                        var it = std.mem.tokenizeScalar(u8, ref, '/');
                        while (it.next()) |component_bytes| {
                            if (std.mem.eql(u8, component_bytes, ".")) continue;
                            if (std.mem.eql(u8, component_bytes, "..")) {
                                if (buf.items.len == 0) {
                                    try errors.append(page_arena, .{
                                        .node = n,
                                        .kind = .{ .missing_asset = .{
                                            .ref = ref,
                                            .kind = .page,
                                        } },
                                    });
                                    continue :outer;
                                }
                                _ = buf.pop();
                                continue;
                            }

                            const component = variant.string_table.get(
                                component_bytes,
                            ) orelse {
                                try errors.append(page_arena, .{
                                    .node = n,
                                    .kind = .{
                                        .missing_asset = .{
                                            .ref = ref,
                                            .kind = .page,
                                        },
                                    },
                                });
                                continue :outer;
                            };
                            try buf.append(scratch, component);
                        }

                        const path_strings = buf.items[0 .. buf.items.len - 1];
                        const name = buf.items[buf.items.len - 1];
                        if (variant.path_table.get(path_strings)) |path| {
                            const pn: PathName = .{ .path = path, .name = name };
                            if (variant.urls.getPtr(pn)) |hint| {
                                switch (hint.kind) {
                                    .page_asset => |*rc| {
                                        // TODO: when going from zero to one
                                        //       grab image size info if needed
                                        _ = rc.fetchAdd(1, .acq_rel);
                                        pa.resolved = .{
                                            .path = @backingInt(path),
                                            .name = @backingInt(name),
                                        };

                                        const bytes = try std.fmt.allocPrint(scratch, "{f}", .{
                                            pn.fmt(
                                                &variant.string_table,
                                                &variant.path_table,
                                                null,
                                                "/",
                                            ),
                                        });

                                        if (autosize and directive.kind == .image and directive.kind.image.size == null) {
                                            wuffs.setImageSize(
                                                io,
                                                scratch,
                                                directive,
                                                variant.content_dir,
                                                bytes,
                                            );
                                        }
                                        continue :outer;
                                    },
                                    else => {},
                                }
                            }
                        }

                        try errors.append(page_arena, .{
                            .node = n,
                            .kind = .{
                                .missing_asset = .{
                                    .ref = pa.ref,
                                    .kind = .page,
                                },
                            },
                        });
                        continue :outer;
                    },
                    .site_asset => |*sa| { //ref
                        const ref = try normalizeAssetRef(page_arena, sa.ref);

                        const dirname = std.fs.path.dirnamePosix(ref) orelse "";
                        if (b.pt.getPathNoName(&b.st, &.{}, dirname)) |path| {
                            const basename = std.fs.path.basenamePosix(ref);
                            if (b.st.get(basename)) |name| {
                                const pn: PathName = .{
                                    .path = path,
                                    .name = name,
                                };

                                if (b.site_assets.getPtr(pn)) |rc| {
                                    _ = rc.fetchAdd(1, .acq_rel);
                                    sa.resolved = .{
                                        .path = @backingInt(path),
                                        .name = @backingInt(name),
                                    };

                                    if (autosize and directive.kind == .image and directive.kind.image.size == null) {
                                        wuffs.setImageSize(
                                            io,
                                            scratch,
                                            directive,
                                            b.site_assets_dir,
                                            ref,
                                        );
                                    }
                                    continue :outer;
                                }
                            }
                        }

                        try errors.append(page_arena, .{
                            .node = n,
                            .kind = .{
                                .missing_asset = .{
                                    .ref = ref,
                                    .kind = .site,
                                },
                            },
                        });
                        continue :outer;
                    },
                    .build_asset => |*ba| {
                        const asset = b.build_assets.getPtr(ba.ref) orelse {
                            try errors.append(page_arena, .{
                                .node = n,
                                .kind = .{
                                    .missing_asset = .{
                                        .ref = ba.ref,
                                        .kind = .build,
                                    },
                                },
                            });
                            continue :outer;
                        };

                        if (autosize and directive.kind == .image and directive.kind.image.size == null) {
                            wuffs.setImageSize(
                                io,
                                scratch,
                                directive,
                                b.site_assets_dir,
                                asset.input_path,
                            );
                        }

                        _ = asset.rc.fetchAdd(1, .acq_rel);

                        const output_path = asset.install_path orelse {
                            try errors.append(page_arena, .{
                                .node = n,
                                .kind = .{
                                    .build_asset_missing_install_path = .{
                                        .ref = ba.ref,
                                    },
                                },
                            });
                            continue :outer;
                        };

                        ba.ref = output_path;
                    },
                }
            },
        }
    }

    // In docs mode, link problems are reported as warnings instead of failing
    // the build. Documentation imported from GitHub routinely points at files
    // outside the docs tree (`../AGENTS.md`, `../examples/`) and at code
    // fences in languages this build cannot highlight. Failing on those would
    // make the tool unusable on real projects.
    //
    // Diverting the accumulated errors here, rather than at each of the two
    // dozen places that append them, keeps the policy in one place.
    if (docs_mode and errors.items.len > 0) {
        for (errors.items) |err| {
            // A link that never resolved still carries a `.page` source whose
            // `resolved` field was never assigned. Rendering it as-is would
            // read uninitialised memory and emit garbage URLs, so rewrite it to
            // emit exactly what the author wrote.
            _ = docs.passthroughLink(page_arena, err.node) catch |e| switch (e) {
                error.OutOfMemory => fatal.oom(),
            };
            try warnings.append(page_arena, err);
        }
        errors.clearRetainingCapacity();
    }
}

pub const RenderJobKind = union(enum) { main, alternative: u32 };
const SuperVM = superhtml.VM(context.Value);
fn renderPage(
    io: Io,
    arena: Allocator,
    progress: std.Progress.Node,
    build: *Build,
    sites: *const std.StringArrayHashMapUnmanaged(context.Site),
    page: *Page,
    kind: RenderJobKind,
) void {
    renderPageInner(io, arena, progress, build, sites, page, kind) catch |err| switch (err) {
        error.OutOfMemory => fatal.oom(),
    };
}

fn renderPageInner(
    io: Io,
    arena: Allocator,
    progress: std.Progress.Node,
    build: *Build,
    sites: *const std.StringArrayHashMapUnmanaged(context.Site),
    page: *Page,
    kind: RenderJobKind,
) !void {
    const zone = tracy.trace(@src());
    defer zone.end();

    const variant_id = page._scan.variant_id;
    const variant = &build.variants[variant_id];

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const page_path = std.fmt.bufPrint(&buf, "{f}", .{
        page._scan.file.fmt(
            &variant.string_table,
            &variant.path_table,
            variant.content_dir_path,
            "",
        ),
    }) catch unreachable;

    tracy.messageCopy(page_path);

    const progress_name = switch (kind) {
        .main => page_path,
        .alternative => |idx| blk: {
            const alt_name = page.alternatives[idx].name;
            break :blk try std.fmt.allocPrint(arena, "{s} (alternative '{s}')", .{
                page_path,
                alt_name,
            });
        },
    };

    const p = progress.start(progress_name, 0);
    defer p.end();

    var ctx: context.Root = .{
        .site = &sites.entries.items(.value)[variant_id],
        .page = page,
        .i18n = variant.i18n,
        .build = undefined,
        ._meta = .{
            .io = io,
            .build = build,
            .sites = sites,
        },
    };

    ctx.build.generated = .initNow(io);
    ctx.build.development = build.mode == .memory;

    const layout_path = switch (kind) {
        .main => page.layout,
        .alternative => |idx| page.alternatives[idx].layout,
    };

    const layout_pn = PathName.get(&build.st, &build.pt, layout_path).?;
    const layout = build.templates.get(layout_pn).?;
    assert(layout.layout);

    var out_aw: Writer.Allocating = .init(gpa);
    var err_aw: Writer.Allocating = .init(gpa);
    defer if (build.mode == .disk) err_aw.deinit();

    var super_vm = SuperVM.init(
        arena,
        &ctx,
        layout_path,
        build.cfg.getLayoutsDirPath(),
        layout.src,
        layout.html_ast,
        layout.ast,
        std.mem.endsWith(u8, layout_path, ".xml"),
        page_path,
        &out_aw.writer,
        &err_aw.writer,
    );

    while (true) super_vm.run() catch |err| switch (err) {
        error.Done => break,
        error.Fatal => {
            std.debug.print("{s}\n", .{err_aw.written()});
            build.any_rendering_error.store(true, .release);
            if (build.mode == .memory) {
                switch (kind) {
                    .main => page._render.errors = err_aw.written(),
                    .alternative => |aidx| page._render.alternatives[aidx].errors = err_aw.written(),
                }
            }
            return;
        },
        error.OutOfMemory => fatal.oom(),
        error.OutIO, error.ErrIO => fatal.msg("i/o error in superhtml", .{}),
        error.Quota => super_vm.setQuota(100),
        error.WantSnippet => {
            const name = switch (super_vm.state) {
                .want_snippet => |snippet| snippet,
                else => "unknown",
            };
            std.debug.print(
                "error: layout requested snippet '{s}', and zdoc has nowhere to load it from\n",
                .{name},
            );
            build.any_rendering_error.store(true, .release);
            if (build.mode == .memory) {
                switch (kind) {
                    .main => page._render.errors = err_aw.written(),
                    .alternative => |aidx| page._render.alternatives[aidx].errors = err_aw.written(),
                }
            }
            return;
        },
        error.WantTemplate => {
            const template_subpath = super_vm.wantedTemplateName();
            const template_path = try root.join(
                arena,
                &.{
                    "templates",
                    template_subpath,
                },
                '/',
            );

            const template_pn = PathName.get(&build.st, &build.pt, template_path).?;
            const t = build.templates.get(template_pn).?;
            assert(!t.layout);

            super_vm.insertTemplate(
                // full template path
                try root.join(
                    arena,
                    &.{
                        build.cfg.getLayoutsDirPath(),
                        template_path,
                    },
                    '/',
                ),
                t.src,
                t.html_ast,
                t.ast,
                std.mem.endsWith(u8, template_subpath, ".xml"),
            );
        },
    };

    switch (build.mode) {
        .memory => switch (kind) {
            .main => {
                page._render.out = out_aw.written();
                page._render.errors = "";
            },
            .alternative => |aidx| {
                page._render.alternatives[aidx].out = out_aw.written();
                page._render.alternatives[aidx].errors = "";
            },
        },
        .disk => |disk| {
            defer out_aw.deinit();
            const out_raw = switch (kind) {
                .main => blk: {
                    // aliases
                    for (page.aliases) |a| {
                        const out_path = if (a[0] == '/') a[1..] else switch (build.cfg.site) {
                            .simple => try std.fmt.allocPrint(arena, "{f}{s}", .{
                                page._scan.url.fmt(
                                    &variant.string_table,
                                    &variant.path_table,
                                    null,
                                    true,
                                ),
                                a,
                            }),
                            .multilingual => try std.fmt.allocPrint(arena, "{f}{s}", .{
                                page._scan.url.fmt(
                                    &variant.string_table,
                                    &variant.path_table,
                                    variant.output_path_prefix,
                                    true,
                                ),
                                a,
                            }),
                        };

                        if (std.fs.path.dirnamePosix(out_path)) |path| {
                            disk.output_dir.createDirPath(
                                io,
                                path,
                            ) catch |err| fatal.dir(path, err);
                        }

                        const f = disk.output_dir.createFile(
                            io,
                            out_path,
                            .{},
                        ) catch |err| fatal.file(out_path, err);
                        defer f.close(io);
                        var file_writer = f.writerStreaming(io, &.{});
                        file_writer.interface.writeAll(out_aw.written()) catch |err| fatal.file(
                            out_path,
                            err,
                        );
                    }

                    // main
                    {
                        const out_dir_path = switch (build.cfg.site) {
                            .simple => try std.fmt.allocPrint(arena, "{f}", .{
                                page._scan.url.fmt(
                                    &variant.string_table,
                                    &variant.path_table,
                                    null,
                                    true,
                                ),
                            }),
                            .multilingual => try std.fmt.allocPrint(arena, "{f}", .{
                                page._scan.url.fmt(
                                    &variant.string_table,
                                    &variant.path_table,
                                    variant.output_path_prefix,
                                    true,
                                ),
                            }),
                        };

                        // note: do not close build.install_dir
                        var out_dir = if (out_dir_path.len == 0) disk.output_dir else disk.output_dir.createDirPathOpen(
                            io,
                            out_dir_path,
                            .{},
                        ) catch |err| fatal.dir(out_dir_path, err);
                        defer if (out_dir_path.len > 0) out_dir.close(io);

                        break :blk out_dir.createFile(
                            io,
                            "index.html",
                            .{},
                        ) catch |err| fatal.file("index.html", err);
                    }
                },

                .alternative => |idx| blk: {
                    const raw_path = page.alternatives[idx].output;
                    const out_path = if (raw_path[0] == '/') raw_path[1..] else switch (build.cfg.site) {
                        .simple => try std.fmt.allocPrint(arena, "{f}{s}", .{
                            page._scan.url.fmt(
                                &variant.string_table,
                                &variant.path_table,
                                null,
                                true,
                            ),
                            raw_path,
                        }),
                        .multilingual => try std.fmt.allocPrint(arena, "{f}{s}", .{
                            page._scan.url.fmt(
                                &variant.string_table,
                                &variant.path_table,
                                variant.output_path_prefix,
                                true,
                            ),
                            raw_path,
                        }),
                    };

                    if (std.fs.path.dirnamePosix(out_path)) |path| {
                        disk.output_dir.createDirPath(
                            io,
                            path,
                        ) catch |err| fatal.dir(path, err);
                    }

                    break :blk disk.output_dir.createFile(
                        io,
                        out_path,
                        .{},
                    ) catch |err| fatal.file(out_path, err);
                },
            };
            defer out_raw.close(io);

            var file_writer = out_raw.writer(io, &.{});
            file_writer.interface.writeAll(out_aw.written()) catch |err| fatal.file(
                page_path,
                err,
            );
        },
    }
}

// Null language evaluates to true for convenience.
pub fn languageExists(language: ?[]const u8) bool {
    if (!options.enable_treesitter) return true;

    const lang = language orelse return true;
    if (std.mem.eql(u8, lang, "=html")) return true;
    if (std.mem.eql(u8, lang, "=mathtex")) return true;
    if (std.mem.eql(u8, lang, "console")) return true;
    // Diagrams are rendered by mermaid.js in the browser, not by tree-sitter,
    // so the language is known even though there is no grammar for it.
    if (std.mem.eql(u8, lang, "mermaid")) return true;
    // Plain text and shell transcripts are documentation, not code to
    // highlight. Treating them as unknown made the whole page unbuildable.
    if (std.mem.eql(u8, lang, "text")) return true;
    if (std.mem.eql(u8, lang, "txt")) return true;

    const syntax = @import("syntax");
    if (syntax.FileType.get_by_name_static(lang) == null) {
        var buf: [1024]u8 = undefined;
        const filename = std.fmt.bufPrint(
            &buf,
            "file.{s}",
            .{lang},
        ) catch "<lang name too long>";

        const guess = syntax.FileType.guess_static(filename, "") orelse return false;
        log.debug("guessed '{?s}' as '{s}'", .{ language, guess.name });
    }

    return true;
}
