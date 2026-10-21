//! Checks the HTML and vendored files produced from `fixtures/docs`.
const std = @import("std");
const Io = std.Io;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.arena.allocator();
    const args = try init.minimal.args.toSlice(gpa);
    if (args.len != 2) {
        std.debug.print("usage: check_docs_fixture OUTPUT_DIR\n", .{});
        return error.BadArgs;
    }
    const root = args[1];

    const index = try read(io, gpa, root, "index.html");
    try expectContains(index, "lang=\"zh-CN\"");
    try expectContains(index, "Fixture Docs");
    try expectContains(index, "id=\"start\"");
    try expectContains(index, "快速开始");
    try expectContains(index, ">开始</a>");
    try expectContains(index, "first line");
    try expectContains(index, "second line");
    try expectContains(index, "Fixture footer");
    try expectContains(index, "href=\"/docs/");
    try expectContains(index, "doc__pager-next");
    try expectContains(index, "安装 Zdoc");

    const guide = try read(io, gpa, root, "guide/index.html");
    try expectContains(guide, "id=\"安装-zdoc\"");
    try expectContains(guide, "toc__title");
    try expectContains(guide, "On this page");
    try expectContains(guide, "doc__pager-prev");
    try expectContains(guide, "快速开始");

    const missing = try read(io, gpa, root, "404.html");
    try expectContains(missing, "lang=\"zh-CN\"");
    try expectContains(missing, "href=\"/docs/zdoc.css\"");
    try expectContains(missing, "href=\"/docs/custom.css\"");
    try expectContains(missing, "href=\"/docs/\">Back to Fixture Docs");
    try expectContains(index, "version-switch__select");
    try expectContains(index, "value=\"/docs/v0/\"");
    try expectContains(index, ">v1</option>");
    try expectContains(index, "theme-toggle");

    const script = try read(io, gpa, root, "zdoc.js");
    try expectContains(guide, "https://ziglang.org/documentation/master/");
    try expectContains(guide, "class=\"block tip\"");
    try expectContains(guide, "class=\"zig\"");
    try expectContains(guide, "data-highlight=\"1\"");
    try expectContains(guide, "code-line-no");
    try expectContains(script, "code-line-no");
    try expectContains(script, "noopener");
    try expectContains(script, ".doc h4[id]");
    try expectContains(script, "code-lang");
    try expectContains(script, "heading-anchor");
    try expectContains(script, "code-copy");
    try expectContains(script, "zdoc-theme");
    const css = try read(io, gpa, root, "zdoc.css");
    try expectContains(css, "content: \"Tip\"");
    try expectContains(css, "content: \"Warning\"");
    try expectContains(css, "code-lang");
    try expectContains(css, "data-theme=\"dark\"");
    try expectContains(css, "heading-anchor");
    try expectContains(css, "code-copy");

    const entry = try read(io, gpa, root, "mermaid.esm.min.mjs");
    try expectContains(entry, "MERMAID_ENTRY_FIXTURE");
    const chunk = try read(io, gpa, root, "chunks/mermaid.esm.min/piece.mjs");
    try expectContains(chunk, "MERMAID_CHUNK_FIXTURE");

    const loader = try read(io, gpa, root, "mermaid.js");
    try expectContains(loader, "./mermaid.esm.min.mjs");
    if (std.mem.indexOf(u8, loader, "jsdelivr") != null) {
        std.debug.print("mermaid loader still points at the CDN\n", .{});
        return error.CdnLoader;
    }
}

fn read(io: Io, gpa: std.mem.Allocator, root: []const u8, rel: []const u8) ![]u8 {
    const path = try std.fs.path.join(gpa, &.{ root, rel });
    return Io.Dir.cwd().readFileAllocOptions(
        io,
        path,
        gpa,
        .limited(8 * 1024 * 1024),
        .of(u8),
        0,
    ) catch |err| {
        std.debug.print("missing {s}: {s}\n", .{ path, @errorName(err) });
        return err;
    };
}

fn expectContains(hay: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, hay, needle) == null) {
        std.debug.print("output is missing `{s}`\n", .{needle});
        return error.Missing;
    }
}
