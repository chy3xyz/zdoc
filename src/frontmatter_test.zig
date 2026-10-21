//! Standalone entry point for the docs-mode modules' unit tests.
//!
//! Both reach into the context module for the template value types, so a
//! module rooted at `src/docs/` cannot resolve them. Rooting the test at
//! `src/` puts the whole tree in scope while leaving the production module
//! boundaries where they are.

const std = @import("std");
const frontmatter = @import("docs/frontmatter.zig");

test {
    _ = @import("docs/frontmatter.zig");
    _ = @import("docs/GitDates.zig");
    _ = @import("docs/Search.zig");
    _ = @import("docs/Sitemap.zig");
    _ = @import("docs/Containers.zig");
    _ = @import("docs/Exclude.zig");
    _ = @import("docs.zig");
    _ = @import("docs/Sidebar.zig");
}

test "block scalar | keeps newlines and |- drops the final one" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const r = try frontmatter.parse(arena_state.allocator(),
        \\description: |-
        \\  color: #fff
        \\
        \\  width: 10
    );
    try std.testing.expectEqualStrings("color: #fff\n\nwidth: 10", r.fields.description.?);
}

test "block scalar > folds lines and breaks on a blank line" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const r = try frontmatter.parse(arena_state.allocator(),
        \\description: >
        \\  first line
        \\  second line
        \\
        \\  third line
        \\title: T
    );
    try std.testing.expectEqualStrings("first line second line\nthird line\n", r.fields.description.?);
    try std.testing.expectEqualStrings("T", r.fields.title.?);
}

test "sidebar_label bare scalar is kept" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const r = try frontmatter.parse(arena_state.allocator(),
        \\sidebar_label: Getting Started
    );
    try std.testing.expectEqualStrings("Getting Started", r.fields.sidebar_label.?);
    try std.testing.expectEqual(@as(usize, 0), r.skipped.len);
}