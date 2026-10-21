const std = @import("std");
const Io = std.Io;
const options = @import("options");
const fatal = @import("../fatal.zig");
const Allocator = std.mem.Allocator;

pub fn init(io: Io, gpa: Allocator, args: []const []const u8) bool {
    _ = gpa;

    const cmd: Command = .parse(args);
    enterDir(io, cmd.dir);

    const File = struct { path: []const u8, src: []const u8 };
    const zine_src = if (cmd.multilingual)
        std.fmt.comptimePrint(@embedFile("init/zine-multilingual.ziggy"), .{options.version})
    else
        std.fmt.comptimePrint(@embedFile("init/zine.ziggy"), .{options.version});
    const files = [_]File{
        .{
            .path = ".zine.ziggy-schema",
            .src = @embedFile("../schemas/zine.ziggy-schema"),
        },
        .{
            .path = "zine.ziggy",
            .src = zine_src,
        },
        .{
            .path = "content/.smd.ziggy-schema",
            .src = @embedFile("../schemas/page.ziggy-schema"),
        },
        .{
            .path = "content/index.smd",
            .src = @embedFile("init/content/index.smd"),
        },
        .{
            .path = "content/product/index.smd",
            .src = @embedFile("init/content/product/index.smd"),
        },
        .{
            .path = "content/blog/index.smd",
            .src = @embedFile("init/content/blog/index.smd"),
        },
        .{
            .path = "content/blog/cover.smd",
            .src = @embedFile("init/content/blog/cover.smd"),
        },
        .{
            .path = "content/blog/docs-first.smd",
            .src = @embedFile("init/content/blog/docs-first.smd"),
        },
        .{
            .path = "content/blog/spine.smd",
            .src = @embedFile("init/content/blog/spine.smd"),
        },
        .{
            .path = "layouts/index.shtml",
            .src = @embedFile("init/layouts/index.shtml"),
        },
        .{
            .path = "layouts/page.shtml",
            .src = @embedFile("init/layouts/page.shtml"),
        },
        .{
            .path = "layouts/post.shtml",
            .src = @embedFile("init/layouts/post.shtml"),
        },
        .{
            .path = "layouts/blog.shtml",
            .src = @embedFile("init/layouts/blog.shtml"),
        },
        .{
            .path = "layouts/blog.xml",
            .src = @embedFile("init/layouts/blog.xml"),
        },
        .{
            .path = "layouts/templates/base.shtml",
            .src = @embedFile("init/layouts/templates/base.shtml"),
        },
        .{
            .path = "assets/style.css",
            .src = @embedFile("init/assets/style.css"),
        },
        .{
            .path = "assets/hero-desk.jpg",
            .src = @embedFile("init/assets/hero-desk.jpg"),
        },
        .{
            .path = "assets/open-pages.jpg",
            .src = @embedFile("init/assets/open-pages.jpg"),
        },
        .{
            .path = "docs/index.md",
            .src = @embedFile("init/docs/index.md"),
        },
        .{
            .path = "docs/01-start/index.md",
            .src = @embedFile("init/docs/01-start/index.md"),
        },
        .{
            .path = "docs/02-ship/index.md",
            .src = @embedFile("init/docs/02-ship/index.md"),
        },
        .{
            .path = "book/index.md",
            .src = @embedFile("init/book/index.md"),
        },
        .{
            .path = "book/01-question.md",
            .src = @embedFile("init/book/01-question.md"),
        },
        .{
            .path = "book/02-method.md",
            .src = @embedFile("init/book/02-method.md"),
        },
        .{
            .path = "book/03-result.md",
            .src = @embedFile("init/book/03-result.md"),
        },
    };

    for (files) |file| {
        if (cmd.multilingual and std.mem.startsWith(u8, file.path, "content/")) {
            const rest = file.path["content/".len..];
            var zh_buf: [std.fs.max_path_bytes]u8 = undefined;
            var en_buf: [std.fs.max_path_bytes]u8 = undefined;
            const zh = std.fmt.bufPrint(&zh_buf, "content/zh-CN/{s}", .{rest}) catch fatal.oom();
            const en = std.fmt.bufPrint(&en_buf, "content/en/{s}", .{rest}) catch fatal.oom();
            writeProjectFile(io, zh, file.src);
            writeProjectFile(io, en, file.src);
            continue;
        }
        writeProjectFile(io, file.path, file.src);
    }

    if (cmd.multilingual) {
        writeProjectFile(io, "i18n/zh-CN.ziggy", "{}\n");
        writeProjectFile(io, "i18n/en.ziggy", "{}\n");
    }

    if (cmd.multilingual) {
        std.debug.print(
            \\
            \\Multilingual site is ready. zh-CN is the default locale at /,
            \\and English is at /en/. Translate content/en/ and the strings
            \\in i18n/.
            \\
            \\  zdoc                 preview
            \\  zdoc site            build into public/
            \\
        , .{});
    } else std.debug.print(
        \\
        \\Official site is ready. The landing, product page and blog
        \\build together. Docs and the paper are Markdown trees beside them.
        \\
        \\  zdoc                 preview the landing
        \\  zdoc site            build the landing, product and blog into public/
        \\  zdoc docs docs --output public/docs --url-prefix /docs --title "南窗"
        \\  zdoc ebook book --output public/book --url-prefix /book --title "作品如何变成收入"
        \\
        \\Build the site first, then docs and the book into that same public/.
        \\The landing links to /docs/ and /book/.
        \\
    , .{});

    return false;
}

fn writeProjectFile(io: Io, path: []const u8, src: []const u8) void {
    const dirname = std.fs.path.dirnamePosix(path);
    const basename = std.fs.path.basenamePosix(path);

    const base_dir = if (dirname) |dn|
        Io.Dir.cwd().createDirPathOpen(io, dn, .{}) catch |err| fatal.dir(dn, err)
    else
        Io.Dir.cwd();

    const f = base_dir.createFile(io, basename, .{
        .exclusive = true,
    }) catch |err| switch (err) {
        else => fatal.file(basename, err),
        error.PathAlreadyExists => {
            std.debug.print(
                "WARNING: '{s}' already exists, skipping.\n",
                .{path},
            );
            return;
        },
    };
    std.debug.print("Created: {s}\n", .{path});
    var file_writer = f.writer(io, &.{});
    file_writer.interface.writeAll(src) catch |err| fatal.file(path, err);
}

fn enterDir(io: Io, explicit: ?[]const u8) void {
    const dir = explicit orelse return;
    if (std.mem.eql(u8, dir, ".")) return;
    var opened = Io.Dir.cwd().createDirPathOpen(io, dir, .{}) catch |err| fatal.dir(dir, err);
    opened.close(io);
    std.Io.Threaded.chdir(dir) catch |err| fatal.dir(dir, err);
}

const Command = struct {
    multilingual: bool,
    dir: ?[]const u8,

    fn parse(args: []const []const u8) Command {
        var multilingual: ?bool = null;
        var dir: ?[]const u8 = null;
        for (args) |a| {
            if (std.mem.eql(u8, a, "--multilingual")) {
                multilingual = true;
            } else if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
                fatal.msg(
                    \\Usage: zdoc init [dir]
                    \\
                    \\Write an official site into [dir], or the current directory.
                    \\The landing, a product page and a blog are a zine project.
                    \\docs/ and book/ are Markdown trees for `zdoc docs` and `zdoc ebook`.
                    \\
                    \\Command specific options:
                    \\  --multilingual   Setup a sample multilingual website
                    \\
                    \\General Options:
                    \\  --help, -h       Print command specific usage
                    \\
                    \\
                , .{});
            } else if (std.mem.startsWith(u8, a, "-")) {
                fatal.msg("error: unexpected cli argument '{s}'\n", .{a});
            } else if (dir == null) {
                dir = a;
            } else {
                fatal.msg("error: unexpected cli argument '{s}'\n", .{a});
            }
        }

        return .{
            .multilingual = multilingual orelse false,
            .dir = dir,
        };
    }
};
