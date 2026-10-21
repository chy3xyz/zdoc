//! A trailing `{#custom-id}` on a heading, the syntax GitHub and Docusaurus
//! authors use for explicit anchors.
//!
//! The marker is recognized on the heading's plain text. The caller strips it
//! from the rendered title and uses `id` verbatim, without slugifying.

const std = @import("std");

pub const ExplicitId = struct {
    id: []const u8,
    /// Byte offset of the `{#` marker in the heading's plain text.
    start: usize,
};

pub fn explicitHeadingId(text: []const u8) ?ExplicitId {
    const trimmed = std.mem.trimEnd(u8, text, " \t\r\n");
    if (!std.mem.endsWith(u8, trimmed, "}")) return null;
    const start = std.mem.lastIndexOf(u8, trimmed, "{#") orelse return null;

    const id = trimmed[start + 2 .. trimmed.len - 1];
    if (id.len == 0) return null;
    // Explicit ids are author-controlled, not slugified. Reject only bytes
    // that would make the marker ambiguous; Unicode anchors are valid.
    for (id) |ch| {
        if (std.ascii.isWhitespace(ch) or ch == '{' or ch == '}' or ch == '#') {
            return null;
        }
    }
    return .{ .id = id, .start = start };
}

const testing = std.testing;

test "explicit heading id is the trailing marker" {
    const got = explicitHeadingId("Install {#install}").?;
    try testing.expectEqualStrings("install", got.id);
    try testing.expectEqual(@as(usize, "Install ".len), got.start);
}

test "explicit heading id keeps Unicode" {
    const got = explicitHeadingId("简介 {#简介}").?;
    try testing.expectEqualStrings("简介", got.id);
}

test "explicit heading id rejects an empty or ambiguous marker" {
    try testing.expect(explicitHeadingId("Title") == null);
    try testing.expect(explicitHeadingId("Title {#}") == null);
    try testing.expect(explicitHeadingId("Title {#has space}") == null);
    try testing.expect(explicitHeadingId("Title {#a#b}") == null);
}
