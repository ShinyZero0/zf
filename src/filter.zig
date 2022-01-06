const std = @import("std");
const ArrayList = std.ArrayList;
const testing = std.testing;

/// Candidates are the strings read from stdin
/// if the filepath matching algorithm is used, then name will be
/// used to store the filename of the path in str.
///
/// lowercase versions of the full path and of the name are stored
/// for smart case matching
pub const Candidate = struct {
    str: []const u8,
    str_lower: []const u8,
    name: ?[]const u8 = null,
    name_lower: ?[]const u8 = null,
    rank: usize = 0,
};

pub fn contains(str: []const u8, byte: u8) bool {
    for (str) |b| {
        if (b == byte) return true;
    }
    return false;
}

/// if a string contains either a separator or a . character, then we assume it is a filepath
fn isPath(str: []const u8) bool {
    if (contains(str, std.fs.path.sep)) return true;
    if (contains(str, '.')) return true;
    return false;
}

test "is path" {
    try testing.expect(isPath("/dev/null"));
    try testing.expect(isPath("main.zig"));
    try testing.expect(isPath("src/tty.zig"));
    try testing.expect(isPath("a/b/c"));

    try testing.expect(!isPath("a"));
    try testing.expect(!isPath("abcdefghijklmnopqrstuvwxyz"));

    // the heuristics are not perfect! not all "files" will be considered as a file
    try testing.expect(!isPath("Makefile"));
}

/// read the candidates from the buffer
pub fn collectCandidates(allocator: std.mem.Allocator, buf: []const u8, delimiter: u8) ![]Candidate {
    var candidates = ArrayList(Candidate).init(allocator);

    // find delimiters
    var start: usize = 0;
    for (buf) |char, index| {
        if (char == delimiter) {
            // add to arraylist only if slice is not all delimiters
            if (index - start != 0) {
                var lower = try allocator.alloc(u8, index - start);
                std.mem.copy(u8, lower, buf[start..index]);
                _ = std.ascii.lowerString(lower, lower);

                try candidates.append(.{ .str = buf[start..index], .str_lower = lower });
            }
            start = index + 1;
        }
    }

    // catch the end if stdio didn't end in a delimiter
    if (start < buf.len) {
        var lower = try allocator.alloc(u8, buf.len - start);
        std.mem.copy(u8, lower, buf[start..]);
        _ = std.ascii.lowerString(lower, lower);

        try candidates.append(.{ .str = buf[start..], .str_lower = lower });
    }

    // determine if these candidates are filepaths
    // const end = candidates.items.len - 1;
    // const filename_match = isPath(candidates.items[0].str) or isPath(candidates.items[end].str) or isPath(candidates.items[end / 2].str);
    const filename_match = true;

    if (filename_match) {
        for (candidates.items) |*candidate| {
            candidate.name = std.fs.path.basename(candidate.str);
            candidate.name_lower = std.fs.path.basename(candidate.str_lower);
        }
    }

    // std.sort.sort(Candidate, candidates.items, {}, sort);

    return candidates.toOwnedSlice();
}

test "collectCandidates whitespace" {
    var candidates = try collectCandidates(testing.allocator, "first second third fourth", ' ');
    defer {
        for (candidates) |c| {
            testing.allocator.free(c.str_lower);
        }
        testing.allocator.free(candidates);
    }

    try testing.expectEqual(@as(usize, 4), candidates.len);
    try testing.expectEqualStrings("first", candidates[0].str);
    try testing.expectEqualStrings("second", candidates[1].str);
    try testing.expectEqualStrings("third", candidates[2].str);
    try testing.expectEqualStrings("fourth", candidates[3].str);
}

test "collectCandidates newline" {
    var candidates = try collectCandidates(testing.allocator, "first\nsecond\nthird\nfourth", '\n');
    defer {
        for (candidates) |c| {
            testing.allocator.free(c.str_lower);
        }
        testing.allocator.free(candidates);
    }

    try testing.expectEqual(@as(usize, 4), candidates.len);
    try testing.expectEqualStrings("first", candidates[0].str);
    try testing.expectEqualStrings("second", candidates[1].str);
    try testing.expectEqualStrings("third", candidates[2].str);
    try testing.expectEqualStrings("fourth", candidates[3].str);
}

test "collectCandidates excess whitespace" {
    var candidates = try collectCandidates(testing.allocator, "   first second   third fourth   ", ' ');
    defer {
        for (candidates) |c| {
            testing.allocator.free(c.str_lower);
        }
        testing.allocator.free(candidates);
    }

    try testing.expectEqual(@as(usize, 4), candidates.len);
    try testing.expectEqualStrings("first", candidates[0].str);
    try testing.expectEqualStrings("second", candidates[1].str);
    try testing.expectEqualStrings("third", candidates[2].str);
    try testing.expectEqualStrings("fourth", candidates[3].str);
}

fn hasUpper(query: []const u8) bool {
    for (query) |*c| {
        if (std.ascii.isUpper(c.*)) return true;
    }
    return false;
}

/// rank each candidate against the query
///
/// returns a sorted slice of Candidates that match the query ready for display
/// in a tui or output to stdout
pub fn rankCandidates(allocator: std.mem.Allocator, candidates: []Candidate, query: []const u8) ![]Candidate {
    var ranked = ArrayList(Candidate).init(allocator);

    if (query.len == 0) {
        for (candidates) |candidate| {
            try ranked.append(candidate);
        }
        return ranked.toOwnedSlice();
    }

    var query_tokens = try splitQuery(allocator, query);
    defer allocator.free(query_tokens);
    for (candidates) |candidate| {
        var c = candidate;
        if (rankCandidate(&c, query_tokens)) {
            try ranked.append(c);
        }
    }

    std.sort.sort(Candidate, ranked.items, {}, sort);

    return ranked.toOwnedSlice();
}

/// split the query on spaces and return a slice of query tokens
fn splitQuery(allocator: std.mem.Allocator, query: []const u8) ![][]const u8 {
    var tokens = ArrayList([]const u8).init(allocator);

    var it = std.mem.tokenize(u8, query, " ");
    while (it.next()) |token| {
        try tokens.append(token);
    }

    return tokens.toOwnedSlice();
}

const IndexIterator = struct {
    str: []const u8,
    char: u8,
    index: usize = 0,

    pub fn init(str: []const u8, char: u8) @This() {
        return .{ .str = str, .char = char };
    }

    pub fn next(self: *@This()) ?usize {
        const index = std.mem.indexOfScalarPos(u8, self.str, self.index, self.char);
        if (index) |i| self.index = i + 1;
        return index;
    }
};

/// rank a candidate against the given query tokens
///
/// algorithm inspired by https://github.com/garybernhardt/selecta
fn rankCandidate(candidate: *Candidate, query_tokens: [][]const u8) bool {
    candidate.rank = 0;

    // the candidate must contain all of the characters (in order) in each token.
    // each tokens rank is summed. if any token does not match the candidate is ignored
    for (query_tokens) |token| {
        // iterate over the indexes where the first char of the token matches
        var best_rank: ?usize = null;
        var it = IndexIterator.init(candidate.name.?, token[0]);

        // TODO: rank better for name matches
        while (it.next()) |start_index| {
            if (scanToEnd(candidate.name.?, token[1..], start_index)) |rank| {
                if (best_rank == null or rank < best_rank.?) best_rank = rank -| 2;
            }
        }

        // retry on the full string
        if (best_rank == null) {
            it = IndexIterator.init(candidate.str, token[0]);
            while (it.next()) |start_index| {
                if (scanToEnd(candidate.str, token[1..], start_index)) |rank| {
                    if (best_rank == null or rank < best_rank.?) best_rank = rank;
                }
            }
        }

        if (best_rank == null) return false;

        candidate.rank += best_rank.?;
    }

    // all tokens matched and the best ranks for each tokens are summed
    return true;
}

/// this is the core of the ranking algorithm. special precedence is given to
/// filenames. if a match is found on a filename the candidate is ranked higher
fn scanToEnd(str: []const u8, token: []const u8, start_index: usize) ?usize {
    var rank: usize = 1;
    var last_index = start_index;
    var last_sequential = false;

    for (token) |c| {
        const index = std.mem.indexOfScalarPos(u8, str, last_index, c);
        if (index == null) return null;

        if (index.? == last_index + 1) {
            // sequential matches only count the first character
            if (!last_sequential) {
                last_sequential = true;
                rank += 1;
            }
        } else {
            // normal match
            last_sequential = false;
            rank += index.? - last_index;
        }

        last_index = index.?;
    }

    return rank;
}

pub fn filter(allocator: std.mem.Allocator, candidates: []Candidate, query: []const u8) ![]Candidate {
    var filtered = ArrayList(Candidate).init(allocator);
    const match_case = hasUpper(query);

    if (query.len == 0) {
        for (candidates) |candidate| {
            try filtered.append(candidate);
        }
        return filtered.toOwnedSlice();
    }

    for (candidates) |*candidate| {
        var str: []const u8 = undefined;
        var name: ?[]const u8 = undefined;

        if (match_case) {
            str = candidate.str;
            name = candidate.name;
        } else {
            str = candidate.str_lower;
            name = candidate.name_lower;
        }

        candidate.score = score(str, name, query, true);
        if (candidate.score > 0) try filtered.append(candidate.*);
    }

    return filtered.toOwnedSlice();
}

/// search for needle in haystack and return length of matching substring
/// returns null if there is no match
fn fuzzyMatch(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len > haystack.len) return null;

    var start: ?usize = null;
    var matches: usize = 0;
    for (haystack) |char, i| {
        if (needle[matches] == char) {
            if (start == null) start = i;
            matches += 1;
        }

        // all chars have matched
        if (matches == needle.len) return i - start.? + 1;
    }

    return null;
}

test "fuzzy match" {
    try testing.expect(fuzzyMatch("abcdefg", "z") == null);
    try testing.expect(fuzzyMatch("a", "xyz") == null);
    try testing.expect(fuzzyMatch("xy", "xyz") == null);

    try testing.expect(fuzzyMatch("abc", "a").? == 1);
    try testing.expect(fuzzyMatch("abc", "abc").? == 3);
    try testing.expect(fuzzyMatch("abc", "ac").? == 3);
    try testing.expect(fuzzyMatch("main.zig", "mi").? == 3);
    try testing.expect(fuzzyMatch("main.zig", "miz").? == 6);
    try testing.expect(fuzzyMatch("main.zig", "mzig").? == 8);
    try testing.expect(fuzzyMatch("main.zig", "zig").? == 3);
}

/// rate how closely the query matches the candidate
fn score(str: []const u8, name: ?[]const u8, query: []const u8, filepath: bool) usize {
    if (filepath) {
        if (fuzzyMatch(name.?, query)) |_| {
            return 1;
        }
    }

    if (query.len > str.len) return 0;

    if (fuzzyMatch(str, query)) |s| {
        return s;
    }

    return 0;
}

test "simple filter" {
    // var candidates = [_][]const u8{ "abc", "xyz", "abcdef" };

    // // match all strings containing "abc"
    // var filtered = try filter(testing.allocator, candidates[0..], "abc");
    // defer filtered.deinit();

    // var expected = [_][]const u8{ "abc", "abcdef" };
    // try testing.expectEqualSlices([]const u8, expected[0..], filtered.items);
}

pub fn sort(_: void, a: Candidate, b: Candidate) bool {
    // first by rank
    if (a.rank < b.rank) return true;
    if (a.rank > b.rank) return false;

    // then by length
    if (a.str.len < b.str.len) return true;
    if (a.str.len > b.str.len) return false;

    // then alphabetically
    for (a.str) |c, i| {
        if (c < b.str[i]) return true;
        if (c > b.str[i]) return false;
    }
    return false;
}
