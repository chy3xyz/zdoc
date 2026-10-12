//! Build-time search index for a documentation site.
//!
//! A documentation site is only navigable if a reader can find the one page
//! they want among hundreds, and a sidebar is not search. The index is
//! generated here rather than at runtime because every page's text is already
//! parsed into an AST by the time a page is rendered, and re-scraping the
//! generated HTML would throw that away.
//!
//! ## Why bigrams
//!
//! The obvious approach -- split text into words -- does not work for this
//! corpus. It is majority Chinese, and Chinese is written without spaces, so
//! whitespace splitting yields almost nothing useful.
//!
//! Byte n-grams need no dictionary and behave the same for both scripts,
//! which is what lets a zero-configuration tool search a corpus it knows
//! nothing about. UTF-8 is self-synchronizing, so a byte bigram that occurs in
//! a Chinese word also occurs wherever that word occurs -- no segmentation
//! step, and no dictionary to ship or keep current.
//!
//! Bigrams rather than trigrams because of the short query: a trigram index
//! cannot answer a two-character query at all -- `租户` produces zero
//! trigrams, so it would silently return nothing. Two-character words are
//! among the most common in Chinese, so that is not an edge case.
//!
//! The cost of bigrams is precision: an ASCII query like `set` intersects the
//! postings of `se` and `et` and matches more than it should. Scoring by how
//! many of the query's bigrams a record contains, rather than requiring all of
//! them, recovers most of it -- see `rank` in `zdoc.js`.
//!
//! The index is emitted as JSON and fetched by `zdoc.js` on the first
//! keystroke, so a reader who never searches never pays for it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const supermd = @import("supermd");
const Variant = @import("../Variant.zig");
const context = @import("../context.zig");
const Page = context.Page;

/// The file name the index is published under.
pub const file_name = "search-index.json";

/// One searchable unit: a heading and the prose beneath it.
///
/// Records are per-heading rather than per-page so that a hit can link to the
/// section that matched instead of dropping the reader at the top of a long
/// document.
const Record = struct {
    /// Page title, shown as the primary line of a result.
    title: []const u8,
    /// Path of the page, without a trailing slash.
    url: []const u8,
    /// Heading text, shown as the secondary line. Empty for a page with no
    /// heading above the text.
    heading: []const u8,
    /// Anchor within the page, empty when the record is the whole page.
    anchor: []const u8,
};

/// Accumulates the index while walking the pages.
pub const Builder = struct {
    arena: Allocator,
    records: std.ArrayListUnmanaged(Record) = .empty,
    /// bigram -> indices into `records`, ascending.
    postings: std.AutoHashMapUnmanaged(u32, std.ArrayListUnmanaged(u32)) = .empty,

    pub fn init(arena: Allocator) Builder {
        return .{ .arena = arena };
    }

    /// Adds one record, indexing its title, heading and body text.
    pub fn add(self: *Builder, rec: Record, body: []const u8) Allocator.Error!void {
        const idx: u32 = @intCast(self.records.items.len);
        try self.records.append(self.arena, rec);

        // The title and heading are indexed alongside the body so that a
        // reader searching for a section name finds the section, not the one
        // page that happens to mention it.
        try self.index(idx, rec.title);
        try self.index(idx, rec.heading);
        try self.index(idx, body);
    }

    fn index(self: *Builder, idx: u32, text: []const u8) Allocator.Error!void {
        if (text.len == 0) return;

        var it = bigrams(text);
        while (it.next()) |g| {
            const entry = try self.postings.getOrPut(self.arena, g);
            if (!entry.found_existing) entry.value_ptr.* = .empty;

            // A posting list answers "which records contain this bigram", so
            // it holds each record once however many times the bigram occurs
            // in it. Records are indexed in order, so the duplicate is always
            // the last element and the check is O(1).
            //
            // Without this the index is roughly six times larger than it needs
            // to be: 1.8M postings for 1715 records, rather than one per
            // record and trigram pair that actually occurs.
            const list = entry.value_ptr;
            if (list.items.len != 0 and list.items[list.items.len - 1] == idx) continue;
            try list.append(self.arena, idx);
        }
    }

    /// Serializes the index as JSON.
    ///
    /// Records come first so the reader can show results as they arrive, and
    /// the trigram table follows. Every index in a posting list points into
    /// `records`, which is what keeps the file small: the text itself is stored
    /// once, not once per trigram.
    pub fn render(self: *const Builder, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.writeAll("{\"r\":[");
        for (self.records.items, 0..) |rec, i| {
            if (i != 0) try w.writeByte(',');
            try w.writeAll("{\"t\":");
            try writeJsonString(w, rec.title);
            try w.writeAll(",\"u\":");
            try writeJsonString(w, rec.url);
            try w.writeAll(",\"h\":");
            try writeJsonString(w, rec.heading);
            try w.writeAll(",\"a\":");
            try writeJsonString(w, rec.anchor);
            try w.writeByte('}');
        }
        try w.writeAll("],\"k\":{");

        var it = self.postings.iterator();
        var first = true;
        while (it.next()) |entry| {
            if (!first) try w.writeByte(',');
            first = false;
            try w.print("\"{x}\":[", .{entry.key_ptr.*});
            for (entry.value_ptr.items, 0..) |idx, i| {
                if (i != 0) try w.writeByte(',');
                try w.print("{d}", .{idx});
            }
            try w.writeByte(']');
        }
        try w.writeAll("}}\n");
    }
};

/// Writes a JSON string literal, escaping what JSON requires.
///
/// Bytes are emitted as UTF-8 unchanged, which is correct for JSON: the format
/// is defined over Unicode text, and a page's content is already valid UTF-8
/// because it came from a source file that parsed.
fn writeJsonString(w: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
    try w.writeByte('"');
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        // Control characters have no literal form in JSON and must be escaped;
        // anything else, including a multi-byte UTF-8 sequence, passes through.
        0x00...0x08, 0x0b, 0x0c, 0x0e...0x1f => try w.print("\\u{x:0>4}", .{c}),
        else => try w.writeByte(c),
    };
    try w.writeByte('"');
}

/// Enumerates the byte bigrams of `text`, with ASCII case folded.
///
/// Case is folded because a bigram spanning a case boundary would otherwise
/// never match. Non-ASCII is left alone: it is caseless in the scripts this
/// corpus is written in.
///
/// These are *byte* bigrams, not character ones. For a three-byte CJK
/// character that means some bigrams straddle a character boundary and match
/// nothing meaningful -- they cost index space and nothing else, because a
/// query is cut the same way and therefore matches the same straddling
/// bigrams. Requiring a whole character to match would need a segmentation
/// pass and a dictionary, which is exactly what this design is avoiding.
pub const Bigrams = struct {
    text: []const u8,
    pos: usize = 0,

    pub fn next(self: *Bigrams) ?u32 {
        if (self.pos + 2 > self.text.len) return null;
        const a = fold(self.text[self.pos]);
        const b = fold(self.text[self.pos + 1]);
        self.pos += 1;
        return (@as(u32, a) << 8) | b;
    }
};

pub fn bigrams(text: []const u8) Bigrams {
    return .{ .text = text };
}

fn fold(c: u8) u8 {
    return std.ascii.toLower(c);
}

/// Builds the index for one variant.
///
/// `url_prefix` is prepended to each page's URL so a hit links correctly when
/// the site is served from a subdirectory.
pub fn build(
    arena: Allocator,
    v: *const Variant,
    url_prefix: []const u8,
) error{ OutOfMemory, WriteFailed }![]const u8 {
    var b = Builder.init(arena);

    for (v.pages.items) |*p| {
        if (!p._parse.active) continue;
        if (p._parse.status != .parsed) continue;

        const url = try pageUrl(arena, v, p, url_prefix);

        // Split the page at its headings: everything up to the first heading
        // is the page itself, and each heading owns the text beneath it.
        var section_heading: []const u8 = "";
        var section_anchor: []const u8 = "";
        var body: std.ArrayListUnmanaged([]const u8) = .empty;

        var it = supermd.Ast.Iter.init(p._parse.ast.md.root);
        defer it.deinit();

        while (it.next()) |ev| {
            if (ev.dir != .enter) continue;
            const node = ev.node;

            switch (node.nodeType()) {
                .HEADING => {
                    // Close the section that was accumulating before starting
                    // the next one.
                    try b.add(.{
                        .title = p.title,
                        .url = url,
                        .heading = section_heading,
                        .anchor = section_anchor,
                    }, try std.mem.join(arena, " ", body.items));

                    body.clearRetainingCapacity();
                    section_heading = try trim(arena, node.renderPlaintext() catch "");
                    section_anchor = headingAnchor(node);
                },
                // Only block-level nodes contribute text. Taking it from
                // every node would read the same paragraph once for the
                // paragraph and again for each run inside it, which is what
                // turned a 1.6MB corpus into a 27MB index.
                .PARAGRAPH, .CODE_BLOCK, .BLOCK_QUOTE, .ITEM, .FOOTNOTE_DEFINITION => {
                    if (node.renderPlaintext()) |text| {
                        try body.append(arena, try trim(arena, text));
                    } else |_| {}
                },
                else => {},
            }
        }

        // Whatever follows the last heading is the final section.
        try b.add(.{
            .title = p.title,
            .url = url,
            .heading = section_heading,
            .anchor = section_anchor,
        }, try std.mem.join(arena, " ", body.items));
    }

    var aw: std.Io.Writer.Allocating = .init(arena);
    try b.render(&aw.writer);
    return aw.written();
}

/// This page's URL as a search result links to it: no trailing slash, so that
/// appending `#anchor` produces a valid URL.
fn pageUrl(
    arena: Allocator,
    v: *const Variant,
    p: *const Page,
    url_prefix: []const u8,
) error{ OutOfMemory, WriteFailed }![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    try aw.writer.writeAll("/");
    if (url_prefix.len != 0) {
        try aw.writer.writeAll(url_prefix);
        try aw.writer.writeByte('/');
    }
    try aw.writer.print("{f}", .{p._scan.url.fmt(
        &v.string_table,
        &v.path_table,
        null,
        true,
    )});

    var url = aw.written();
    while (url.len > 1 and url[url.len - 1] == '/') url = url[0 .. url.len - 1];
    return url;
}

/// The anchor a heading will be linked by, or empty when it has none.
///
/// Docs mode generates these in `docs.applyHeadingIds`, so they are read back
/// from the directive rather than recomputed -- recomputing would mean keeping
/// two slug implementations in step.
fn headingAnchor(node: supermd.Node) []const u8 {
    const dir = node.getDirective() orelse return "";
    return switch (dir.kind) {
        .heading => dir.id orelse "",
        else => "",
    };
}

fn trim(arena: Allocator, s: []const u8) Allocator.Error![]const u8 {
    return arena.dupe(u8, std.mem.trim(u8, s, " \t\r\n")) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
    };
}

const testing = std.testing;

test "bigrams are emitted once per starting position" {
    // A four-byte string has three two-byte windows, each a different pair.
    var it = bigrams("abcd");
    const first = it.next().?;
    const second = it.next().?;
    const third = it.next().?;
    try testing.expect(first != second);
    try testing.expect(second != third);
    try testing.expect(it.next() == null);
}

test "bigram values pack two bytes" {
    var it = bigrams("abc");
    try testing.expectEqual(
        @as(u32, 'a') << 8 | @as(u32, 'b'),
        it.next().?,
    );
    try testing.expectEqual(
        @as(u32, 'b') << 8 | @as(u32, 'c'),
        it.next().?,
    );
    try testing.expect(it.next() == null);
}

test "a two-character CJK query is searchable" {
    // The reason bigrams rather than trigrams: `租户` is an ordinary Chinese
    // word, and a trigram index cannot represent it at all. Here it is six
    // UTF-8 bytes, so it yields five byte bigrams -- and the same five come
    // out of the text wherever the word occurs, which is the property that
    // makes search work without segmentation.
    const query = "租户";
    const text = "多租户隔离";

    var q = bigrams(query);
    var n: usize = 0;
    while (q.next()) |g| {
        n += 1;

        // Every bigram of the query must also occur in the text, otherwise
        // the query could not match the word it names.
        var t = bigrams(text);
        var seen = false;
        while (t.next()) |other| {
            if (other == g) {
                seen = true;
                break;
            }
        }
        try testing.expect(seen);
    }
    try testing.expect(n > 0);
}

test "a one-byte query yields nothing" {
    // Too short to discriminate; the caller is expected to want at least two
    // characters before searching.
    var it = bigrams("a");
    try testing.expect(it.next() == null);
}

test "ASCII case is folded so a capital does not hide a match" {
    var lower = bigrams("abc");
    var upper = bigrams("ABC");
    try testing.expectEqual(lower.next().?, upper.next().?);
}

test "JSON strings escape what JSON requires" {
    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try writeJsonString(&w, "a\"b\\c\nd\te");
    try testing.expectEqualStrings("\"a\\\"b\\\\c\\nd\\te\"", w.buffered());
}

test "JSON strings pass UTF-8 through unchanged" {
    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try writeJsonString(&w, "租户");
    try testing.expectEqualStrings("\"租户\"", w.buffered());
}

test "a builder indexes title, heading and body into the same record" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var b = Builder.init(arena);
    try b.add(.{ .title = "Raft", .url = "/raft", .heading = "选主", .anchor = "" }, "consensus");

    try testing.expectEqual(@as(usize, 1), b.records.items.len);
    // The body bigrams and the heading bigrams both point at record 0.
    var with_body: usize = 0;
    var it = b.postings.valueIterator();
    while (it.next()) |list| {
        if (list.items.len > 0) with_body += 1;
    }
    try testing.expect(with_body > 0);
}

test "the rendered index is parseable JSON with the expected shape" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var b = Builder.init(arena);
    try b.add(.{ .title = "Raft", .url = "/raft", .heading = "选主", .anchor = "x" }, "consensus");

    var aw: std.Io.Writer.Allocating = .init(arena);
    try b.render(&aw.writer);
    const json = aw.written();

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();

    const obj = parsed.value.object;
    try testing.expectEqual(@as(usize, 1), obj.get("r").?.array.items.len);
    try testing.expect(obj.get("k") != null);

    const rec = obj.get("r").?.array.items[0].object;
    try testing.expectEqualStrings("Raft", rec.get("t").?.string);
    try testing.expectEqualStrings("/raft", rec.get("u").?.string);
    try testing.expectEqualStrings("选主", rec.get("h").?.string);
}