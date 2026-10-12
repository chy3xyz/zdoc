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
/// `content_dir_path` is the directory to run git in, resolved to an absolute
/// path. It has to be the content tree itself rather than the process's
/// working directory: `zdoc docs ~/projects/app/docs` is normally run from
/// anywhere, and a git run from an unrelated directory is not in a repository
/// at all. Running there with `--relative` also makes the paths come back
/// relative to the content directory, which is the form the caller asks about.
pub fn read(
    gpa: Allocator,
    io: Io,
    arena: Allocator,
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
        // Confine the walk to the current directory and report paths relative
        // to it. A repository's whole history is not interesting, and
        // limiting it keeps the output small on a large project.
        "--relative",
        "HEAD",
    };

    const result = std.process.run(gpa, io, .{
        .argv = &argv,
        .cwd = .{ .path = content_dir_path },
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

    // `--relative` already stripped the content directory from every path, so
    // there is no prefix left to remove.
    try parse(gpa, arena, result.stdout, &dates);
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
    dates: *Dates,
) Allocator.Error!void {
    const header_prefix = "zxdoc-commit ";

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

        // First date wins: git log is newest-first, so this is the latest.
        if (dates.entries.contains(raw)) continue;
        try dates.entries.put(gpa, try arena.dupe(u8, raw), date);
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

/// Formats a date as `YYYY-MM-DD` into `buf`, returning the written slice.
///
/// Both consumers want the same string -- the "Last updated" line in the page
/// footer and the sitemap's `<lastmod>` -- and the W3C datetime format accepts
/// a bare calendar day, so there is one rendering rather than two.
///
/// The year is formatted as unsigned because Zig's signed integer formatting
/// prefixes a `+` for non-negative values, which would render as `+2026-10-12`.
pub fn isoDay(buf: *[10]u8, date: Date) []const u8 {
    const civil = civilFromDays(@divFloor(date.unix, std.time.s_per_day));
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}", .{
        @as(u32, @intCast(civil.year)),
        civil.month,
        civil.day,
    }) catch unreachable;
}

/// `isoDay`, on the heap.
pub fn formatDay(gpa: Allocator, date: Date) Allocator.Error![]const u8 {
    var buf: [10]u8 = undefined;
    return gpa.dupe(u8, isoDay(&buf, date));
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
        "README.md\n" ++
        "guide/QUICK-START.md\n" ++
        "\n" ++
        "zxdoc-commit 2026-01-02\n" ++
        "README.md\n" ++
        "other.md\n" ++
        "\n";

    try parse(gpa, arena_state.allocator(), output, &dates);

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

test "parse reads the paths git reports relative to the content directory" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    var dates: Dates = .{};
    defer dates.deinit(testing.allocator);

    // `git log --relative` run inside the content directory reports paths
    // with no content-directory prefix, which is exactly what
    // `Page.sourcePath` produces. A build that confuses the two looks up
    // every page under a name that is not in the map, which is a silent miss
    // rather than a visible failure.
    const output =
        "zxdoc-commit 2026-10-11\n" ++
        "README.md\n" ++
        "ai/AI.md\n" ++
        "\n";

    try parse(testing.allocator, arena_state.allocator(), output, &dates);

    try testing.expectEqual(@as(usize, 2), dates.entries.count());
    try testing.expect(dates.get("README.md") != null);
    try testing.expect(dates.get("ai/AI.md") != null);
}

test "parse skips a commit header with no paths after it" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    var dates: Dates = .{};
    defer dates.deinit(testing.allocator);

    // `--relative` drops the paths of a commit that touched nothing inside
    // the content directory, leaving a bare header. The following commit's
    // paths must not inherit its date, which is what resetting on the blank
    // line is for.
    const output =
        "zxdoc-commit 2026-10-11\n" ++
        "\n" ++
        "zxdoc-commit 2026-01-02\n" ++
        "README.md\n" ++
        "\n";

    try parse(testing.allocator, arena_state.allocator(), output, &dates);

    try testing.expectEqual(@as(usize, 1), dates.entries.count());
    try testing.expectEqual(
        parseDate("2026-01-02").?.unix,
        dates.get("README.md").?.unix,
    );
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

test "isoDay renders the date both consumers print" {
    const cases = [_]struct { y: i32, m: u8, d: u8, text: []const u8 }{
        .{ .y = 1970, .m = 1, .d = 1, .text = "1970-01-01" },
        // Single-digit fields are zero-padded: an unpadded `2026-1-2` is not
        // the date format either consumer's readers expect.
        .{ .y = 2026, .m = 1, .d = 2, .text = "2026-01-02" },
        .{ .y = 2000, .m = 2, .d = 29, .text = "2000-02-29" },
        .{ .y = 2026, .m = 10, .d = 12, .text = "2026-10-12" },
    };
    for (cases) |c| {
        var buf: [10]u8 = undefined;
        const date: Date = .{ .unix = daysFromCivil(c.y, c.m, c.d) * std.time.s_per_day };
        try testing.expectEqualStrings(c.text, isoDay(&buf, date));

        const owned = try formatDay(testing.allocator, date);
        defer testing.allocator.free(owned);
        try testing.expectEqualStrings(c.text, owned);
    }
}

test "isoDay does not prefix a plus onto the year" {
    // Zig's signed integer formatting writes `+2026`, which would render the
    // date as `+2026-10-12` and be rejected by a sitemap reader.
    var buf: [10]u8 = undefined;
    const text = isoDay(&buf, .{ .unix = daysFromCivil(2026, 10, 12) * std.time.s_per_day });
    try testing.expect(text[0] >= '0' and text[0] <= '9');
}
