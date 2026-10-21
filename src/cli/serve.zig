const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const WebSocket = std.http.Server.WebSocket;
const builtin = @import("builtin");
const mime = @import("mime");
const tracy = @import("tracy");
const root = @import("../root.zig");
const docs_cli = @import("docs.zig");
const BuildAsset = root.BuildAsset;
const worker = @import("../worker.zig");
const fatal = @import("../fatal.zig");
const Build = @import("../Build.zig");
const PathTable = @import("../PathTable.zig");
const PathName = PathTable.PathName;
const StringTable = @import("../StringTable.zig");
const Path = PathTable.Path;
const String = StringTable.String;
const Channel = @import("../channel.zig").Channel;

const zinereload_js = @embedFile("serve/zinereload.js");
const not_found_html = @embedFile("serve/404.html");
const error_html = @embedFile("serve/error.html");
const outside_html = @embedFile("serve/outside.html");
const Watcher = switch (builtin.target.os.tag) {
    .linux => @import("serve/watcher/LinuxWatcher.zig"),
    .freebsd => @import("serve/watcher/LinuxWatcher.zig"),
    .netbsd => @import("serve/watcher/NetBSDWatcher.zig"),
    .macos => @import("serve/watcher/MacosWatcher.zig"),
    .windows => @import("serve/watcher/WindowsWatcher.zig"),
    else => @compileError("unsupported platform"),
};

const log = std.log.scoped(.serve);

pub const ServeEvent = union(enum) {
    change,
    connect: WebSocket,
    disconnect: WebSocket,
};

pub fn serve(io: Io, gpa: Allocator, args: []const []const u8) error{OutOfMemory}!noreturn {
    if (builtin.single_threaded) {
        std.debug.print(
            "error: single-threaded zine does not yet support running the live server, sorry\n\n",
            .{},
        );

        fatal.help();
    }

    const cmd: Command = try .parse(gpa, args);

    worker.start(io);
    defer if (builtin.mode == .debug) worker.stopWaitAndDeinit(io);

    var buf: [64]ServeEvent = undefined;
    var channel: Channel(ServeEvent) = .init(&buf);

    var debouncer: Debouncer = .{
        .io = io,
        .cascade_window_ms = cmd.debounce,
        .channel = &channel,
    };

    debouncer.start() catch |err| fatal.msg(
        "error: unable to start debouncer: {s}",
        .{@errorName(err)},
    );

    // A Zine project keeps the live server it has always had. Anything else
    // is the tree `zdoc docs` builds when given no path: `docs/` if that
    // directory exists, otherwise the current directory.
    const docs_preview = !zineConfigExists(io, gpa);
    var cfg: root.Config = undefined;
    var base_dir_path: []const u8 = undefined;
    var docs_theme_dir: ?[]const u8 = null;
    if (docs_preview) {
        const docs_cmd = docs_cli.DocsOptions.parse(io, gpa, &.{}, false) catch fatal.oom();
        defer docs_cmd.deinit(gpa);
        cfg = docs_cmd.config;
        base_dir_path = docs_cmd.base_dir_path;
        docs_theme_dir = docs_cmd.theme_dir;
    } else {
        const loaded_cfg, const loaded_base = root.Config.load(io, gpa, .auto);
        cfg = loaded_cfg;
        base_dir_path = loaded_base;
    }
    switch (cfg.site) {
        .simple => |*s| {
            if (cmd.url_path_prefix) |url_path_prefix| {
                s.url_path_prefix = url_path_prefix;
            }
            s.host_url = try std.fmt.allocPrint(
                gpa,
                "http://{s}:{}/",
                .{ cmd.host, cmd.port },
            );
        },

        .multilingual => |*ml| {
            ml.host_url = try std.fmt.allocPrint(
                gpa,
                "http://{s}:{}/",
                .{ cmd.host, cmd.port },
            );

            for (ml.locales) |l| if (l.host_url_override != null) {
                fatal.msg("error: host_url_override is not yet supported by the zine live server, sorry!", .{});
            };
        },
    }

    var dirs_to_watch: std.ArrayListUnmanaged([:0]const u8) = .empty;
    defer if (builtin.mode == .debug) dirs_to_watch.deinit(gpa);

    // Watching `.` already covers the installed theme. Adding those
    // directories again makes the Linux watcher register the same inode twice.
    const content_covers_theme = docs_preview and switch (cfg.site) {
        .simple => |s| dirCovers(s.content_dir_path, cfg.getLayoutsDirPath()) and
            dirCovers(s.content_dir_path, cfg.getAssetsDirPath()),
        .multilingual => false,
    };
    if (!content_covers_theme) {
        try dirs_to_watch.appendSlice(
            gpa,
            &.{
                try std.fs.path.joinZ(gpa, &.{
                    base_dir_path,
                    cfg.getAssetsDirPath(),
                }),
                try std.fs.path.joinZ(gpa, &.{
                    base_dir_path,
                    cfg.getLayoutsDirPath(),
                }),
            },
        );
    }
    switch (cfg.site) {
        .simple => |s| try dirs_to_watch.append(
            gpa,
            try std.fs.path.joinZ(gpa, &.{
                base_dir_path,
                s.content_dir_path,
            }),
        ),
        .multilingual => |ml| {
            try dirs_to_watch.append(gpa, try std.fs.path.joinZ(gpa, &.{
                base_dir_path,
                ml.i18n_dir_path,
            }));
            for (ml.locales) |l| try dirs_to_watch.append(
                gpa,
                try std.fs.path.joinZ(gpa, &.{
                    base_dir_path,
                    l.content_dir_path,
                }),
            );
        },
    }

    var build_lock: Io.RwLock = .init;
    var build: Build = undefined;
    if (docs_preview) {
        // Theme directories are created by the build. The watcher opens them,
        // so the first docs build has to finish before it starts. Missing
        // built-in files are written; files already in `.zdoc-theme/` stay,
        // so a stylesheet edited before the server starts is not erased.
        build = serveBuild(io, gpa, &cfg, base_dir_path, &cmd, docs_theme_dir, true);
    }

    var watcher: Watcher = .init(
        io,
        gpa,
        &debouncer,
        dirs_to_watch.items,
    );

    watcher.start() catch |err| fatal.msg(
        "error: unable to start file watcher: {s}",
        .{@errorName(err)},
    );

    if (!docs_preview) {
        build = serveBuild(io, gpa, &cfg, base_dir_path, &cmd, null, false);
    }

    var server: Server = .init(io, gpa, &channel, &build, &build_lock);
    server.start(cmd) catch |err| fatal.msg(
        "error: unable to start live webserver: {s}",
        .{@errorName(err)},
    );

    std.debug.print(
        \\Starting the development server.
        \\Run 'zdoc help' to learn more about available options.
        \\
        \\
    , .{});

    const name = switch (cfg.site) {
        .simple => |s| try std.fmt.allocPrint(
            gpa,
            "Listening at http://{s}:{}{f}",
            .{ cmd.host, cmd.port, root.fmtJoin('/', &.{ "/", s.url_path_prefix orelse "", "/" }) },
        ),
        .multilingual => try std.fmt.allocPrint(
            gpa,
            "Listening at http://{s}:{}/",
            .{ cmd.host, cmd.port },
        ),
    };

    const node = root.progress.start(name, 0);
    defer node.end();

    var websockets: std.AutoArrayHashMapUnmanaged(
        [*]const u8,
        WebSocket,
    ) = .empty;

    while (true) {
        const event = channel.get(io) catch unreachable;
        log.debug("new event: {s}", .{@tagName(event)});
        switch (event) {
            .change => {
                build_lock.lock(io) catch unreachable;
                if (docs_preview) debouncer.hold();
                build.deinit(io, gpa);
                build = serveBuild(io, gpa, &cfg, base_dir_path, &cmd, docs_theme_dir, docs_preview);
                build_lock.unlock(io);

                for (websockets.entries.items(.value)) |*conn| {
                    conn.writeMessage(
                        \\{ "command": "reload_all" }
                    , .text) catch |err| {
                        log.debug(
                            "error writing to ws: {s}",
                            .{@errorName(err)},
                        );
                    };
                }
                if (docs_preview) debouncer.release();
            },
            .connect => |ws| {
                var conn = ws;
                try websockets.put(gpa, conn.key.ptr, conn);
                // We don't lock the build because this thread is the only writer

                for (build.mode.memory.errors.items) |build_err| {
                    var aw: Writer.Allocating = .init(gpa);
                    defer aw.deinit();

                    aw.writer.print("{f}", .{
                        std.json.fmt(.{
                            .command = "build",
                            .err = build_err.msg,
                        }, .{}),
                    }) catch return error.OutOfMemory;

                    conn.writeMessage(aw.written(), .text) catch |err| {
                        log.debug(
                            "error writing to ws: {s}",
                            .{@errorName(err)},
                        );
                    };
                }

                if (build.any_rendering_error.load(.acquire)) {
                    outer: for (build.variants) |*v| {
                        for (v.pages.items) |*p| {
                            if (!p._parse.active) continue;
                            if (p._parse.status != .parsed) continue;
                            if (p._analysis.frontmatter.items.len > 0) continue;
                            if (p._analysis.page.items.len > 0) continue;

                            if (p._render.errors.len > 0) {
                                var aw: Writer.Allocating = .init(gpa);
                                defer aw.deinit();

                                aw.writer.print("{f}", .{
                                    std.json.fmt(.{
                                        .command = "build",
                                        .err = p._render.errors,
                                    }, .{}),
                                }) catch return error.OutOfMemory;

                                conn.writeMessage(
                                    aw.written(),
                                    .text,
                                ) catch |err| {
                                    log.debug(
                                        "error writing to ws: {s}",
                                        .{@errorName(err)},
                                    );
                                };

                                break :outer;
                            }

                            for (p._render.alternatives) |alt| {
                                if (alt.errors.len > 0) {
                                    var aw: Writer.Allocating = .init(gpa);
                                    defer aw.deinit();

                                    aw.writer.print("{f}", .{
                                        std.json.fmt(.{
                                            .command = "build",
                                            .err = alt.errors,
                                        }, .{}),
                                    }) catch return error.OutOfMemory;
                                    conn.writeMessage(aw.written(), .text) catch |err| {
                                        log.debug(
                                            "error writing to ws: {s}",
                                            .{@errorName(err)},
                                        );
                                    };

                                    break :outer;
                                }
                            }
                        }
                    }
                }
            },
            .disconnect => |conn| {
                // the server thread will take care of closing the connection
                // as the corresponding thread shuts down
                _ = websockets.swapRemove(conn.key.ptr);
            },
        }
    }
}

/// Whether `zine.ziggy` can be found in this directory or a parent.
///
/// The walk matches `Config.load`, so a Zine project started from a
/// subdirectory keeps the server it has today. A missing file is the docs
/// preview; any other error is left for `Config.load` to report.
fn zineConfigExists(io: Io, gpa: Allocator) bool {
    const cwd_path = std.process.currentPathAlloc(io, gpa) catch |err| {
        fatal.msg("error while trying to get the cwd path: {s}\n", .{
            @errorName(err),
        });
    };
    defer gpa.free(cwd_path);

    var dir_path: []const u8 = cwd_path;
    while (true) {
        const joined_path = std.fs.path.join(gpa, &.{
            dir_path,
            "zine.ziggy",
        }) catch fatal.oom();
        defer gpa.free(joined_path);

        var file = Io.Dir.cwd().openFile(io, joined_path, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                dir_path = std.fs.path.dirname(dir_path) orelse return false;
                continue;
            },
            else => return true,
        };
        file.close(io);
        return true;
    }
}

/// Whether every file under `child` is also under `parent`.
///
/// Both paths are the relative paths stored in the config, not absolute ones.
/// `.` is the current directory, so it covers every relative child.
fn dirCovers(parent: []const u8, child: []const u8) bool {
    if (std.mem.eql(u8, parent, child)) return true;
    if (std.mem.eql(u8, parent, ".")) {
        return child.len > 0 and !std.fs.path.isAbsolute(child);
    }
    if (!std.mem.startsWith(u8, child, parent)) return false;
    if (child.len == parent.len) return true;
    const sep = child[parent.len];
    return sep == '/' or sep == '\\';
}

/// `keep_theme` is set on docs rebuilds. The first build installs the
/// built-in theme; a later one must leave `.zdoc-theme/` alone, because the
/// edit that triggered it is already in that directory and a fresh install
/// would replace it before the build reads it.
fn serveBuild(
    io: Io,
    gpa: Allocator,
    cfg: *const root.Config,
    base_dir_path: []const u8,
    cmd: *const Command,
    theme_dir: ?[]const u8,
    keep_theme: bool,
) Build {
    return root.run(io, gpa, cfg, .{
        .base_dir_path = base_dir_path,
        .build_assets = &cmd.build_assets,
        .drafts = cmd.drafts,
        .mode = .memory,
        .theme_dir = theme_dir,
        .theme_keep_existing = keep_theme,
    }) catch fatal.oom();
}

pub const Command = struct {
    // search: root.Config.Search,
    host: []const u8,
    port: u16,
    url_path_prefix: ?[]const u8,
    debounce: u16,
    build_assets: std.StringArrayHashMapUnmanaged(BuildAsset),
    drafts: bool,

    fn parseAddress(arg: []const u8) struct { []const u8, ?u16 } {
        if (arg.len <= 0) {
            fatal.msg(
                "error: missing argument to '--host='",
                .{},
            );
        }

        const host = if (arg[0] == '[') ipv6: {
            var i: usize = 1;
            while (i < arg.len) : (i += 1) {
                if (arg[i] == ']') {
                    break :ipv6 arg[0 .. i + 1];
                }
            }
            fatal.msg(
                "error: unmatched '[' in '--host='",
                .{},
            );
        } else arg[0 .. std.mem.indexOfScalar(u8, arg, ':') orelse arg.len];

        var port: ?u16 = null;
        const maybe_port = arg[host.len..];
        if (maybe_port.len > 0 and maybe_port[0] == ':') {
            port = std.fmt.parseInt(u16, maybe_port[1..], 10) catch |err| fatal.msg(
                \\error: bad port in '{s}': {s}
                \\hint: if you meant to use IPv6, wrap it in square brackets, e.g. --host=[::1]
                \\
            ,
                .{ arg, @errorName(err) },
            );
        }

        return .{ host, port };
    }
    pub fn parse(
        gpa: Allocator,
        args: []const []const u8,
    ) error{OutOfMemory}!Command {
        // var config_path: ?[]const u8 = null;
        var host: ?[]const u8 = null;
        var port: ?u16 = null;
        var url_path_prefix: ?[]const u8 = null;
        var debounce: ?u16 = null;
        var build_assets: std.StringArrayHashMapUnmanaged(BuildAsset) = .empty;
        var drafts: ?bool = null;

        var idx: usize = 0;
        while (idx < args.len) : (idx += 1) {
            const arg = args[idx];
            if (std.mem.startsWith(u8, arg, "--host=")) {
                const suffix = arg["--host=".len..];
                host, const maybe_port = parseAddress(suffix);
                if (maybe_port) |p| port = p;
            } else if (std.mem.eql(u8, arg, "--host")) {
                idx += 1;
                if (idx >= args.len) fatal.msg(
                    "error: missing argument to '--host'",
                    .{},
                );
                host, const maybe_port = parseAddress(args[idx]);
                if (maybe_port) |p| port = p;
            } else if (std.mem.startsWith(u8, arg, "--url-path-prefix=")) {
                const suffix = arg["--url-path-prefix=".len..];
                url_path_prefix = suffix;
            } else if (std.mem.eql(u8, arg, "--url-path-prefix")) {
                idx += 1;
                if (idx >= args.len) fatal.msg(
                    "error: missing argument to '--url-path-prefix'",
                    .{},
                );
                url_path_prefix = args[idx];
            } else if (std.mem.startsWith(u8, arg, "--port=")) {
                const suffix = arg["--port=".len..];
                port = std.fmt.parseInt(u16, suffix, 10) catch |err| fatal.msg(
                    "error: bad port value '{s}': {s}",
                    .{ arg, @errorName(err) },
                );
            } else if (std.mem.eql(u8, arg, "--port")) {
                idx += 1;
                if (idx >= args.len) fatal.msg(
                    "error: missing argument to '--port'",
                    .{},
                );
                port = std.fmt.parseInt(u16, args[idx], 10) catch |err| fatal.msg(
                    "error: bad port value '{s}': {s}",
                    .{ arg, @errorName(err) },
                );
            } else if (std.mem.startsWith(u8, arg, "--debounce=")) {
                const suffix = arg["--debounce=".len..];
                debounce = std.fmt.parseInt(u16, suffix, 10) catch |err| fatal.msg(
                    "error: bad debounce value '{s}': {s}",
                    .{ arg, @errorName(err) },
                );
            } else if (std.mem.eql(u8, arg, "--debounce")) {
                idx += 1;
                if (idx >= args.len) fatal.msg(
                    "error: missing argument to '--debounce'",
                    .{},
                );
                debounce = std.fmt.parseInt(u16, args[idx], 10) catch |err| fatal.msg(
                    "error: bad debounce value '{s}': {s}",
                    .{ arg, @errorName(err) },
                );
                // } else if (std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "--config")) {
                //     idx += 1;
                //     if (idx >= args.len) fatal.msg(
                //         "error: missing argument to '{s}'",
                //         .{arg},
                //     );
                //     config_path = args[idx];
                // } else if (std.mem.startsWith(u8, arg, "--config=")) {
                //     config_path = arg["--config=".len..];
            } else if (std.mem.eql(u8, arg, "-h") or
                std.mem.eql(u8, arg, "--help"))
            {
                fatal.help();
            } else if (std.mem.startsWith(u8, arg, "--build-asset=")) {
                const name = arg["--build-asset=".len..];

                idx += 1;
                if (idx >= args.len) fatal.msg(
                    "error: missing build asset sub-argument for '{s}'",
                    .{name},
                );

                const input_path = args[idx];

                idx += 1;
                var install_path: ?[]const u8 = null;
                var install_always = false;
                if (idx < args.len) {
                    const next = args[idx];
                    if (std.mem.startsWith(u8, next, "--install=")) {
                        install_path = next["--install=".len..];
                    } else if (std.mem.startsWith(u8, next, "--install-always=")) {
                        install_always = true;
                        install_path = next["--install-always=".len..];
                    } else {
                        idx -= 1;
                    }
                }

                const gop = try build_assets.getOrPut(gpa, name);
                if (gop.found_existing) fatal.msg(
                    "error: duplicate build asset name '{s}'",
                    .{name},
                );

                gop.value_ptr.* = .{
                    .input_path = input_path,
                    .install_path = install_path,
                    .install_always = install_always,
                    .rc = .{ .raw = @intFromBool(install_always) },
                };
            } else if (std.mem.eql(u8, arg, "--drafts")) {
                drafts = true;
            } else {
                std.debug.print("error: unexpected cli argument '{s}'\n\n", .{arg});
                fatal.help();
            }
        }

        return .{
            // .search = if (config_path) |p| .{ .path = p } else .auto,
            .host = host orelse "localhost",
            .port = port orelse 1990,
            .url_path_prefix = url_path_prefix,
            .debounce = debounce orelse 25,
            .build_assets = build_assets,
            .drafts = drafts orelse false,
        };
    }
};
/// like fs.path.dirname but ensures a final `/`
// fn dirNameWithSlash(path: []const u8) []const u8 {
//     const d = std.fs.path.dirname(path).?;
//     if (d.len > 1) {
//         return path[0 .. d.len + 1];
//     } else {
//         return "/";
//     }
// }

pub const Server = struct {
    io: Io,
    gpa: Allocator,
    channel: *Channel(ServeEvent),
    build: *const Build,
    build_lock: *Io.RwLock,
    addresses_buffer: [16]Io.net.HostName.LookupResult = undefined,
    canon_name_buffer: [Io.net.HostName.max_len]u8 = undefined,

    pub const max_connection_header_size: usize = 8 * 1024;

    pub fn init(
        io: Io,
        gpa: Allocator,
        channel: *Channel(ServeEvent),
        build: *const Build,
        build_lock: *Io.RwLock,
    ) Server {
        return .{
            .io = io,
            .gpa = gpa,
            .channel = channel,
            .build = build,
            .build_lock = build_lock,
        };
    }

    pub fn start(s: *Server, cmd: Command) !void {
        const host = if (cmd.host[0] == '[')
            cmd.host[1..][0 .. cmd.host.len - 2] // Strip brackets from IPv6
        else
            cmd.host;

        var queue: Io.Queue(Io.net.HostName.LookupResult) = .init(&s.addresses_buffer);
        try Io.net.HostName.lookup(try .init(host), s.io, &queue, .{
            .port = cmd.port,
            .canonical_name_buffer = &s.canon_name_buffer,
        });

        const result = s.addresses_buffer[0];
        const t = try std.Thread.spawn(.{}, Server.serve, .{ s, result.address });
        t.detach();
    }

    fn serve(s: *Server, address: Io.net.IpAddress) void {
        var tcp_server = address.listen(
            s.io,
            .{ .reuse_address = true },
        ) catch |err| fatal.msg(
            "error: unable to bind to '{any}': {s}",
            .{ address, @errorName(err) },
        );
        defer tcp_server.deinit();

        // const server_port = tcp_server.listen_address.in.getPort();

        while (true) {
            const stream = tcp_server.accept(s.io) catch |err| switch (err) {
                error.SystemResources,
                error.ProcessFdQuotaExceeded,
                error.SystemFdQuotaExceeded,
                error.Unexpected,
                error.SocketNotListening,
                error.ProtocolFailure,
                error.BlockedByFirewall,
                error.WouldBlock,
                error.Canceled,
                => fatal.msg(
                    "error: critical failure while opening new live server tcp connection: {s}",
                    .{@errorName(err)},
                ),
                error.ConnectionAborted,
                error.NetworkDown,
                => {
                    log.debug("non-fatal tcp error: {s}", .{@errorName(err)});
                    continue;
                },
            };

            const t = std.Thread.spawn(.{}, Server.handleConnection, .{
                s,
                stream,
            }) catch |err| fatal.msg(
                "error: unable to spawn connection thread: {s}",
                .{@errorName(err)},
            );
            t.detach();
        }
    }

    fn handleConnection(s: *Server, stream: Io.net.Stream) void {
        defer stream.close(s.io);

        var bufin: [4096 * 4]u8 = undefined;
        var in = stream.reader(s.io, &bufin);
        var bufout: [4096]u8 = undefined;
        var out = stream.writer(s.io, &bufout);

        var arena_state = std.heap.ArenaAllocator.init(s.gpa);
        const arena = arena_state.allocator();

        var http_server = std.http.Server.init(&in.interface, &out.interface);

        while (true) {
            var request = http_server.receiveHead() catch |err| {
                if (err != error.HttpConnectionClosing) {
                    log.debug("connection error: {s}\n", .{@errorName(err)});
                }
                return;
            };

            log.debug("request: {s}", .{request.head.target});
            s.handleRequest(arena, &request) catch |err| {
                log.debug("failed request: {s}", .{@errorName(err)});
                return;
            };
            _ = arena_state.reset(.retain_capacity);
        }
    }

    fn handleRequest(
        server: *Server,
        arena: Allocator,
        req: *std.http.Server.Request,
    ) !void {
        var path_with_query = req.head.target;

        if (std.mem.indexOf(u8, path_with_query, "..")) |_| {
            req.respond("path is not allowed\n", .{
                .status = .bad_request,
                .extra_headers = &.{
                    .{ .name = "content-type", .value = "text/plain" },
                    .{ .name = "connection", .value = "close" },
                },
            }) catch |err| log.debug(
                "error while sending http response: {}",
                .{err},
            );
            return;
        }

        if (std.mem.indexOfScalar(u8, path_with_query, '%')) |_| {
            const buffer = try arena.dupe(u8, path_with_query);
            path_with_query = std.Uri.percentDecodeInPlace(buffer);
        }

        var path = path_with_query[0 .. std.mem.indexOfScalar(
            u8,
            path_with_query,
            '?',
        ) orelse path_with_query.len];

        if (std.mem.eql(u8, path, "/__zine/zinereload.js")) {
            req.respond(zinereload_js, .{
                .extra_headers = &.{
                    .{ .name = "content-type", .value = "text/javascript" },
                    // .{ .name = "connection", .value = "close" },
                },
            }) catch |err| log.debug(
                "error while sending http response: {}",
                .{err},
            );

            log.debug("sent livereload script", .{});
            return;
        }

        if (std.mem.eql(u8, path, "/__zine/ws")) {
            server.handleWebsocket(req);
            return error.Websocket;
        }

        switch (server.build.cfg.site) {
            .simple => |s| {
                const url_path_prefix = s.url_path_prefix orelse "";
                if (url_path_prefix.len > 0) {
                    if (!std.mem.startsWith(u8, path[1..], url_path_prefix)) {
                        return sendOutsideOfPathPrefix(
                            arena,
                            req,
                            url_path_prefix,
                        );
                    }

                    var len = url_path_prefix.len;
                    if (url_path_prefix[len - 1] == '/') len -= 1;
                    path = path[1 + len ..];

                    if (path.len == 0) {
                        return appendSlashRedirect(
                            arena,
                            req,
                            path_with_query,
                        ) catch |err| fatal.file(path, err);
                    }
                }
            },
            .multilingual => {},
        }

        const path_ends_with_slash = std.mem.endsWith(u8, path, "/");

        if (path_ends_with_slash) {
            path = try std.fmt.allocPrint(arena, "{s}{s}", .{
                path,
                "index.html",
            });
        }

        const ext = std.fs.path.extension(path);
        const mime_type = mime.extension_map.get(ext) orelse
            .@"application/octet-stream";

        server.build_lock.lockShared(server.io) catch unreachable;
        defer server.build_lock.unlockShared(server.io);

        if (server.build.any_prerendering_error) return sendError(
            arena,
            req,
            "No page was built because of a pre-rendering error.",
        );

        // Site asset search
        not_found: {
            const site_asset = server.build.site_assets.get(PathName.get(
                &server.build.st,
                &server.build.pt,
                path,
            ) orelse break :not_found) orelse break :not_found;

            if (site_asset.load(.acquire) == 0) {
                return sendNotFound(
                    arena,
                    req,
                    true,
                ) catch |err| fatal.file(path, err);
            }

            return sendFile(
                server.io,
                arena,
                req,
                server.build.site_assets_dir,
                mime_type,
                path[1..],
            ) catch |err| fatal.file(path, err);
        }

        for (server.build.variants) |*v| {
            if (!std.mem.startsWith(u8, path[1..], v.output_path_prefix)) continue;
            const subpath = path[1..][v.output_path_prefix.len..][@intFromBool(v.output_path_prefix.len > 0 and path_ends_with_slash)..];

            const hint = v.urls.get(PathName.get(
                &v.string_table,
                &v.path_table,
                subpath,
            ) orelse continue) orelse continue;

            const page = &v.pages.items[hint.id];
            if (hint.kind != .page_asset) {
                if (!page._parse.active) return sendError(
                    arena,
                    req,
                    "This page is not active",
                );

                if (page._parse.status != .parsed) return sendError(
                    arena,
                    req,
                    "This page failed to parse",
                );

                if (page._analysis.frontmatter.items.len > 0) return sendError(
                    arena,
                    req,
                    "This page has frontmatter errors",
                );

                if (page._analysis.page.items.len > 0) return sendError(
                    arena,
                    req,
                    "This page contains SuperMD errors",
                );

                // TODO: why not just send the error directly for good measure?
                if (page._render.errors.len > 0) return sendError(
                    arena,
                    req,
                    "This page contains rendering errors",
                );
            }

            switch (hint.kind) {
                .page_main, .page_alias => {
                    return sendHtml(
                        arena,
                        req,
                        page._render.out,
                    ) catch |err| fatal.file(path, err);
                },
                .page_alternative => |name| {
                    const idx = for (page.alternatives, 0..) |alt, idx| {
                        if (std.mem.eql(u8, alt.name, name)) {
                            break idx;
                        }
                    } else unreachable;

                    // NOTE: some alternatives might be XML!
                    return sendAlternative(
                        arena,
                        req,
                        subpath,
                        page._render.alternatives[idx].out,
                    ) catch |err| fatal.file(path, err);
                },
                .page_asset => |pa| {
                    if (pa.load(.acquire) == 0) {
                        return sendNotFound(
                            arena,
                            req,
                            true,
                        ) catch |err| fatal.file(path, err);
                    }

                    return sendFile(
                        server.io,
                        arena,
                        req,
                        v.content_dir,
                        mime_type,
                        subpath,
                    ) catch |err| fatal.file(path, err);
                },
            }
        }

        for (server.build.build_assets.entries.items(.value)) |ba| {
            const raw_install_path = ba.install_path orelse continue;
            const install_path = std.mem.trimStart(u8, raw_install_path, "/");
            // skip leading slash in url path
            if (!std.mem.eql(u8, path[1..], install_path)) continue;
            return sendFile(
                server.io,
                arena,
                req,
                server.build.base_dir,
                mime_type,
                ba.input_path,
            ) catch |err| fatal.file(path, err);
        }

        if (!path_ends_with_slash) {
            return appendSlashRedirect(
                arena,
                req,
                path_with_query,
            ) catch |err| fatal.file(path, err);
        } else {
            return sendNotFound(
                arena,
                req,
                false,
            ) catch |err| fatal.file(path, err);
        }
    }

    fn sendAlternative(
        arena: Allocator,
        req: *std.http.Server.Request,
        path: []const u8,
        src: []const u8,
    ) !void {
        const ext = std.fs.path.extension(path);
        const mime_type = mime.extension_map.get(ext) orelse
            .@"application/octet-stream";

        if (mime_type == .@"text/html") {
            return sendHtml(arena, req, src);
        }

        req.respond(src, .{
            .status = .ok,
            .extra_headers = &.{
                .{ .name = "content-type", .value = @tagName(mime_type) },
            },
        }) catch |err| log.debug(
            "error while sending http response: {}",
            .{err},
        );
    }

    fn sendHtml(
        arena: Allocator,
        req: *std.http.Server.Request,
        src: []const u8,
    ) !void {
        const injection =
            \\<script defer src="/__zine/zinereload.js"></script>
        ;
        const head = "</head>";
        const head_pos = std.mem.indexOf(u8, src, head) orelse src.len;

        const injected = try std.fmt.allocPrint(arena, "{s}{s}{s}", .{
            src[0..head_pos],
            injection,
            src[head_pos..],
        });

        req.respond(injected, .{
            .status = .ok,
            .extra_headers = &.{
                .{ .name = "content-type", .value = "text/html" },
            },
        }) catch |err| log.debug(
            "error while sending http response: {}",
            .{err},
        );
    }

    fn sendOutsideOfPathPrefix(
        arena: Allocator,
        req: *std.http.Server.Request,
        path: []const u8,
    ) !void {
        const data = try std.fmt.allocPrint(arena, outside_html, .{path});

        req.respond(data, .{
            .status = .not_found,
            .extra_headers = &.{
                .{ .name = "content-type", .value = "text/html" },
            },
        }) catch |err| log.debug(
            "error while sending http response: {}",
            .{err},
        );
        log.debug("outside of perfix path", .{});
    }

    fn sendError(
        arena: Allocator,
        req: *std.http.Server.Request,
        msg: []const u8,
    ) !void {
        const data = try std.fmt.allocPrint(arena, error_html, .{msg});

        req.respond(data, .{
            .status = .not_found,
            .extra_headers = &.{
                .{ .name = "content-type", .value = "text/html" },
            },
        }) catch |err| log.debug(
            "error while sending http response: {}",
            .{err},
        );
        log.debug("not found", .{});
    }

    fn sendNotFound(
        arena: Allocator,
        req: *std.http.Server.Request,
        /// Set to true when the asset exists but it was not referenced anywhere
        /// and thus would not be installed.
        not_installed: bool,
    ) !void {
        const msg = switch (not_installed) {
            true => "This path does exist but it was never referenced in the build!",
            false => "This path does not exist!",
        };

        const data = try std.fmt.allocPrint(arena, not_found_html, .{msg});

        req.respond(data, .{
            .status = .not_found,
            .extra_headers = &.{
                .{ .name = "content-type", .value = "text/html" },
                // .{ .name = "connection", .value = "close" },
            },
        }) catch |err| log.debug(
            "error while sending http response: {}",
            .{err},
        );
        log.debug("not found", .{});
    }

    fn sendFile(
        io: Io,
        arena: Allocator,
        req: *std.http.Server.Request,
        dir: Io.Dir,
        mime_type: mime.Type,
        file_path: []const u8,
    ) !void {
        assert(file_path[0] != '/');

        const contents = try dir.readFileAlloc(
            io,
            file_path,
            arena,
            .unlimited,
        );

        if (mime_type == .@"text/html") {
            return sendHtml(arena, req, contents);
        }

        req.respond(contents, .{
            .status = .ok,
            .extra_headers = &.{
                .{ .name = "content-type", .value = @tagName(mime_type) },
                // .{ .name = "connection", .value = "close" },
            },
        }) catch |err| log.debug(
            "error while sending http response: {}",
            .{err},
        );
    }

    fn appendSlashRedirect(
        arena: std.mem.Allocator,
        req: *std.http.Server.Request,
        path_with_query: []const u8,
    ) !void {
        // convert `foo/bar?query=1` to `foo/bar/?query=1`
        const query_start = std.mem.indexOfScalar(u8, path_with_query, '?') orelse path_with_query.len;
        const location = try std.fmt.allocPrint(
            arena,
            "{s}/{s}",
            .{ path_with_query[0..query_start], path_with_query[query_start..] },
        );

        req.respond(not_found_html, .{
            .status = .see_other,
            .extra_headers = &.{
                .{ .name = "location", .value = location },
                .{ .name = "content-type", .value = "text/html" },
                .{ .name = "connection", .value = "close" },
            },
        }) catch |err| log.debug(
            "error while sending http response: {}",
            .{err},
        );
        log.debug("append final slash redirect", .{});
    }

    fn handleWebsocket(s: *Server, req: *std.http.Server.Request) void {
        const up = req.upgradeRequested();
        const wsup = switch (up) {
            .none, .other => return req.respond("error: must request websocket upgrade", .{
                .status = .bad_request,
            }) catch {},

            .websocket => |wsup| wsup orelse "<no key provided>",
        };

        var ws = req.respondWebSocket(.{ .key = wsup }) catch return;
        ws.flush() catch return;

        s.channel.put(s.io, .{ .connect = ws }) catch return;

        while (true) {
            const msg = ws.readSmallMessage() catch |err| {
                log.debug("readWs error: {s}", .{@errorName(err)});
                s.channel.put(s.io, .{ .disconnect = ws }) catch return;
                return;
            };
            _ = msg;
        }
    }
};

pub const Debouncer = struct {
    cascade_window_ms: i64,

    io: Io,
    cascade_mutex: Io.Mutex = .init,
    cascade_condition: Io.Condition = .init,
    cascade_start_ms: i64 = 0,
    /// Docs preview only. Theme installation writes into a watched directory
    /// on every build; those events must not schedule another build.
    suppress: bool = false,
    channel: *Channel(ServeEvent),

    /// Thread-safe. To be called when a new event comes in
    pub fn newEvent(d: *Debouncer) void {
        {
            d.cascade_mutex.lock(d.io) catch unreachable;
            defer d.cascade_mutex.unlock(d.io);
            if (d.suppress) return;
            d.cascade_start_ms = Io.Clock.awake.now(d.io).toMilliseconds();
        }
        d.cascade_condition.signal(d.io);
    }

    /// Drop watcher events until `release`. Also cancels a cascade that
    /// already started, so a theme write cannot land in the channel.
    fn hold(d: *Debouncer) void {
        d.cascade_mutex.lock(d.io) catch unreachable;
        defer d.cascade_mutex.unlock(d.io);
        d.suppress = true;
        d.cascade_start_ms = 0;
    }

    /// macOS delivers FSEvents after the stream latency (50ms). Keep ignoring
    /// them briefly so the writes from the build that just finished do not
    /// schedule a second one.
    fn release(d: *Debouncer) void {
        d.io.sleep(.fromMilliseconds(200), .awake) catch |err| fatal.msg(
            "error: unable to resume the file watcher: {s}",
            .{@errorName(err)},
        );
        d.cascade_mutex.lock(d.io) catch unreachable;
        defer d.cascade_mutex.unlock(d.io);
        d.cascade_start_ms = 0;
        d.suppress = false;
    }

    pub fn start(d: *Debouncer) !void {
        const t = try std.Thread.spawn(.{}, Debouncer.notify, .{d});
        t.detach();
    }

    pub fn notify(d: *Debouncer) !void {
        while (true) {
            try d.cascade_mutex.lock(d.io);
            defer d.cascade_mutex.unlock(d.io);

            while (d.cascade_start_ms == 0) {
                // no active cascade
                try d.cascade_condition.wait(d.io, &d.cascade_mutex);
            }
            // cascade != 0
            while (true) {
                // `hold` zeroes this from the server thread. A zero timestamp
                // is not the start of a window.
                if (d.cascade_start_ms == 0 or d.suppress) break;
                const time_passed = Io.Clock.awake.now(d.io).toMilliseconds() - d.cascade_start_ms;
                if (time_passed >= d.cascade_window_ms) break;
                d.cascade_mutex.unlock(d.io);
                const sleep_ms = d.cascade_window_ms - time_passed;
                try d.io.sleep(.fromMilliseconds(sleep_ms), .awake);
                try d.cascade_mutex.lock(d.io);
            }

            // A docs rebuild cancels the cascade from under us. Committing
            // it would rebuild again because the build wrote theme files.
            if (d.cascade_start_ms == 0 or d.suppress) {
                d.cascade_start_ms = 0;
                continue;
            }

            // We have slept enough, "commit" the cascade window and
            // trigger a new build.
            d.cascade_start_ms = 0;
            try d.channel.put(d.io, .change);
        }
    }
};
