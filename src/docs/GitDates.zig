//! Per-page last-modified dates, read from git history.
//!
//! VitePress shows "Last updated" on every page, and a docs reader genuinely
//! wants it: a page's age says whether the advice in it still holds. There
//! was no way to produce that, because the git support in `src/Git.zig` reads
//! loose objects and explicitly does not handle packed ones. Any repository
//! that has ever run `git gc` -- which is to say, every cloned repository --
//! returns nothing from it.
//!
//! Rather than write a packfile reader, this shells out to `git log` once and
//! takes every page's date from the same output. On the zigmodu corpus that
//! is 95ms for 85 pages, which is cheaper than reading the objects would be.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

/// One page's last commit date, as the author recorded it.
pub const Date = struct {
    /// Seconds since the Unix epoch.
    unix: i64,
};

/// Maps a path relative to the content directory to the date of the most
/// recent commit that touched it.
pub const Dates = struct {
    entries: std.StringArrayHashMapUnmanaged(Date) = .empty,

    pub fn get(self: Dates, path: []const u8) ?Date {
        return self.entries.get(path);
    }

    pub fn deinit(self: *Dates, gpa: Allocator) void {
        self.entries.deinit(gpa);
    }
};

/// Reads the last-modified date of every file under `content_dir_path`.
///
/// Returns an empty map when the directory is not in a repository, when `git`
/// is not installed, or when the history is empty. A missing date is never an
/// error: the caller simply does not print one.
///
/// `repo_dir` is the directory to run git in, which for a docs site is
/// wherever the content lives -- that is the repository the author committed
/// from.
pub fn read(
    gpa: Allocator,
    io: Io,
    arena: Allocator,
    repo_dir: []const u8,
    content_dir_path: []const u8,
) Allocator.Error!Dates {
    var dates: Dates = .{};

    const argv = [_][]const u8{
        "git",
        "log",
        // One header line per commit naming its date, then the paths that
        // commit touched. The header is prefixed so it cannot be confused with
        // a path, which is what makes the format unambiguous even for a
        // commit that touches nothing.
        "--pretty=format:zxdoc-commit %cI",
        "--name-only",
        "--no-renames",
        "HEAD",
        // Confine the walk to the content directory: a repository's whole
        // history is not interesting, and limiting it keeps the output small
        // on a large project.
        "--",
        content_dir_path,
    };

    const result = std.process.run(gpa, io, .{
        .argv = &argv,
        .cwd = .{ .path = repo_dir },
        // A docs tree's history can be large; cap it so a pathological
        // repository cannot exhaust memory here.
        .stdout_limit = .limited(64 * 1024 * 1024),
    }) catch return dates;

    // A non-zero exit means "not a repository" or "no commits yet", both of
    // which are ordinary for a docs tree and neither of which is an error.
    if (!result.term.success()) {
        gpa.free(result.stdout);
        gpa.free(result.stderr);
        return dates;
    }
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    try parse(gpa, arena, result.stdout, content_dir_path, &dates);
    return dates;
}

/// Parses `git log` output into a path-to-date map.
///
/// The input alternates between a header line naming a commit date and the
/// paths that commit touched. Walking the history newest-first means the first
/// date seen for a path is its most recent, so later entries are ignored.
fn parse(
    gpa: Allocator,
    arena: Allocator,
    output: []const u8,
    content_dir_path: []const u8,
    dates: *Dates,
) Allocator.Error!void {
    const header_prefix = "zxdoc-commit ";

    // A path is only interesting if it is under the content directory; the
    // caller wants dates for pages, not for the repository's source tree.
    const content_prefix = if (content_dir_path.len == 0 or
        std.mem.eql(u8, content_dir_path, ".")) "" else content_dir_path;

    var current: ?Date = null;
    var lines = std.mem.splitScalar(u8, output, '\n');

    while (lines.next()) |raw| {
        if (std.mem.startsWith(u8, raw, header_prefix)) {
            current = parseDate(raw[header_prefix.len..]);
            continue;
        }
        if (raw.len == 0) {
            current = null;
            continue;
        }
        const date = current orelse continue;

        // `--name-only` output is relative to the repository root, while the
        // caller asks about paths relative to the content directory.
        var path = raw;
        if (content_prefix.len != 0) {
            if (!std.mem.startsWith(u8, path, content_prefix)) continue;
            path = path[content_prefix.len..];
            while (path.len > 0 and (path[0] == '/' or path[0] == '\\')) path = path[1..];
            if (path.len == 0) continue;
        }

        // First date wins: git log is newest-first, so this is the latest.
        if (dates.entries.contains(path)) continue;
        try dates.entries.put(gpa, try arena.dupe(u8, path), date);
    }
}

/// Parses an ISO 8601 timestamp, keeping only the seconds.
///
/// The date is rendered as a plain `YYYY-MM-DD` in the template, so the time
/// of day and the offset are computed and then discarded.
fn parseDate(raw: []const u8) ?Date {
    const trimmed = std.mem.trim(u8, raw, " \t\r");
    if (trimmed.len < 10) return null;

    const year = std.fmt.parseInt(i32, trimmed[0..4], 10) catch return null;
    const month = std.fmt.parseInt(u8, trimmed[5..7], 10) catch return null;
    const day = std.fmt.parseInt(u8, trimmed[8..10], 10) catch return null;
    if (month < 1 or month > 12 or day < 1 or day > 31) return null;

    return .{ .unix = daysFromCivil(year, month, day) * std.time.s_per_day };
}

/// Days between 1970-01-01 and a civil date, by Howard Hinnant's algorithm.
///
/// This is the standard formulation because it is exact across the whole
/// range including leap years, without a table.
fn daysFromCivil(y_in: i32, m: u8, d: u8) i64 {
    var y: i64 = y_in;
    y -%= @intFromBool(m <= 2);

    const era = @divFloor(if (y >= 0) y else y - 399, 400);
    const yoe = y - era * 400;
    const mp: i64 = @mod(m + (if (m > 2) @as(i64, -3) else 9), 12);
    const doy = @divFloor(153 * mp + 2, 5) + @as(i64, d) - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;

    return era * 146097 + doe - 719468;
}

/// A calendar date, recovered from a day count.
pub const Civil = struct {
    year: i32,
    month: u8,
    day: u8,
};

/// The inverse of `daysFromCivil`, by the same algorithm.
///
/// Rendering the date is done in Zig because the template language has no
/// date formatter and no way to do arithmetic on a number.
pub fn civilFromDays(z: i64) Civil {
    const shifted = z + 719468;
    const era = @divFloor(if (shifted >= 0) shifted else shifted - 146096, 146097);
    const doe = shifted - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) -
        @divFloor(doe, 146096), 365);
    const y = yoe + era * 400;
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);

    const day: u8 = @intCast(doy - @divFloor(153 * mp + 2, 5) + 1);
    const month: u8 = @intCast(mp + (if (mp < 10) @as(i64, 3) else -9));
    return .{ .year = @intCast(y + @intFromBool(month <= 2)), .month = month, .day = day };
}

const testing = std.testing;

test "parseDate keeps the calendar day" {
    // The time of day and the offset are discarded: only the date is shown.
    const d = parseDate("2026-10-11T23:29:50+08:00").?;
    const days = @divFloor(d.unix, std.time.s_per_day);
    try testing.expectEqual(@as(i64, 20737), days);

    // The same date at either end of the day, and across offsets, is one day.
    const early = parseDate("2026-10-11T00:00:00Z").?;
    const late = parseDate("2026-10-11T23:59:59Z").?;
    try testing.expectEqual(d.unix, early.unix);
    try testing.expectEqual(d.unix, late.unix);
}

test "parseDate rejects nonsense rather than guessing" {
    try testing.expect(parseDate("") == null);
    try testing.expect(parseDate("not-a-date") == null);
    try testing.expect(parseDate("2026-13-01") == null);
    try testing.expect(parseDate("2026-01-99") == null);
}

test "daysFromCivil agrees with known dates" {
    try testing.expectEqual(@as(i64, 0), daysFromCivil(1970, 1, 1));
    try testing.expectEqual(@as(i64, 1), daysFromCivil(1970, 1, 2));
    // 2000 was a leap year and 1900 was not, so March 1st lands a day
    // further apart than a naive four-year rule would predict.
    try testing.expectEqual(@as(i64, 11017), daysFromCivil(2000, 3, 1));
    try testing.expectEqual(@as(i64, -25508), daysFromCivil(1900, 3, 1));

    // The leap day itself.
    try testing.expectEqual(
        daysFromCivil(2000, 3, 1),
        daysFromCivil(2000, 2, 29) + 1,
    );
}

test "parse keeps the newest date for each path" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    var dates: Dates = .{};
    defer dates.deinit(testing.allocator);

    const gpa = testing.allocator;
    // `git log` is newest-first, so the first commit listed is the most
    // recent one. QUICK-START is only in that commit; README is in both.
    const output =
        "zxdoc-commit 2026-10-11\n" ++
        "docs/README.md\n" ++
        "docs/guide/QUICK-START.md\n" ++
        "\n" ++
        "zxdoc-commit 2026-01-02\n" ++
        "docs/README.md\n" ++
        "docs/other.md\n" ++
        "\n";

    try parse(gpa, arena_state.allocator(), output, "docs", &dates);

    const readme = dates.get("README.md").?;
    const quickstart = dates.get("guide/QUICK-START.md").?;
    const other = dates.get("other.md").?;

    // README appears in both commits. Git is newest-first, so the date
    // recorded by the first walk must win over the older one -- this is the
    // assertion that a second walk does not overwrite a page's real date.
    const newest = parseDate("2026-10-11").?.unix;
    const oldest = parseDate("2026-01-02").?.unix;
    try testing.expectEqual(newest, readme.unix);
    try testing.expect(readme.unix != oldest);

    // A file touched once takes that commit's date, and the pages fall in the
    // order the history says they do.
    try testing.expectEqual(newest, quickstart.unix);
    try testing.expectEqual(oldest, other.unix);
    try testing.expectEqual(@as(usize, 3), dates.entries.count());
}

test "parse ignores paths outside the content directory" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    var dates: Dates = .{};
    defer dates.deinit(testing.allocator);

    const output =
        "zxdoc-commit 2026-10-11\n" ++
        "src/main.zig\n" ++
        "docs/README.md\n" ++
        "\n";

    try parse(testing.allocator, arena_state.allocator(), output, "docs", &dates);

    try testing.expectEqual(@as(usize, 1), dates.entries.count());
    try testing.expect(dates.get("README.md") != null);
}
test "civilFromDays is the inverse of daysFromCivil" {
    const cases = [_]struct { y: i32, m: u8, d: u8 }{
        .{ .y = 1970, .m = 1, .d = 1 },
        .{ .y = 1970, .m = 1, .d = 2 },
        .{ .y = 1999, .m = 12, .d = 31 },
        .{ .y = 2000, .m = 2, .d = 29 },
        .{ .y = 2026, .m = 10, .d = 11 },
    };
    for (cases) |c| {
        const back = civilFromDays(daysFromCivil(c.y, c.m, c.d));
        try testing.expectEqual(c.y, back.year);
        try testing.expectEqual(c.m, back.month);
        try testing.expectEqual(c.d, back.day);
    }
}
