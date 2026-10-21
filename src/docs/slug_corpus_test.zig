//! End-to-end validation of the slugger against the anchors that actually
//! exist in `zigmodu/docs`. Two anchors are known to be stale (their headings
//! have changed since the links were written); they are listed in
//! `known_stale` so the test still documents them.

const std = @import("std");
const slug = @import("slug.zig");
const case_table = @import("case_table.zig");
const data = @import("corpus_data.zig");

/// Anchors that provably no longer have a matching heading.
const known_stale = [_][]const u8{
    // Heading is now "... 0.6 → 0.12 → 0.13 → … → 0.76 → 0.83 → 0.86",
    // but the link still says 0.27 → 0.31 → 0.37.
    "14-升级注意zent-06--012--013--027--031--037",
    // Heading is now "📊 质量指标（**可复核的**，不是愿望值）"; the link is a
    // truncated older form.
    "-质量指标",
};

test "corpus: every anchor resolves to a generated heading slug" {
    const gpa = std.testing.allocator;
    // `Set` leaves its slug strings for whoever allocated them, so give them an
    // arena here rather than the testing allocator, which checks for leaks.
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const strings = arena_state.allocator();

    var checked: usize = 0;
    var stale: usize = 0;
    var missing: usize = 0;

    for (data.corpus) |cf| {
        var set = slug.Set{};
        defer set.deinit(gpa);

        var slugs: std.ArrayList([]const u8) = .empty;
        defer slugs.deinit(gpa);

        for (cf.headings) |h| try slugs.append(gpa, try set.unique(strings, h));

        for (cf.anchors) |anchor| {
            checked += 1;
            var found = false;
            for (slugs.items) |s| {
                if (std.mem.eql(u8, s, anchor)) found = true;
            }
            if (found) continue;

            for (known_stale) |k| {
                if (std.mem.eql(u8, k, anchor)) {
                    stale += 1;
                    found = true;
                    break;
                }
            }
            if (found) continue;

            missing += 1;
            std.debug.print("UNRESOLVED {s}: #{s}\n  slugs: ", .{ cf.file, anchor });
            for (slugs.items) |s| std.debug.print("{s} | ", .{s});
            std.debug.print("\n", .{});
        }
    }

    std.debug.print("\nchecked={d} stale={d} missing={d}\n", .{ checked, stale, missing });
    try std.testing.expectEqual(@as(usize, 0), missing);
    try std.testing.expect(checked > 0);
}

test "toLower: Latin capital maps, unmapped codepoint stays" {
    // U+00C0 LATIN CAPITAL LETTER A WITH GRAVE → U+00E0.
    try std.testing.expectEqual(@as(u21, 0x00E0), case_table.toLower(0x00C0));
    // U+00D7 MULTIPLICATION SIGN sits in the gap between the Latin-1 letter
    // ranges and has no simple lowercase mapping.
    try std.testing.expectEqual(@as(u21, 0x00D7), case_table.toLower(0x00D7));
}
