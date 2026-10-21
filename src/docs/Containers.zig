//! VitePress-style `:::` containers, as a pre-parse rewrite.
//!
//! Documentation written for VitePress marks an aside with a fenced block:
//!
//! ```markdown
//! ::: warning Careful
//! The queue is unbounded.
//! :::
//! ```
//!
//! SuperMD has no such syntax, so it renders as three paragraphs of literal
//! `:::` text. Rather than teach the parser something it will not know about
//! next release, the container is rewritten here into the blockquote form
//! SuperMD already understands, which renders as `<div class="block warning">`
//! (or a native `<details>` for `::: details`).
//!
//! ## Why a rewrite and not an AST edit
//!
//! The rewrite happens on the source text before SuperMD sees it, which is the
//! only place the three nodes can be produced. SuperMD's `Node.setDirective`
//! attaches a directive to a node that already exists; there is no node
//! factory, so a blockquote could not be built after the fact.
//!
//! ## What makes this safe
//!
//! A `:::` inside a code fence must survive untouched -- showing a container
//! example inside a code block is the most common way to document the feature,
//! and rewriting it would corrupt the documentation of the documentation. So
//! the scan tracks fenced regions and only rewrites outside them.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// A container kind, and the class it renders as.
pub const Kind = struct {
    name: []const u8,
    class: []const u8,
};

/// The container types VitePress defines, plus `code-group` and `tabs`, which
/// are containers in the same sense.
pub const kinds = [_]Kind{
    .{ .name = "tip", .class = "tip" },
    .{ .name = "warning", .class = "warning" },
    .{ .name = "danger", .class = "danger" },
    .{ .name = "info", .class = "info" },
    .{ .name = "note", .class = "note" },
    .{ .name = "details", .class = "details" },
};

/// The kinds whose body is transformed beyond blockquoting.
///
/// `::: tabs` becomes a set of labelled tabs and `::: code-group` a set of code
/// blocks; both need the *title* syntax (`::: tip Title`) preserved, which is
/// why titles are captured rather than discarded.
fn isKnown(name: []const u8) bool {
    for (kinds) |k| {
        if (std.mem.eql(u8, k.name, name)) return true;
    }
    // These two are containers whose inner structure the template-side tab
    // script builds; they are still recognized so the block is not left as
    // literal `:::` text, and both are rewritten to a `.block.tabs` container.
    return std.mem.eql(u8, name, "code-group") or std.mem.eql(u8, name, "tabs");
}

/// Rewrites every `:::` container in `src` into SuperMD blockquote form.
///
/// Returns null when there is nothing to rewrite, so the caller can keep the
/// original buffer rather than copying it.
pub fn rewrite(
    arena: Allocator,
    src: []const u8,
) Allocator.Error!?[]const u8 {
    // A cheap pre-scan: most documents contain no `:::` at all, and this is a
    // documentation generator where most pages are ordinary prose.
    if (std.mem.indexOf(u8, src, ":::") == null) return null;

    var out: std.ArrayListUnmanaged(u8) = .empty;
    var rewrote = false;

    // Stack of open containers, so nesting depth maps to blockquote depth.
    var open: std.ArrayListUnmanaged(Kind) = .empty;
    defer open.deinit(arena);

    var lines = splitLines(arena, src) catch |err| return err;
    defer lines.deinit(arena);

    var fence: ?Fence = null;
    var fence_marker_len: usize = 0;

    for (lines.items) |line| {
        const trimmed = std.mem.trimStart(u8, line.text, " \t");

        // Inside a fenced code block nothing is rewritten, and the fence is
        // tracked only so that its closing line is recognized. Inside a
        // container every line, including the fence and its body, has to stay
        // quoted: an unquoted line would end the blockquote and leak the rest
        // of the container out of it.
        if (fence) |f| {
            if (open.items.len != 0) {
                for (0..open.items.len) |_| try out.append(arena, '>');
            }
            try out.appendSlice(arena, line.text);
            try out.append(arena, '\n');
            if (line.indent < 4 and closesFence(trimmed, f, fence_marker_len)) {
                fence = null;
            }
            continue;
        }

        if (line.indent < 4) {
            if (startsFence(trimmed, &fence_marker_len)) |f| {
                fence = f;
                if (open.items.len != 0) {
                    for (0..open.items.len) |_| try out.append(arena, '>');
                }
                try out.appendSlice(arena, line.text);
                try out.append(arena, '\n');
                continue;
            }
        }

        // An indented code block: not a fence, but equally not prose. Outside
        // a container it is copied through; inside one it still has to be
        // quoted, because an unquoted line would end the blockquote and the
        // rest of the container would leak out of it.
        if (line.indent >= 4) {
            if (open.items.len != 0) {
                for (0..open.items.len) |_| try out.append(arena, '>');
            }
            try out.appendSlice(arena, line.text);
            try out.append(arena, '\n');
            continue;
        }

        if (line.indent < 4 and std.mem.startsWith(u8, trimmed, ":::")) {
            const rest = std.mem.trim(u8, trimmed[3..], " \t");

            // `:::` alone closes the innermost container.
            if (rest.len == 0) {
                if (open.items.len == 0) {
                    // A stray closer with nothing open is the author's text,
                    // not a container. Leave it exactly as written.
                    try out.appendSlice(arena, line.text);
                    try out.append(arena, '\n');
                    continue;
                }
                _ = open.pop();
                // Keep the enclosing blockquotes open. A bare blank line
                // would close every level, so quote it at the new depth.
                if (open.items.len != 0) {
                    for (0..open.items.len) |_| try out.append(arena, '>');
                }
                try out.append(arena, '\n');
                continue;
            }

            // `::: warning Careful` -- a kind and an optional title.
            var name = rest;
            var title: []const u8 = "";
            if (std.mem.indexOfAny(u8, rest, " \t")) |sp| {
                name = rest[0..sp];
                title = std.mem.trim(u8, rest[sp..], " \t");
            }

            if (!isKnown(name)) {
                // Not one of ours. Treat the whole line as prose so an author
                // writing about `:::` syntax keeps their text intact. Inside
                // a container it still has to stay quoted.
                if (open.items.len != 0) {
                    for (0..open.items.len) |_| try out.append(arena, '>');
                }
                try out.appendSlice(arena, line.text);
                try out.append(arena, '\n');
                continue;
            }

            rewrote = true;
            try open.append(arena, kindFor(name));
            const kind = open.items[open.items.len - 1];

            // Each level of nesting is one more `>` so that SuperMD nests the
            // blockquotes, which is what produces nested containers.
            if (std.mem.eql(u8, kind.name, "details")) {
                // SuperMD only emits `<details>` when the block directive is
                // embedded in the first heading, whose text becomes the
                // `<summary>`. `collapsible(false)` leaves the element closed
                // initially, as `::: details` does in VitePress.
                const label = if (title.len != 0) title else "Details";
                for (0..open.items.len) |_| try out.append(arena, '>');
                try out.appendSlice(arena, "# [");
                try out.appendSlice(arena, label);
                try out.appendSlice(arena, "]($block.collapsible(false).attrs('");
                try out.appendSlice(arena, kind.class);
                try out.appendSlice(arena, "'))");
                try out.append(arena, '\n');
                continue;
            }

            // The directive goes on the quoted line with nothing after it;
            // the form that actually renders is
            // `>[]($block.attrs('tip'))`.
            for (0..open.items.len) |_| try out.append(arena, '>');
            try out.appendSlice(arena, "[]($block.attrs('");
            try out.appendSlice(arena, kind.class);
            try out.appendSlice(arena, "'))");

            // The title is a visible label, not syntax. Keep it on the same
            // line as the (invisible) directive so the paragraph does not
            // begin with a stray space from a soft break. Tabs take their
            // labels from the headings in the body, so a bold title here
            // would be a second, wrong label.
            const titled = title.len != 0 and
                !std.mem.eql(u8, kind.name, "tabs") and
                !std.mem.eql(u8, kind.name, "code-group");
            if (titled) {
                try out.appendSlice(arena, "**");
                try out.appendSlice(arena, title);
                try out.appendSlice(arena, "**");
            }
            try out.append(arena, '\n');
            if (titled) {
                for (0..open.items.len) |_| try out.append(arena, '>');
                try out.append(arena, '\n');
            }
            continue;
        }

        if (open.items.len == 0) {
            try out.appendSlice(arena, line.text);
            try out.append(arena, '\n');
            continue;
        }

        // Inside a container: quote the line at the current depth, and blank
        // lines become an empty quoted line, which is what keeps two
        // paragraphs in one container.
        if (line.text.len == 0) {
            for (0..open.items.len) |_| try out.append(arena, '>');
            try out.append(arena, '\n');
            continue;
        }

        // No space after the `>`: adding one puts a leading space inside the
        // paragraph text, which is visible in the rendered output.
        for (0..open.items.len) |_| try out.append(arena, '>');
        try out.appendSlice(arena, line.text);
        try out.append(arena, '\n');
    }

    if (!rewrote) return null;
    return out.items;
}

fn kindFor(name: []const u8) Kind {
    for (kinds) |k| {
        if (std.mem.eql(u8, k.name, name)) return k;
    }
    // `code-group` and `tabs` are both rendered by the template-side tab
    // script, which looks for a single `.block.tabs` container. The original
    // name is kept so the rewrite can still tell them apart.
    if (std.mem.eql(u8, name, "code-group") or std.mem.eql(u8, name, "tabs")) {
        return .{ .name = name, .class = "tabs" };
    }
    return .{ .name = name, .class = name };
}

const Fence = enum { backtick, tilde };

fn startsFence(text: []const u8, marker_len: *usize) ?Fence {
    if (text.len < 3) return null;
    const c = text[0];
    const f: Fence = switch (c) {
        '`' => .backtick,
        '~' => .tilde,
        else => return null,
    };
    var n: usize = 0;
    while (n < text.len and text[n] == c) n += 1;
    if (n < 3) return null;
    marker_len.* = n;
    return f;
}

fn closesFence(text: []const u8, f: Fence, marker_len: usize) bool {
    const c: u8 = if (f == .backtick) '`' else '~';
    var n: usize = 0;
    while (n < text.len and text[n] == c) n += 1;
    // CommonMark requires the closing fence to be at least as long as the
    // opening one, and to carry no info string.
    return n >= marker_len and std.mem.trim(u8, text, " \t").len == n;
}

const Line = struct {
    indent: usize,
    /// Line content with indentation preserved, minus the newline.
    text: []const u8,
};

fn splitLines(arena: Allocator, src: []const u8) Allocator.Error!std.ArrayListUnmanaged(Line) {
    var out: std.ArrayListUnmanaged(Line) = .empty;
    var start: usize = 0;
    while (start <= src.len) {
        const nl = std.mem.indexOfScalarPos(u8, src, start, '\n') orelse src.len;
        var text = src[start..nl];
        if (text.len > 0 and text[text.len - 1] == '\r') text = text[0 .. text.len - 1];

        // A source ending in a newline has one more (empty) span after it.
        // Emitting it would add a blank line to the output that the author
        // never wrote, which is visible wherever the text is not rewritten
        // verbatim.
        if (nl == src.len and start == src.len and text.len == 0) break;

        var indent: usize = 0;
        while (indent < text.len and text[indent] == ' ') indent += 1;

        try out.append(arena, .{ .indent = indent, .text = text });
        if (nl == src.len) break;
        start = nl + 1;
    }
    return out;
}

const testing = std.testing;

/// `rewrite` on a document that is expected to contain containers.
///
/// The arena is owned by the caller: `rewrite` returns a slice allocated from
/// it, so a helper that freed the arena before returning would hand back
/// freed memory rather than a test failure.
fn run(arena: Allocator, src: []const u8) ![]const u8 {
    return (try rewrite(arena, src)) orelse error.TestUnexpectedResult;
}

/// `rewrite` on a document that must be left alone.
fn runUnchanged(arena: Allocator, src: []const u8) !void {
    try testing.expect((try rewrite(arena, src)) == null);
}

test "a tip container becomes a blockquote block" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    const out = try run(arena_state.allocator(), "::: tip\nBe careful.\n:::\n");
    try testing.expectEqualStrings(
        ">[]($block.attrs('tip'))\n>Be careful.\n\n",
        out,
    );
}

test "a container title is rendered as a label" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const out = try run(arena, "::: warning Careful\nDanger ahead.\n:::\n");
    try testing.expect(std.mem.indexOf(u8, out, "$block.attrs('warning')") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Danger ahead.") != null);
    try testing.expect(std.mem.indexOf(u8, out, "**Careful**") != null);
}

test "a ::: inside a fenced code block is left alone" {
    // Showing a container example inside a code block is the most common way
    // to document the feature, so rewriting it would corrupt the very
    // documentation of this feature.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    try runUnchanged(arena_state.allocator(),
        \\Example:
        \\
        \\```markdown
        \\::: tip
        \\Inside the example.
        \\:::
        \\```
        \\
        \\Real text.
        \\
    );
}

test "a tilde fence is tracked too" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    try runUnchanged(arena_state.allocator(),
        \\~~~text
        \\::: tip
        \\:::
        \\~~~
        \\
    );
}

test "an indented code block inside a container is not re-quoted" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    const out = try run(arena_state.allocator(), "::: tip\n    ::: not a container\n:::\n");
    try testing.expect(std.mem.indexOf(u8, out, ">    ::: not a container") != null);
}

test "nesting produces nested blockquotes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    const out = try run(arena_state.allocator(),
        \\::: tip
        \\outer
        \\::: warning
        \\inner
        \\
        \\
        \\:::
        \\:::
        \\
    );
    try testing.expect(std.mem.indexOf(
        u8,
        out,
        ">[]($block.attrs('tip'))\n>outer\n",
    ) != null);
    try testing.expect(std.mem.indexOf(
        u8,
        out,
        ">>[]($block.attrs('warning'))\n>>inner\n",
    ) != null);
}

test "paragraphs inside a container stay separate" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    const out = try run(arena_state.allocator(), "::: info\none\n\ntwo\n:::\n");
    try testing.expect(std.mem.indexOf(u8, out, ">one\n>\n>two\n") != null);
}

test "an unknown kind is left as written" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    // `:::` with a kind zdoc does not know is an author writing about the
    // syntax, not a container. The document comes back unchanged, so the
    // caller keeps its original buffer rather than a rewritten copy.
    try runUnchanged(
        arena_state.allocator(),
        "::: notarealkind\ntext\n:::\n",
    );
}

test "a stray closing delimiter is left as written" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    try runUnchanged(
        arena_state.allocator(),
        "Just text.\n:::\nMore text.\n",
    );
}

test "a document with no containers is not rewritten at all" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    try runUnchanged(arena_state.allocator(), "# Heading\n\nJust prose.\n");
}

test "an unclosed container still renders its body" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    const out = try run(arena_state.allocator(), "::: tip\nbody without a close\n");
    try testing.expect(std.mem.indexOf(u8, out, ">body without a close\n") != null);
}

test "code-group and tabs share the tabs container class" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    for ([_][]const u8{ "code-group", "tabs" }) |name| {
        var buf: [128]u8 = undefined;
        // A title is ignored: tab labels live in the body as headings.
        const src = try std.fmt.bufPrint(&buf, "::: {s} Ignored\n## One\nbody\n:::\n", .{name});
        const out = try run(arena, src);
        try testing.expectEqualStrings(
            ">[]($block.attrs('tabs'))\n>## One\n>body\n\n",
            out,
        );
    }
}

test "a details container becomes a collapsible heading block" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    const out = try run(arena_state.allocator(), "::: details More\nHidden.\n:::\n");
    try testing.expectEqualStrings(
        "># [More]($block.collapsible(false).attrs('details'))\n>Hidden.\n\n",
        out,
    );
}

test "a details container without a title gets a default summary" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    const out = try run(arena_state.allocator(), "::: details\nHidden.\n:::\n");
    try testing.expectEqualStrings(
        "># [Details]($block.collapsible(false).attrs('details'))\n>Hidden.\n\n",
        out,
    );
}
