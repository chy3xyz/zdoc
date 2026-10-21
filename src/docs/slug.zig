//! GitHub-compatible heading slug generation.
//!
//! VitePress, GitHub and most static site generators derive heading anchors by
//! slugifying the heading's plain text. Markdown that was authored for GitHub
//! carries explicit `#anchor` links pointing at those slugs, so reproducing
//! the algorithm exactly is what keeps intra-page links from breaking.
//!
//! The rules, as verified against the anchors present in
//! `zigmodu/docs` (80/82 exact match, the 2 misses being provably stale
//! anchors whose headings have since changed):
//!
//!   1. Lowercase the text.
//!   2. A space becomes a single `-`.
//!   3. `-` and `_` pass through untouched. Runs are *not* collapsed and
//!      leading/trailing `-` are *not* trimmed: GitHub produces anchors like
//!      `#-测试策略` (from `🧪 测试策略`, where stripping the emoji leaves a
//!      leading space) and `#14-...-06--012--013--...` (where a `/` is
//!      dropped between two spaces that each become a dash).
//!   4. Variation selectors are dropped. They are category `M*` and would
//!      otherwise survive step 5, leaking `U+FE0F` into the slug.
//!   5. Keep letters, numbers and marks; drop everything else. Keeping `M*` is
//!      what preserves CJK; dropping `S*` is what strips emoji.
//!
//! Slugs are deduplicated per page the way `github-slugger` does: the first
//! occurrence keeps the base, later ones get `-1`, `-2`, and so on.

const std = @import("std");
const case_table = @import("case_table.zig");
const cat_table = @import("category_table.zig");

const category_ranges = cat_table.category_ranges;

/// Returns true when the codepoint's general category is a letter, number or
/// mark, i.e. when it survives in a slug.
pub fn keepsCodepoint(cp: u21) bool {
    // The table spans the whole codepoint space, so there is always a hit.
    var lo: usize = 0;
    var hi: usize = category_ranges.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const r = category_ranges[mid];
        if (cp < r.lo) {
            hi = mid;
        } else if (cp > r.hi) {
            lo = mid + 1;
        } else {
            return r.keep;
        }
    }
    return false;
}

/// Emoji modifiers and variation selectors render as nothing but would
/// otherwise be kept by `keepsCodepoint`, since they are `M*`.
fn isVariationSelector(cp: u21) bool {
    return (cp >= 0xFE00 and cp <= 0xFE0F) or
        (cp >= 0xE0100 and cp <= 0xE01EF);
}

/// A sigma is final when the next non-case-ignorable codepoint is not cased.
/// `rest` must be positioned just after `next`.
fn isFinalSigma(next: ?u21, rest: std.unicode.Utf8Iterator) bool {
    var it = rest;
    var current = next;
    while (current) |cp| {
        if (!case_table.isCaseIgnorable(cp)) return !case_table.isCased(cp);
        current = it.nextCodepoint();
    }
    return true;
}

/// Slugifies heading text. The input should be the heading's plain text
/// (inline markup already resolved), which is what
/// `supermd.Node.renderPlaintext` produces.
pub fn slugify(
    gpa: std.mem.Allocator,
    text: []const u8,
) std.mem.Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var view = std.unicode.Utf8View.initUnchecked(text);
    var it = view.iterator();

    var current = it.nextCodepoint();
    while (current) |cp| {
        const next = it.nextCodepoint();

        var lowered: [2]u21 = undefined;
        var lowered_len: usize = 1;
        if (cp == 0x130) {
            // GitHub's `toLowerCase` emits a plain `i` plus a combining dot.
            lowered[0] = 'i';
            lowered[1] = 0x307;
            lowered_len = 2;
        } else if (cp == 0x3A3 and isFinalSigma(next, it)) {
            lowered[0] = 0x3C2;
        } else {
            lowered[0] = case_table.toLower(cp);
        }

        for (lowered[0..lowered_len]) |lower| {
            if (lower == ' ') {
                try out.append(gpa, '-');
                continue;
            }
            if (lower == '-' or lower == '_') {
                try out.append(gpa, @intCast(lower));
                continue;
            }
            if (isVariationSelector(lower)) continue;
            if (!keepsCodepoint(lower)) continue;

            var buf: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(lower, &buf) catch continue;
            try out.appendSlice(gpa, buf[0..n]);
        }

        current = next;
    }

    return out.toOwnedSlice(gpa);
}

/// Tracks the slugs already used on a page so repeated headings can be
/// deduplicated the way `github-slugger` does.
///
/// The map itself is allocated from `gpa`, but the slug strings it stores are
/// allocated from `strings`. Keeping those separate matters when `strings` is
/// an arena: an arena's `free` is a no-op, but handing it a pointer it never
/// allocated is not, so the two must not be mixed.
pub const Set = struct {
    map: std.StringHashMapUnmanaged(void) = .empty,

    /// Returns a unique slug for `text`, appending `-1`, `-2`, ... to repeats.
    /// The returned slice is owned by the set and stays valid until `deinit`.
    pub fn unique(
        self: *Set,
        strings: std.mem.Allocator,
        text: []const u8,
    ) std.mem.Allocator.Error![]const u8 {
        const base = try slugify(strings, text);

        const gop = try self.map.getOrPut(strings, base);
        if (!gop.found_existing) {
            gop.value_ptr.* = {};
            return gop.key_ptr.*;
        }
        // A repeat. The map owns the original key; this duplicate is ours to
        // drop, but only after we are done reading from it below.
        defer strings.free(base);

        // Retry with an increasing suffix until we find one that is itself
        // unused, mirroring github-slugger when a slug already ends in `-N`.
        var suffix: usize = 1;
        while (true) {
            var buf: std.ArrayList(u8) = .empty;
            errdefer buf.deinit(strings);
            try buf.appendSlice(strings, base);
            try buf.print(strings, "-{d}", .{suffix});

            if (!self.map.contains(buf.items)) {
                const owned = try buf.toOwnedSlice(strings);
                const gop2 = try self.map.getOrPut(strings, owned);
                if (gop2.found_existing) strings.free(owned);
                gop2.value_ptr.* = {};
                return gop2.key_ptr.*;
            }
            buf.deinit(strings);
            suffix += 1;
        }
    }

    /// Releases the map's bookkeeping only. The slug strings it references
    /// belong to the allocator they were created with, which is frequently a
    /// long-lived arena that must not be asked to free them.
    pub fn deinit(self: *Set, gpa: std.mem.Allocator) void {
        _ = gpa;
        self.map = .empty;
    }
};

const testing = std.testing;

fn expectSlug(expected: []const u8, text: []const u8) !void {
    const got = try slugify(testing.allocator, text);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(expected, got);
}

test "slugify: ascii basics" {
    try expectSlug("overview", "Overview");
    try expectSlug("what-is-a-module", "What is a Module?");
    // Multiple spaces each become a dash; runs are not collapsed, same as
    // literal '-' characters.
    try expectSlug("core----concepts", "Core    Concepts");
}

test "slugify: Cyrillic lowercases" {
    try expectSlug("привет", "Привет");
    try expectSlug("ёжик", "ЁЖИК");
    try expectSlug("привет-мир", "Привет, Мир!");
}

test "slugify: Greek accented capitals lowercase" {
    try expectSlug("άλφα", "Άλφα");
    try expectSlug("άλφα", "ΆΛΦΑ");
}

test "slugify: Greek final sigma is context-sensitive" {
    try expectSlug("ος", "ΟΣ");
    try expectSlug("σοφια", "ΣΟΦΙΑ");
    try expectSlug("σας", "ΣΑΣ");
    // Digits and CJK are not cased, so the sigma is still final.
    try expectSlug("ας2", "ΑΣ2");
    try expectSlug("ας中", "ΑΣ中");
    // Case-ignorable marks are skipped: a following cased letter keeps sigma
    // non-final, while a following digit still makes it final.
    try expectSlug("ασ\u{0301}β", "ΑΣ\u{0301}Β");
    try expectSlug("ας\u{0301}2", "ΑΣ\u{0301}2");
}

test "slugify: dotted capital I matches GitHub's two-codepoint lowercase" {
    try expectSlug("i\u{0307}stanbul", "İstanbul");
}

test "slugify: Latin Extended Additional lowercases" {
    try expectSlug("ạậ", "ẠẬ");
    try expectSlug("ốc", "Ốc");
}

test "slugify: CJK is kept and Latin is lowercased" {
    try expectSlug("快速开始", "快速开始");
    try expectSlug("安装-zdoc", "安装 Zdoc");
}

test "slugify: Armenian lowercases" {
    try expectSlug("արև", "Արև");
}

test "slugify: fullwidth Latin lowercases" {
    try expectSlug("ｈｅｌｌｏ-世界", "ＨＥＬＬＯ 世界");
}

test "slugify: punctuation is dropped, spaces become dashes" {
    try expectSlug("14-升级注意zent-06--012--013----076--083--086", "14. 升级注意（zent 0.6 → 0.12 → 0.13 → … → 0.76 → 0.83 → 0.86）");
}

test "slugify: leading dash survives (emoji stripped, space remains)" {
    try expectSlug("-测试策略", "🧪 测试策略");
    try expectSlug("-错误处理", "⚠️ 错误处理");
}

test "slugify: variation selectors do not leak into slugs" {
    // U+1F3D7 U+FE0F must slug to `-模块设计原则`, not `\uFE0F-模块设计原则`.
    try expectSlug("-模块设计原则", "\u{1F3D7}️ 模块设计原则");
}

test "slugify: emphasis and code marks are gone by the time we see text" {
    // The caller passes renderPlaintext output, which has already resolved
    // these. This asserts we do not mangle what remains.
    try expectSlug("bold-and-code", "bold and code");
}

test "Set: dedupes repeated headings" {
    // The slug strings outlive the set, so give them an arena.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const strings = arena_state.allocator();

    var set = Set{};
    defer set.deinit(testing.allocator);

    const a = try set.unique(strings, "Setup");
    const b = try set.unique(strings, "Setup");
    const c = try set.unique(strings, "Setup");

    try testing.expectEqualStrings("setup", a);
    try testing.expectEqualStrings("setup-1", b);
    try testing.expectEqualStrings("setup-2", c);
}

test "Set: skips over slugs that already end in a numeric suffix" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const strings = arena_state.allocator();

    var set = Set{};
    defer set.deinit(testing.allocator);

    _ = try set.unique(strings, "Setup");
    _ = try set.unique(strings, "Setup-1");
    // "Setup" repeats and must not collide with the real "setup-1" entry.
    const again = try set.unique(strings, "Setup");
    try testing.expectEqualStrings("setup-2", again);
}

// The corpus anchors below were extracted verbatim from
// `zigmodu/docs/{ZENT,BEST_PRACTICES,ROUTE_TABLE,ARCHITECTURE}.md`.
test "corpus: anchors from ZENT.md" {
    try expectSlug(
        "14-升级注意zent-06--012--013----076--083--086",
        "14. 升级注意（zent 0.6 → 0.12 → 0.13 → … → 0.76 → 0.83 → 0.86）",
    );
}

test "corpus: anchors from BEST_PRACTICES.md" {
    // Verbatim from BEST_PRACTICES.md:113. This heading mixes an emoji, a
    // variation selector, a semicolon, slashes and a bold span, and its anchor
    // is the one that proves runs of '-' must not be collapsed.
    try expectSlug(
        "-待修清单审计产出按严重度-命中的条目是-2026-09-17--2026-09-18-两批复核后已修的其余仍未修",
        "⚠️ 待修清单（审计产出，按严重度；✅ 命中的条目是 " ++
            "2026-09-17 / 2026-09-18 两批复核后已修的，其余仍未修）",
    );
    try expectSlug(
        "-质量指标可复核的不是愿望值",
        "📊 质量指标（**可复核的**，不是愿望值）",
    );
}

test "keepsCodepoint: sanity checks against the generated table" {
    try testing.expect(keepsCodepoint('a'));
    try testing.expect(keepsCodepoint('Z'));
    try testing.expect(keepsCodepoint('7'));
    try testing.expect(keepsCodepoint(0x4E2D)); // 中
    try testing.expect(keepsCodepoint(0x3042)); // あ, Lo
    try testing.expect(keepsCodepoint(0x0301)); // combining acute, Mn
    try testing.expect(!keepsCodepoint(' '));
    try testing.expect(!keepsCodepoint('.'));
    try testing.expect(!keepsCodepoint('（')); // fullwidth paren, Po
    try testing.expect(!keepsCodepoint(0x1F9EA)); // 🧪 So
    try testing.expect(!keepsCodepoint(0x26A0)); // ⚠ So
    try testing.expect(keepsCodepoint(0xFE0F)); // variation selector is Mn
}

// `keepsCodepoint` is intentionally category-based and has no idea about
// variation selectors; `slugify` is the layer that drops them. Assert both
// halves so the distinction is not lost.
test "variation selectors are filtered in slugify, not in keepsCodepoint" {
    try testing.expect(keepsCodepoint(0xFE0F));
    try expectSlug("-模块设计原则", "\u{1F3D7}️ 模块设计原则");
}
