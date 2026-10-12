//! `sitemap.xml` for a documentation site.
//!
//! Search engines need to be able to enumerate the site, and a documentation
//! site is exactly the kind of thing that benefits: it has many pages, most
//! of them reachable only from the sidebar, and its internal links are the
//! whole navigation.
//!
//! The output uses site-absolute *paths*, not absolute URLs. That is a
//! deliberate deviation from the sitemap specification, which asks for full
//! URLs: docs mode is zero-config and genuinely does not know the host it will
//! be deployed to, and guessing one produces a sitemap that is wrong the
//! moment the site is published anywhere else. A reader resolves each path
//! against the host it already fetched the sitemap from, which is the same
//! host by construction.
//
//! Every path begins with `/` so that it is a valid absolute-path reference;
//! a relative path in a sitemap is ambiguous about what it is relative to.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Variant = @import("../Variant.zig");
const context = @import("../context.zig");
const Page = context.Page;

/// The file name a sitemap is published under.
pub const file_name = "sitemap.xml";

/// Renders the sitemap for one variant into `writer`.
pub fn write(
    writer: *Io.Writer,
    v: *const Variant,
) Io.Writer.Error!void {
    try writer.writeAll(
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
        \\
    );

    for (v.pages.items) |*p| {
        if (!p._parse.active) continue;
        if (p._parse.status != .parsed) continue;
        // A page the author asked to keep out of listings stays out of the
        // sitemap too: `noindex` on a page that the sitemap contradicts is a
        // contradiction a crawler will resolve by ignoring one of them.
        if (p.hidden) continue;

        try writer.writeAll("  <url><loc>/");
        // `Path.fmt` prints nothing for the root path, which would leave the
        // homepage with an empty `<loc>` -- the single most important URL in
        // the file, and the one a reader visits first.
        try writer.print("{f}", .{p._scan.url.fmt(
            &v.string_table,
            &v.path_table,
            null,
            true,
        )});
        try writer.writeAll("</loc></url>\n");
    }

    try writer.writeAll("</urlset>\n");
}

/// Escapes text for use in an XML attribute or text node.
///
/// Only the five predefined entities exist in XML, so this is the complete
/// set -- unlike HTML, there is nothing else a parser will accept.
pub fn escape(w: *Io.Writer, text: []const u8) Io.Writer.Error!void {
    for (text) |c| switch (c) {
        '&' => try w.writeAll("&amp;"),
        '<' => try w.writeAll("&lt;"),
        '>' => try w.writeAll("&gt;"),
        '"' => try w.writeAll("&quot;"),
        '\'' => try w.writeAll("&apos;"),
        else => try w.writeByte(c),
    };
}

const testing = std.testing;

test "escape covers the five XML entities" {
    var buf: [128]u8 = undefined;
    var w = Io.Writer.fixed(&buf);
    try escape(&w, "a & b < c > d \" e ' f");
    try testing.expectEqualStrings(
        "a &amp; b &lt; c &gt; d &quot; e &apos; f",
        w.buffered(),
    );
}

test "escape passes ordinary text through untouched" {
    var buf: [64]u8 = undefined;
    var w = Io.Writer.fixed(&buf);
    try escape(&w, "plain text 123");
    try testing.expectEqualStrings("plain text 123", w.buffered());
}