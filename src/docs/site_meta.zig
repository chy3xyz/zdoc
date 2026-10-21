//! Optional chrome for a documentation site.
//!
//! `site.yaml` lives in the theme directory (`.zdoc-theme/site.yaml` next to
//! the content). It is not required: a tree with no such file builds exactly
//! as before. The keys it does understand are the ones authors otherwise have
//! to fork a layout to change.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

pub const LocaleLink = struct {
    name: []const u8,
    /// URL prefix of that locale, such as `/` or `/en/`.
    prefix: []const u8,
};

pub const VersionLink = struct {
    name: []const u8,
    /// URL prefix of that version, such as `/` or `/docs/v0/`.
    prefix: []const u8,
};

pub const Chrome = struct {
    /// File name of an image in the theme directory, shown beside the title.
    logo: []const u8 = "",
    /// Plain text for the page footer.
    footer: []const u8 = "",
    /// Link to the page source. `{path}` is replaced with the page's path
    /// relative to the content directory.
    edit_url: []const u8 = "",
    /// Site title. A `--title` flag replaces this.
    title: []const u8 = "",
    /// BCP 47 language tag. A `--lang` flag replaces this.
    lang: []const u8 = "",
    /// URL prefix, the same shape as `--url-prefix`.
    url_prefix: []const u8 = "",
    /// Vendored mermaid file or dist directory, relative to the directory
    /// `zdoc` is run from. A `--mermaid` flag replaces this.
    mermaid: []const u8 = "",
    locales: []const LocaleLink = &.{},
    /// Other published versions of this site. Each build is separate; these
    /// are links, not a second render of the current tree.
    versions: []const VersionLink = &.{},
};

pub const Parsed = struct {
    chrome: Chrome = .{},
    /// Set when the file could be read but not understood. Static, or
    /// allocated with the same allocator as the chrome strings.
    err: ?[]const u8 = null,
};

pub fn parse(gpa: Allocator, src: []const u8) error{OutOfMemory}!Parsed {
    var logo: ?[]const u8 = null;
    var footer: ?[]const u8 = null;
    var edit_url: ?[]const u8 = null;
    var title: ?[]const u8 = null;
    var lang: ?[]const u8 = null;
    var url_prefix: ?[]const u8 = null;
    var mermaid: ?[]const u8 = null;
    var locales: std.ArrayListUnmanaged(LocaleLink) = .empty;
    var versions: std.ArrayListUnmanaged(VersionLink) = .empty;
    const OpenList = enum { none, locales, versions };
    var open: OpenList = .none;
    var locale_item: ?LocaleLink = null;
    var version_item: ?VersionLink = null;

    var it = std.mem.splitScalar(u8, src, '\n');
    while (it.next()) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        if (isIgnorable(line)) continue;

        const indent = leadingSpaces(line);
        const text = std.mem.trim(u8, line, " ");
        if (indent == 0) {
            if (try finishItem(LocaleLink, "locale", gpa, &locales, &locale_item)) |err| return .{ .err = err };
            if (try finishItem(VersionLink, "version", gpa, &versions, &version_item)) |err| return .{ .err = err };
            open = .none;
            const key, const value = splitField(text) orelse return .{
                .err = "site.yaml: expected 'key: value'",
            };
            if (std.mem.eql(u8, key, "locales")) {
                if (value.len != 0) return .{ .err = "site.yaml: 'locales' is a list, not a scalar" };
                open = .locales;
                continue;
            }
            if (std.mem.eql(u8, key, "versions")) {
                if (value.len != 0) return .{ .err = "site.yaml: 'versions' is a list, not a scalar" };
                open = .versions;
                continue;
            }
            const stored = try unquote(gpa, value);
            if (stored.len == 0) return .{ .err = "site.yaml: a value is empty" };
            if (std.mem.eql(u8, key, "logo")) {
                if (!validLogo(stored)) {
                    gpa.free(stored);
                    return .{
                        .err = "site.yaml: 'logo' must be a file name in the theme directory",
                    };
                }
                if (logo != null) return .{ .err = "site.yaml: 'logo' is repeated" };
                logo = stored;
            } else if (std.mem.eql(u8, key, "footer")) {
                if (footer != null) return .{ .err = "site.yaml: 'footer' is repeated" };
                footer = stored;
            } else if (std.mem.eql(u8, key, "edit_url")) {
                if (edit_url != null) return .{ .err = "site.yaml: 'edit_url' is repeated" };
                edit_url = stored;
            } else if (std.mem.eql(u8, key, "title")) {
                if (title != null) return .{ .err = "site.yaml: 'title' is repeated" };
                title = stored;
            } else if (std.mem.eql(u8, key, "lang")) {
                if (lang != null) return .{ .err = "site.yaml: 'lang' is repeated" };
                lang = stored;
            } else if (std.mem.eql(u8, key, "url_prefix")) {
                if (url_prefix != null) return .{ .err = "site.yaml: 'url_prefix' is repeated" };
                url_prefix = stored;
            } else if (std.mem.eql(u8, key, "mermaid")) {
                if (mermaid != null) return .{ .err = "site.yaml: 'mermaid' is repeated" };
                mermaid = stored;
            } else {
                return .{ .err = try std.fmt.allocPrint(gpa, "site.yaml: unknown key '{s}'", .{key}) };
            }
            continue;
        }

        switch (open) {
            .none => return .{ .err = "site.yaml: indented line is not under 'locales' or 'versions'" },
            .locales => {
                if (try takeListLine(LocaleLink, "locale", gpa, &locales, &locale_item, text)) |err| {
                    return .{ .err = err };
                }
            },
            .versions => {
                if (try takeListLine(VersionLink, "version", gpa, &versions, &version_item, text)) |err| {
                    return .{ .err = err };
                }
            },
        }
    }

    if (try finishItem(LocaleLink, "locale", gpa, &locales, &locale_item)) |err| return .{ .err = err };
    if (try finishItem(VersionLink, "version", gpa, &versions, &version_item)) |err| return .{ .err = err };

    return .{ .chrome = .{
        .logo = logo orelse "",
        .footer = footer orelse "",
        .edit_url = edit_url orelse "",
        .title = title orelse "",
        .lang = lang orelse "",
        .url_prefix = url_prefix orelse "",
        .mermaid = mermaid orelse "",
        .locales = try locales.toOwnedSlice(gpa),
        .versions = try versions.toOwnedSlice(gpa),
    } };
}

fn finishItem(
    comptime T: type,
    comptime kind: []const u8,
    gpa: Allocator,
    list: *std.ArrayListUnmanaged(T),
    item: *?T,
) error{OutOfMemory}!?[]const u8 {
    const current = item.* orelse return null;
    item.* = null;
    if (current.name.len == 0) return "site.yaml: a " ++ kind ++ " is missing 'name'";
    if (current.prefix.len == 0) return "site.yaml: a " ++ kind ++ " is missing 'prefix'";
    try list.append(gpa, current);
    return null;
}

fn takeListLine(
    comptime T: type,
    comptime kind: []const u8,
    gpa: Allocator,
    list: *std.ArrayListUnmanaged(T),
    item: *?T,
    text: []const u8,
) error{OutOfMemory}!?[]const u8 {
    if (std.mem.startsWith(u8, text, "- ")) {
        if (try finishItem(T, kind, gpa, list, item)) |err| return err;
        item.* = .{ .name = "", .prefix = "" };
        const rest = std.mem.trim(u8, text["- ".len..], " ");
        if (rest.len == 0) return null;
        return assignLinkField(kind, gpa, &item.*.?, rest);
    }
    if (item.* == null) return "site.yaml: " ++ kind ++ " field is not under a list item";
    return assignLinkField(kind, gpa, &item.*.?, text);
}

fn assignLinkField(comptime kind: []const u8, gpa: Allocator, item: anytype, text: []const u8) error{OutOfMemory}!?[]const u8 {
    const key, const value = splitField(text) orelse return "site.yaml: expected 'key: value' in a " ++ kind;
    const stored = try unquote(gpa, value);
    if (stored.len == 0) return "site.yaml: a " ++ kind ++ " value is empty";
    if (std.mem.eql(u8, key, "name")) {
        if (item.name.len != 0) return "site.yaml: a " ++ kind ++ " repeats 'name'";
        item.name = stored;
    } else if (std.mem.eql(u8, key, "prefix")) {
        if (item.prefix.len != 0) return "site.yaml: a " ++ kind ++ " repeats 'prefix'";
        item.prefix = stored;
    } else {
        return try std.fmt.allocPrint(gpa, "site.yaml: unknown " ++ kind ++ " key '{s}'", .{key});
    }
    return null;
}

fn splitField(text: []const u8) ?struct { []const u8, []const u8 } {
    const colon = std.mem.indexOfScalar(u8, text, ':') orelse return null;
    const key = std.mem.trim(u8, text[0..colon], " ");
    const value = std.mem.trim(u8, text[colon + 1 ..], " ");
    if (key.len == 0) return null;
    return .{ key, value };
}

fn unquote(gpa: Allocator, value: []const u8) error{OutOfMemory}![]const u8 {
    if (value.len >= 2) {
        const q = value[0];
        if ((q == '"' or q == '\'') and value[value.len - 1] == q) {
            return gpa.dupe(u8, value[1 .. value.len - 1]);
        }
    }
    return gpa.dupe(u8, value);
}

fn validLogo(name: []const u8) bool {
    if (name.len == 0 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return false;
    if (std.mem.indexOfAny(u8, name, "/\\") != null) return false;
    return true;
}

fn isIgnorable(line: []const u8) bool {
    const text = std.mem.trim(u8, line, " \t");
    return text.len == 0 or text[0] == '#';
}

fn leadingSpaces(line: []const u8) usize {
    var n: usize = 0;
    while (n < line.len and line[n] == ' ') : (n += 1) {}
    return n;
}

pub fn trimSlash(s: []const u8) []const u8 {
    var out = s;
    while (out.len > 0 and out[0] == '/') out = out[1..];
    while (out.len > 0 and out[out.len - 1] == '/') out = out[0 .. out.len - 1];
    return out;
}

pub fn prefixEqual(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, trimSlash(a), trimSlash(b));
}

/// `{path}` in `template` becomes the page's content-relative source path.
pub fn applyEditTemplate(gpa: Allocator, template: []const u8, path: []const u8) error{OutOfMemory}![]u8 {
    const needle = "{path}";
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var rest = template;
    while (std.mem.indexOf(u8, rest, needle)) |at| {
        try out.appendSlice(gpa, rest[0..at]);
        try out.appendSlice(gpa, path);
        rest = rest[at + needle.len ..];
    }
    try out.appendSlice(gpa, rest);
    return out.toOwnedSlice(gpa);
}

pub fn writeLocaleHref(w: *Writer, prefix: []const u8, page_rel: []const u8) Writer.Error!void {
    try w.writeByte('/');
    const p = trimSlash(prefix);
    if (p.len != 0) {
        try w.writeAll(p);
        try w.writeByte('/');
    }
    const rel = std.mem.trim(u8, page_rel, "/");
    if (rel.len != 0) {
        try w.writeAll(rel);
        try w.writeByte('/');
    }
}

pub fn appendEscaped(w: *Writer, text: []const u8) Writer.Error!void {
    for (text) |c| switch (c) {
        '&' => try w.writeAll("&amp;"),
        '<' => try w.writeAll("&lt;"),
        '>' => try w.writeAll("&gt;"),
        '"' => try w.writeAll("&quot;"),
        else => try w.writeByte(c),
    };
}

const testing = std.testing;

test "site.yaml reads logo, footer, edit url and locales" {
    const parsed = try parse(testing.allocator,
        \\# chrome
        \\logo: logo.svg
        \\footer: "© 2026"
        \\edit_url: https://github.com/org/repo/blob/main/docs/{path}
        \\title: Fixture Docs
        \\lang: zh-CN
        \\url_prefix: /docs/
        \\mermaid: vendor/mermaid/dist
        \\locales:
        \\  - name: 中文
        \\    prefix: /
        \\  - name: English
        \\    prefix: /en/
    );
    defer {
        testing.allocator.free(parsed.chrome.logo);
        testing.allocator.free(parsed.chrome.footer);
        testing.allocator.free(parsed.chrome.edit_url);
        testing.allocator.free(parsed.chrome.title);
        testing.allocator.free(parsed.chrome.lang);
        testing.allocator.free(parsed.chrome.url_prefix);
        testing.allocator.free(parsed.chrome.mermaid);
        for (parsed.chrome.locales) |l| {
            testing.allocator.free(l.name);
            testing.allocator.free(l.prefix);
        }
        testing.allocator.free(parsed.chrome.locales);
    }
    try testing.expect(parsed.err == null);
    try testing.expectEqualStrings("logo.svg", parsed.chrome.logo);
    try testing.expectEqualStrings("© 2026", parsed.chrome.footer);
    try testing.expectEqualStrings("https://github.com/org/repo/blob/main/docs/{path}", parsed.chrome.edit_url);
    try testing.expectEqual(@as(usize, 2), parsed.chrome.locales.len);
    try testing.expectEqualStrings("中文", parsed.chrome.locales[0].name);
    try testing.expectEqualStrings("/", parsed.chrome.locales[0].prefix);
    try testing.expectEqualStrings("/en/", parsed.chrome.locales[1].prefix);
    try testing.expectEqualStrings("Fixture Docs", parsed.chrome.title);
    try testing.expectEqualStrings("zh-CN", parsed.chrome.lang);
    try testing.expectEqualStrings("/docs/", parsed.chrome.url_prefix);
    try testing.expectEqualStrings("vendor/mermaid/dist", parsed.chrome.mermaid);
}

test "site.yaml reads versions and locales in either order" {
    const versions_first =
        \\logo: logo.svg
        \\footer: "© 2026"
        \\edit_url: https://github.com/org/repo/blob/main/docs/{path}
        \\title: Fixture Docs
        \\lang: zh-CN
        \\url_prefix: /docs/
        \\mermaid: vendor/mermaid/dist
        \\versions:
        \\  - name: v1
        \\    prefix: /docs/
        \\  - name: v0
        \\    prefix: /docs/v0/
        \\locales:
        \\  - name: 中文
        \\    prefix: /
        \\  - name: English
        \\    prefix: /en/
    ;
    const locales_first =
        \\logo: logo.svg
        \\footer: "© 2026"
        \\edit_url: https://github.com/org/repo/blob/main/docs/{path}
        \\title: Fixture Docs
        \\lang: zh-CN
        \\url_prefix: /docs/
        \\mermaid: vendor/mermaid/dist
        \\locales:
        \\  - name: 中文
        \\    prefix: /
        \\  - name: English
        \\    prefix: /en/
        \\versions:
        \\  - name: v1
        \\    prefix: /docs/
        \\  - name: v0
        \\    prefix: /docs/v0/
    ;
    for ([_][]const u8{ versions_first, locales_first }) |src| {
        const parsed = try parse(testing.allocator, src);
        defer {
            testing.allocator.free(parsed.chrome.logo);
            testing.allocator.free(parsed.chrome.footer);
            testing.allocator.free(parsed.chrome.edit_url);
            testing.allocator.free(parsed.chrome.title);
            testing.allocator.free(parsed.chrome.lang);
            testing.allocator.free(parsed.chrome.url_prefix);
            testing.allocator.free(parsed.chrome.mermaid);
            for (parsed.chrome.locales) |l| {
                testing.allocator.free(l.name);
                testing.allocator.free(l.prefix);
            }
            testing.allocator.free(parsed.chrome.locales);
            for (parsed.chrome.versions) |v| {
                testing.allocator.free(v.name);
                testing.allocator.free(v.prefix);
            }
            testing.allocator.free(parsed.chrome.versions);
        }
        try testing.expect(parsed.err == null);
        try testing.expectEqual(@as(usize, 2), parsed.chrome.versions.len);
        try testing.expectEqualStrings("v1", parsed.chrome.versions[0].name);
        try testing.expectEqualStrings("/docs/", parsed.chrome.versions[0].prefix);
        try testing.expectEqualStrings("v0", parsed.chrome.versions[1].name);
        try testing.expectEqualStrings("/docs/v0/", parsed.chrome.versions[1].prefix);
        try testing.expectEqual(@as(usize, 2), parsed.chrome.locales.len);
        try testing.expectEqualStrings("中文", parsed.chrome.locales[0].name);
        try testing.expectEqualStrings("/", parsed.chrome.locales[0].prefix);
        try testing.expectEqualStrings("English", parsed.chrome.locales[1].name);
        try testing.expectEqualStrings("/en/", parsed.chrome.locales[1].prefix);
    }
}

test "site.yaml rejects a scalar versions value" {
    const parsed = try parse(testing.allocator, "versions: foo\n");
    try testing.expectEqualStrings("site.yaml: 'versions' is a list, not a scalar", parsed.err.?);
}

test "site.yaml rejects a logo path" {
    const parsed = try parse(testing.allocator, "logo: ../logo.svg\n");
    try testing.expect(parsed.err != null);
}

test "edit template substitutes the page path" {
    const href = try applyEditTemplate(
        testing.allocator,
        "https://github.com/org/repo/blob/main/docs/{path}",
        "guide/intro.md",
    );
    defer testing.allocator.free(href);
    try testing.expectEqualStrings(
        "https://github.com/org/repo/blob/main/docs/guide/intro.md",
        href,
    );
}

test "locale href joins the prefix and the page" {
    var guide: Writer.Allocating = .init(testing.allocator);
    defer guide.deinit();
    try writeLocaleHref(&guide.writer, "/en/", "guide/");
    try testing.expectEqualStrings("/en/guide/", guide.written());

    var index: Writer.Allocating = .init(testing.allocator);
    defer index.deinit();
    try writeLocaleHref(&index.writer, "/", "");
    try testing.expectEqualStrings("/", index.written());
    try testing.expect(prefixEqual("en", "/en/"));
}
