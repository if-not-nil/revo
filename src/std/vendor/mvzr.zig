//!
//! vendored MIT, from https://github.com/mnemnion/mvzr
//!
//! mvzr: Minimum Viable Zig Regex
//!
//! A minimalistic, but y'know, viable, Zig regex library.
//!
//! Focused on basic support of runtime-provided regular expressions.

const builtin = @import("builtin");
const std = @import("std");
const assert = std.debug.assert;

// Zig is very particular about the types of shifts.
const one: u64 = 1;

/// Maximum regex operations.
pub const MAX_REGEX_OPS = 64;
/// Maximum character sets, ASCII only.
pub const MAX_CHAR_SETS = 8;

const RegexType = enum(u5) {
    unused,
    begin,
    end,
    left,
    right,
    word_break,
    not_word_break,
    alt,
    optional,
    star,
    plus,
    lazy_optional,
    lazy_star,
    lazy_plus,
    eager_optional,
    eager_star,
    eager_plus,
    some,
    up_to,
    eager_up_to,
    dot,
    char,
    class,
    not_class,
    high_class,
    not_high_class,
    digit,
    not_digit,
    alpha,
    not_alpha,
    whitespace,
    not_whitespace, // #26, can add five before bumping to u6
};

pub const RegOp = union(RegexType) {
    unused: void,
    begin: void,
    end: void,
    left: void, // TODO add offset u8
    right: void, // TODO add head-match offset
    word_break: void,
    not_word_break: void,
    alt: void, // TODO add offset u8
    optional: void,
    star: void,
    plus: void,
    lazy_optional: void,
    lazy_star: void,
    lazy_plus: void,
    eager_optional: void,
    eager_star: void,
    eager_plus: void,
    some: u8,
    up_to: u8,
    eager_up_to: u8,
    dot: void,
    char: u8, // character byte
    class: u8, // offset into class array (ASCII)
    not_class: u8,
    high_class: u8, // offset into class array (high bytes)
    not_high_class: u8,
    digit: void,
    not_digit: void,
    alpha: void,
    not_alpha: void,
    whitespace: void,
    not_whitespace: void,
};

pub const CharSet = struct {
    low: u64 = 0,
    hi: u64 = 0,
};

const OpMatch = struct {
    j: []const RegOp,
    i: usize,
};

pub const Regex: type = SizedRegex(MAX_REGEX_OPS, MAX_CHAR_SETS);

pub fn SizedRegex(ops: comptime_int, char_sets: comptime_int) type {
    return struct {
        patt: [ops]RegOp = @splat(.{ .unused = {} }),
        sets: [char_sets]CharSet = @splat(.{ .low = 0, .hi = 0 }),

        const SizedRegexT = @This();

        pub fn compile(patt: []const u8) ?SizedRegexT {
            return compileRegex(SizedRegexT, patt);
        }

        /// Match a regex pattern in `haystack`, if found, this returns a `Match`.
        pub fn match(regex: *const SizedRegexT, haystack: []const u8) ?Match {
            const maybe_matched = regex.matchInternal(haystack);
            if (maybe_matched) |m| {
                const m1 = m[0];
                const m2 = m[1];
                return Match{
                    .slice = haystack[m1..m2],
                    .start = m1,
                    .end = m2,
                };
            } else {
                return null;
            }
        }

        /// Match a regex pattern in `haystack` after `pos`.  Returns a `Match`
        /// if the pattern is found.
        pub fn matchPos(regex: *const SizedRegexT, pos: usize, haystack: []const u8) ?Match {
            if (pos >= haystack.len) return null;
            const substack = haystack[pos..];
            const maybe_matched = regex.matchInternal(substack);
            if (maybe_matched) |m| {
                const m1 = pos + m[0];
                const m2 = pos + m[1];
                return Match{
                    .slice = haystack[m1..m2],
                    .start = m1,
                    .end = m2,
                };
            } else {
                return null;
            }
        }

        /// Boolean test if the regex matches in the haystack.
        pub fn isMatch(regex: *const SizedRegexT, haystack: []const u8) bool {
            const maybe_matched = regex.matchInternal(haystack);
            if (maybe_matched) |_| {
                return true;
            } else {
                return false;
            }
        }

        /// Copy a Regex to the heap, returning a pointer.  Free the memory
        /// later with `allocator.destroy(owned_regex)`.
        pub fn toOwnedRegex(regex: *const SizedRegexT, allocator: std.mem.Allocator) !*const SizedRegexT {
            const heap_regex = try allocator.create(SizedRegexT);
            heap_regex.* = regex.*;
            return heap_regex;
        }

        /// Return an iterator over all matches.  Call `next` until exhausted.
        /// A `Match` struct is returned for successful matches, consisting of
        /// the match in both slice and bookend form.
        pub fn iterator(regex: *const SizedRegexT, haystack: []const u8) RegexIterator {
            return RegexIterator{
                .regex = regex,
                .haystack = haystack,
            };
        }

        pub const RegexIterator = struct {
            regex: *const SizedRegexT,
            idx: usize = 0,
            haystack: []const u8,

            pub fn next(iter: *RegexIterator) ?Match {
                if (iter.idx > iter.haystack.len) return null;
                const maybe_match = iter.regex.match(iter.haystack[iter.idx..]);
                if (maybe_match) |m| {
                    const m_start = m.start + iter.idx;
                    const m_end = m.end + iter.idx;
                    iter.idx += @max(m.end, 1);
                    return Match{
                        .slice = m.slice,
                        .start = m_start,
                        .end = m_end,
                    };
                } else {
                    return null;
                }
            }
        };

        fn matchInternal(regex: *const SizedRegexT, haystack: []const u8) ?struct { usize, usize } {
            const end = regex.findPatternEnd();
            const patt = regex.patt[0..end];
            if (patt.len == 0) return .{ 0, 0 };
            switch (patt[0]) {
                .begin => {
                    const matched: ?OpMatch = matchOuterPattern(patt[1..], &regex.sets, haystack, 0);
                    if (matched) |m| {
                        return .{ 0, m.i };
                    } else return null;
                },
                else => {
                    var matchlen: usize = 0;
                    while (matchlen <= haystack.len) : (matchlen += 1) {
                        const matched: ?OpMatch = matchOuterPattern(patt, &regex.sets, haystack, matchlen);
                        if (matched) |m| {
                            return .{ matchlen, m.i };
                        }
                    }
                    return null;
                },
            }
        }

        fn findPatternEnd(regex: *const SizedRegexT) usize {
            const patt = regex.patt;
            for (0..patt.len) |i| {
                if (patt[i] == .unused) {
                    return i;
                }
            }
            return patt.len;
        }
    };
}

/// A single match as returned from `regex.match` and `regex.iterator`.
/// Note that the slice is borrowed from the haystack: to own it, call
/// `try match.toOwned(allocator)`.
pub const Match = struct {
    slice: []const u8,
    start: usize,
    end: usize,

    /// Return an copy of the Match with fresh memory allocator for the
    /// slice.
    pub fn toOwnedMatch(matched: Match, allocator: std.mem.Allocator) !Match {
        const new_slice = try allocator.dupe(u8, matched.slice);
        return Match{
            .slice = new_slice,
            .start = matched.start,
            .end = matched.end,
        };
    }

    /// For freeing copied Match structs created with `toOwned`.
    pub fn deinit(matched: Match, allocator: std.mem.Allocator) void {
        allocator.free(matched.slice);
    }

    pub fn format(
        matched: Match,
        writer: anytype,
    ) !void {
        try writer.print("[{d}..{d}]: \"{f}\"", .{
            matched.start,
            matched.end,
            std.zig.fmtString(matched.slice),
        });
    }
};

/// Match `pattern` in `haystack`.
pub fn match(haystack: []const u8, pattern: []const u8) ?Match {
    const maybe_regex = compile(pattern);
    if (maybe_regex) |regex| {
        return regex.match(haystack);
    } else {
        return null;
    }
}

/// Entry point for matching a pattern.
fn matchOuterPattern(patt: []const RegOp, sets: []const CharSet, haystack: []const u8, i: usize) ?OpMatch {
    if (findAlt(patt, 0)) |_| {
        // There's at least one alt.
        var remaining_patt = patt;
        while (true) {
            const this_match = matchAlt(remaining_patt, sets, haystack, i);
            if (this_match) |m1| {
                // Matched
                return OpMatch{ .i = m1.i, .j = patt[0..0] };
            } else {
                const maybe_next = maybeAlt(remaining_patt);
                if (maybe_next) |next_patt| {
                    remaining_patt = remaining_patt[next_patt.len + 1 ..];
                } else { // Ran out of pattern
                    return null;
                }
            }
        }
    } else { // No alt.
        return matchPattern(patt, sets, haystack, i);
    }
}

fn matchPattern(patt: []const RegOp, sets: []const CharSet, haystack: []const u8, i_in: usize) ?OpMatch {
    var i: usize = i_in;
    var this_patt = patt;
    dispatch: while (this_patt.len != 0) {
        if (i == haystack.len) {
            switch (this_patt[0]) {
                .word_break, .not_word_break => {
                    if (haystack.len == 0) return null;
                },
                .optional,
                .star,
                .lazy_optional,
                .lazy_star,
                .eager_optional,
                .eager_star,
                .up_to,
                .eager_up_to,
                .end,
                => {
                    this_patt = nextPattern(this_patt);
                    continue :dispatch;
                },
                .left => {
                    if (groupAcceptsEmpty(this_patt)) {
                        this_patt = nextPattern(this_patt);
                        continue :dispatch;
                    } else {
                        return null;
                    }
                },
                .some => |how_many| {
                    if (how_many == 0) {
                        this_patt = nextPattern(this_patt);
                        continue :dispatch;
                    } else {
                        return null;
                    }
                },
                .begin,
                .plus,
                .lazy_plus,
                .eager_plus,
                .dot,
                .class,
                .not_class,
                .high_class,
                .not_high_class,
                .digit,
                .not_digit,
                .alpha,
                .not_alpha,
                .whitespace,
                .not_whitespace,
                .char,
                => return null,
                .right, .alt, .unused => unreachable,
            }
        }
        const maybe_match: ?OpMatch = switch (this_patt[0]) {
            .dot,
            .class,
            .not_class,
            .high_class,
            .not_high_class,
            .digit,
            .not_digit,
            .alpha,
            .not_alpha,
            .whitespace,
            .not_whitespace,
            .char,
            => matchOne(this_patt, sets, haystack, i),
            .optional => matchOptional(this_patt[1..], sets, haystack, i),
            .star => matchStar(this_patt[1..], sets, haystack, i),
            .plus => matchPlus(this_patt[1..], sets, haystack, i),
            .lazy_optional => matchLazyOptional(this_patt[1..], sets, haystack, i),
            .lazy_star => matchLazyStar(this_patt[1..], sets, haystack, i),
            .lazy_plus => matchLazyPlus(this_patt[1..], sets, haystack, i),
            .eager_optional => matchEagerOptional(this_patt[1..], sets, haystack, i),
            .eager_star => matchEagerStar(this_patt[1..], sets, haystack, i),
            .eager_plus => matchEagerPlus(this_patt[1..], sets, haystack, i),
            .some => matchSome(this_patt, sets, haystack, i),
            .up_to => matchUpTo(this_patt, sets, haystack, i),
            .eager_up_to => matchEagerUpTo(this_patt, sets, haystack, i),
            .left => matchGroup(this_patt, sets, haystack, i),
            .word_break => matchWordBreak(this_patt, sets, haystack, i),
            .not_word_break => matchNotWordBreak(this_patt, sets, haystack, i),
            .end => { // We accept a final newline, but only a Unix one
                if (i + 1 == haystack.len and haystack[i] == '\n') {
                    // Compiler ensures that this is the last operation
                    return OpMatch{ .i = i + 1, .j = patt[0..0] };
                } else // Ok.  Fine, we'll try it the Windows way
                if (i + 2 == haystack.len // Such a dumb convention
                and haystack[i] == '\r' // Suck it Bill Gates
                and haystack[i + 1] == '\n') { // Thanks for making my regex engine slow
                    // Still. Nothing but the best for my users
                    return OpMatch{ .i = i + 2, .j = patt[0..0] };
                }

                return null;
            },
            .unused, .alt, .right, .begin => unreachable, // probably
        };
        if (maybe_match) |m| {
            this_patt = m.j;
            i = m.i;
            assert(!(i > haystack.len));
        } else {
            return null;
        }
    }
    if (this_patt.len == 0) // We've matched
        return OpMatch{ .i = i, .j = this_patt }
    else
        return null;
}

const ascii = std.ascii;

inline fn isWordChar(c: u8) bool {
    return ascii.isAlphanumeric(c) or c == '_';
}

fn matchOne(patt: []const RegOp, sets: []const CharSet, haystack: []const u8, i: usize) ?OpMatch {
    if (matchOneByte(patt[0], sets, haystack[i])) {
        return OpMatch{ .i = 1 + i, .j = patt[1..] };
    } else {
        return null;
    }
}

fn matchOneByte(op: RegOp, sets: []const CharSet, c: u8) bool {
    return switch (op) {
        .dot => true, // We match newlines, deal with it
        .class => |c_off| matchClass(sets[c_off], c),
        .not_class => |c_off| !matchClass(sets[c_off], c),
        .high_class => |c_off| matchHighClass(sets[c_off], c),
        .not_high_class => |c_off| !matchHighClass(sets[c_off], c),
        .digit => ascii.isDigit(c),
        .not_digit => !ascii.isDigit(c),
        .alpha => isWordChar(c),
        .not_alpha => !isWordChar(c),
        .whitespace => ascii.isWhitespace(c),
        .not_whitespace => !ascii.isWhitespace(c),
        .char => |ch| (c == ch),
        else => unreachable,
    };
}

fn matchStar(patt: []const RegOp, sets: []const CharSet, haystack: []const u8, i_in: usize) OpMatch {
    var i = i_in;
    const this_patt = thisPattern(patt);
    while (matchPattern(this_patt, sets, haystack, i)) |m| {
        const i_before = i;
        i = m.i;
        assert(!(i > haystack.len));
        // End of string or no progress? break
        if (i == haystack.len or i == i_before) break;
    }

    const next_patt = nextPattern(patt);
    if (next_patt.len == 0) {
        return OpMatch{ .i = i, .j = next_patt };
    }

    const maybe_next = matchPattern(next_patt, sets, haystack, i);
    if (maybe_next) |m2| {
        return m2;
    } // otherwise we gotta do the loopback dance.
    // TODO this logic is wrong because /our/ pattern might not match at every point in the string.
    // fix that later (I have something in mind here: a mask storing an intersection of every real
    // match for us, with a potential match for the next guy)
    //
    // Theory: if we switch to matchLazyStar here, starting from the beginning, we always get what
    // we came for, but pay the minimum amount for it.
    i = if (i == i_in) i_in else (i - 1);
    while (true) {
        const try_next = matchPattern(next_patt, sets, haystack, i);
        if (try_next) |m2| {
            // Verify that our pattern can also match here
            if (matchPattern(this_patt, sets, haystack, i)) |_| {
                return m2;
            } // Otherwise we keep backing out
        }
        if (i == i_in) break;
        i -= 1;
    } // This might be ok (alts)

    return OpMatch{ .i = i_in, .j = next_patt };
}

fn matchPlus(patt: []const RegOp, sets: []const CharSet, haystack: []const u8, i: usize) ?OpMatch {
    const this_patt = thisPattern(patt);
    const first_m = matchPattern(this_patt, sets, haystack, i);
    if (first_m == null) return null;
    const m1 = first_m.?;
    // We can skip matchStar if we're at the end
    if (m1.i == haystack.len) return OpMatch{ .i = m1.i, .j = nextPattern(patt) };
    const m2 = matchStar(patt, sets, haystack, m1.i);
    // If matchStar produced 0 cursor move, then its m2.j is probably invalid:
    // Neither the * nor the next pattern matched, so we use ours.  If the
    // nextPattern is also able to match zero, it will do so again.
    if (m2.i == m1.i) {
        return OpMatch{ .i = m1.i, .j = nextPattern(patt) };
    } else {
        return m2;
    }
}

fn matchOptional(patt: []const RegOp, sets: []const CharSet, haystack: []const u8, i_in: usize) ?OpMatch {
    const this_patt = thisPattern(patt);
    const maybe_m = matchPattern(this_patt, sets, haystack, i_in);
    if (maybe_m) |m1| {
        // See if we can succeed here
        const next_patt = nextPattern(patt);
        var i = m1.i;
        if (next_patt.len != 0) {
            if (i == haystack.len and next_patt[0] != .end) {
                // Reset.
                i = i_in;
            }
            const maybe_next = matchPattern(next_patt, sets, haystack, i);
            if (maybe_next) |m2| {
                return m2;
            } else { // Drop our match.
                return matchPattern(next_patt, sets, haystack, i_in);
            }
        } else {
            return m1;
        }
    } else { // Match was optional, try next pattern
        return OpMatch{ .i = i_in, .j = nextPattern(patt) };
    }
}

fn matchEagerOptional(patt: []const RegOp, sets: []const CharSet, haystack: []const u8, i: usize) OpMatch {
    const this_patt = thisPattern(patt);
    const maybe_m = matchPattern(this_patt, sets, haystack, i);
    if (maybe_m) |m| {
        return OpMatch{ .i = m.i, .j = nextPattern(patt) };
    } else {
        return OpMatch{ .i = i, .j = nextPattern(patt) };
    }
}

fn matchLazyStar(patt: []const RegOp, sets: []const CharSet, haystack: []const u8, i_in: usize) OpMatch {
    const this_patt = thisPattern(patt);
    const next_patt = nextPattern(patt);
    // Other guy gets the first shot
    var match_first = if (next_patt.len != 0)
        matchPattern(next_patt, sets, haystack, i_in)
    else
        null;

    if (match_first) |m| {
        return m;
    }

    var i: usize = i_in;
    // Our turn
    match_first = matchPattern(this_patt, sets, haystack, i);
    if (match_first) |m| {
        if (m.i == i) return OpMatch{ .i = i, .j = next_patt };
        i = m.i;
    }
    // Now we alternate
    while (true) {
        if (i == haystack.len)
            return OpMatch{ .i = i, .j = next_patt };
        // Always try next first
        const match_theirs = matchPattern(next_patt, sets, haystack, i);
        if (match_theirs) |m1| {
            // All done
            return m1;
        } else {
            const match_ours = matchPattern(this_patt, sets, haystack, i);
            if (match_ours) |m2| {
                // Keep it up
                if (m2.i == i) return OpMatch{ .i = i, .j = next_patt };
                i = m2.i;
            } else {
                // other guy's turn coming up
                return OpMatch{ .i = i, .j = next_patt };
            }
        }
    }
}

fn matchLazyPlus(patt: []const RegOp, sets: []const CharSet, haystack: []const u8, i: usize) ?OpMatch {
    const this_patt = thisPattern(patt);
    const first_m = matchPattern(this_patt, sets, haystack, i);
    if (first_m == null) return null;
    const m1 = first_m.?;
    if (m1.i == haystack.len) return OpMatch{ .i = m1.i, .j = nextPattern(patt) };
    const m2 = matchLazyStar(patt, sets, haystack, m1.i);
    // TODO do we need to reset to m1.j if m2.i == m1.i? Probably (not)
    return m2;
}

fn matchLazyOptional(patt: []const RegOp, sets: []const CharSet, haystack: []const u8, i: usize) ?OpMatch {
    // try the rest first
    const maybe_match = matchPattern(nextPattern(patt), sets, haystack, i);
    if (maybe_match) |m| {
        return m;
    }
    return matchEagerOptional(patt, sets, haystack, i);
}

fn matchEagerPlus(patt: []const RegOp, sets: []const CharSet, haystack: []const u8, i: usize) ?OpMatch {
    const this_patt = thisPattern(patt);
    const first_m = matchPattern(this_patt, sets, haystack, i);
    if (first_m == null) return null;
    const m1 = first_m.?;
    if (m1.i == haystack.len) return OpMatch{ .i = m1.i, .j = nextPattern(patt) };
    const m2 = matchEagerStar(patt, sets, haystack, m1.i);
    return m2;
}

fn matchEagerStar(patt: []const RegOp, sets: []const CharSet, haystack: []const u8, i_in: usize) OpMatch {
    const this_patt = thisPattern(patt);
    var i = i_in;
    while (matchPattern(this_patt, sets, haystack, i)) |m| {
        const i_before = i;
        i = m.i;
        assert(!(i > haystack.len));
        if (i == haystack.len or i == i_before) break;
    }
    return OpMatch{ .i = i, .j = nextPattern(patt) };
}

fn matchSome(patt: []const RegOp, sets: []const CharSet, haystack: []const u8, i_in: usize) ?OpMatch {
    var count = patt[0].some;
    var i = i_in;
    const this_patt = if (patt[1] == .up_to or patt[1] == .eager_up_to or patt[1] == .star)
        thisPattern(patt[2..])
    else
        thisPattern(patt[1..]);

    while (count > 0) : (count -= 1) {
        const matched = matchPattern(this_patt, sets, haystack, i);
        if (matched) |m| {
            i = m.i;
        } else {
            return null;
        }
    } // We may need to slice manually
    if (patt[1] == .eager_up_to or patt[1] == .up_to or patt[1] == .star) {
        return OpMatch{ .i = i, .j = patt[1..] };
    } else {
        return OpMatch{ .i = i, .j = nextPattern(patt) };
    }
}

fn matchUpTo(patt: []const RegOp, sets: []const CharSet, haystack: []const u8, i: usize) OpMatch {
    const more_match = matchUpToInner(patt[1..], sets, haystack, i, patt[0].up_to);
    if (more_match) |m|
        return m
    else // This one we don't need to slice
        return OpMatch{ .i = i, .j = nextPattern(patt) };
}

fn matchUpToInner(
    patt: []const RegOp,
    sets: []const CharSet,
    haystack: []const u8,
    i_in: usize,
    count: usize,
) ?OpMatch {
    if (count == 1) { // Last try is an optional
        const opt = matchOptional(patt, sets, haystack, i_in);
        // TODO this can return directly, this way is breakpoint-friendly
        return opt;
    }
    const this_patt = thisPattern(patt);

    const maybe_m = matchPattern(this_patt, sets, haystack, i_in);
    if (maybe_m) |m1| {
        // See if we can succeed here
        // TODO I think this logic is lazy, it should be 'greedy'
        // Hmm, no, but it's a bit convoluted and can probably be more efficient
        const next_patt = nextPattern(patt);
        var i = m1.i;
        var maybe_next: ?OpMatch = null;
        if (next_patt.len != 0) {
            if (i == haystack.len and next_patt[0] != .end) {
                // Reset (we still have m1.i)
                i = i_in;
            }
            maybe_next = matchPattern(next_patt, sets, haystack, i);
            if (maybe_next) |m2| {
                if (m2.i == haystack.len) {
                    // As far as it goes
                    return m2;
                }
            }
        }
        const maybe_rest = matchUpToInner(patt, sets, haystack, m1.i, count - 1);
        if (maybe_rest) |m3| {
            return m3;
        }
        // Otherwise we backtrack from down stack.
        if (maybe_next) |m2| {
            return m2;
        } else {
            return null;
        }
    } else {
        return null;
    }
}

fn matchEagerUpTo(patt: []const RegOp, sets: []const CharSet, haystack: []const u8, i_in: usize) OpMatch {
    const this_patt = thisPattern(patt[1..]);
    const first_match = matchPattern(this_patt, sets, haystack, i_in);
    if (first_match == null) return OpMatch{ .i = i_in, .j = nextPattern(patt) };
    // Keep it up
    var latest_match: OpMatch = first_match.?;
    var count = patt[0].eager_up_to - 1;
    while (count > 0) : (count -= 1) {
        const next_match = matchPattern(this_patt, sets, haystack, latest_match.i);
        if (next_match) |m| {
            latest_match = m;
        } else {
            break;
        }
    }
    return OpMatch{ .i = latest_match.i, .j = nextPattern(patt) };
}

fn matchGroup(patt: []const RegOp, sets: []const CharSet, haystack: []const u8, i: usize) ?OpMatch {
    // Cut out the group pattern:
    const inner_patt = sliceGroup(patt);
    // Empty group is a match:
    if (inner_patt.len == 0) {
        return OpMatch{ .i = i, .j = nextPattern(patt) };
    }
    // And the next pattern (can be empty)
    const next_patt = nextPattern(patt);
    // Are there alts?
    if (!hasAlt(patt)) {
        const maybe_match = matchPattern(inner_patt, sets, haystack, i);
        if (maybe_match) |m| {
            // Success, return the next pattern.
            return OpMatch{ .i = m.i, .j = next_patt };
        } else { // Fail,  with nothing left to try.
            return null;
        }
    } // There's at least one alt.
    // Is there another pattern to check?
    if (next_patt.len == 0) {
        // NOTE: This is where we might implement 'leftmost longest'.  Current
        // behavior short-circuits on the first match, but we can keep trying
        // and keep the longest of any matches.
        const our_match = matchAlt(inner_patt, sets, haystack, i);
        if (our_match) |m| {
            // Strip the remaining matches, may as well use empty next_patt
            return OpMatch{ .i = m.i, .j = next_patt };
        }
    } // Try anything potentially unmatched, using the next pattern to test success
    var remaining_patt = inner_patt;
    while (remaining_patt.len != 0) {
        const this_match = matchAlt(remaining_patt, sets, haystack, i);
        if (this_match) |m1| {
            // Make sure the next pattern passes:
            const next_match = matchPattern(next_patt, sets, haystack, m1.i);
            if (next_match) |m2| {
                // Whole group matches, and we can use m2.j
                return m2;
            } else { // Try our next pattern, if any.
                remaining_patt = m1.j;
            }
        } else { // Nothing in our group passed
            return null;
        }
    } // Ran out of pattern
    return null;
}

fn matchWordBreak(patt: []const RegOp, sets: []const CharSet, haystack: []const u8, i: usize) ?OpMatch {
    if (i == haystack.len) {
        if (isWordChar(haystack[i - 1])) {
            return OpMatch{ .i = i, .j = nextPattern(patt) };
        } else {
            return null;
        }
    }
    const this_is_word = isWordChar(haystack[i]);
    if (i == 0) {
        if (this_is_word) {
            return OpMatch{ .i = i, .j = nextPattern(patt) };
        } else {
            return null;
        }
    } // i is now > 0, i - 1 is legal
    const was_word = isWordChar(haystack[i - 1]);
    // If this is a \w and what precedes isn't, word break:
    if (!was_word and this_is_word) {
        return OpMatch{ .i = i, .j = nextPattern(patt) };
    } else if (was_word and !this_is_word) {
        // also a wordbreak
        return OpMatch{ .i = i, .j = patt[1..] };
    } else {
        return null;
    }
    // Dispatch should have all identical signatures for the compiler's sake,
    // but we don't use sets here:
    _ = sets;
}

fn matchNotWordBreak(patt: []const RegOp, sets: []const CharSet, haystack: []const u8, i: usize) ?OpMatch {
    const wb = matchWordBreak(patt, sets, haystack, i);
    if (wb) |_| {
        return null;
    } else {
        return OpMatch{ .i = i, .j = patt[1..] };
    }
}

fn matchAlt(patt: []const RegOp, sets: []const CharSet, haystack: []const u8, i: usize) ?OpMatch {
    const maybe_first = maybeAlt(patt);
    if (maybe_first) |first_patt| {
        const one_m = matchPattern(first_patt, sets, haystack, i);
        if (one_m) |m1| {
            // alt groups return what they don't eat
            return OpMatch{ .i = m1.i, .j = patt[first_patt.len + 1 ..] };
        } else {
            // try the next one
            return matchAlt(patt[first_patt.len + 1 ..], sets, haystack, i);
        }
    } else {
        // Ordinary pattern (last match)
        return matchPattern(patt, sets, haystack, i);
    }
}

fn matchClass(set: CharSet, c: u8) bool {
    switch (c) {
        0...0x3f => {
            const cut_c: u6 = @truncate(c);
            return (set.low | (one << cut_c)) == set.low;
        },
        0x40...0x7f => {
            const cut_c: u6 = @truncate(c);
            return (set.hi | (one << cut_c)) == set.hi;
        },
        else => return false,
    }
}

fn matchHighClass(set: CharSet, c: u8) bool {
    switch (c) {
        0x80...0xbf => {
            const cut_c: u6 = @truncate(c);
            return (set.low | (one << cut_c)) == set.low;
        },
        0xc0...0xff => {
            const cut_c: u6 = @truncate(c);
            return (set.hi | (one << cut_c)) == set.hi;
        },
        else => return false,
    }
}

fn nextPatternForSome(patt: []const RegOp) usize {
    switch (patt[0]) {
        .left => return findRight(patt, 0) + 1,
        .star,
        .optional,
        .plus,
        .lazy_star,
        .lazy_optional,
        .lazy_plus,
        .eager_star,
        .eager_plus,
        .eager_optional,
        .up_to,
        => return 1 + nextPatternForSome(patt[1..]),
        .some => {
            if (patt[1] == .star or patt[1] == .up_to) {
                return 2 + nextPatternForSome(patt[2..]);
            } else {
                return 1 + nextPatternForSome(patt[1..]);
            }
        },
        .unused => unreachable,
        else => return 1,
    }
}

fn nextPattern(patt: []const RegOp) []const RegOp {
    switch (patt[0]) {
        .unused, .begin => @panic("Internal error, .unused or .begin encountered"),
        .right => @panic("Internal error, encountered .right"),
        .left => return patternAfterGroup(patt),
        .alt,
        .optional,
        .star,
        .plus,
        .lazy_optional,
        .lazy_star,
        .lazy_plus,
        .eager_optional,
        .eager_star,
        .eager_plus,
        .some,
        .up_to,
        .eager_up_to,
        => return nextPattern(patt[1..]),
        .word_break,
        .not_word_break,
        .end,
        .dot,
        .char,
        .class,
        .not_class,
        .high_class,
        .not_high_class,
        .digit,
        .not_digit,
        .alpha,
        .not_alpha,
        .whitespace,
        .not_whitespace,
        => return patt[1..],
    }
}

fn patternAfterGroup(patt: []const RegOp) []const RegOp {
    assert(patt[0] == .left);
    var j: usize = 1;
    var pump: usize = 0;
    while (true) : (j += 1) {
        switch (patt[j]) {
            .right => {
                if (pump == 0) {
                    return patt[j + 1 ..];
                } else {
                    pump -= 1;
                }
            },
            .left => pump += 1,
            else => {},
        }
    }
    unreachable;
}

// Returns just our pattern.
fn thisPattern(patt: []const RegOp) []const RegOp {
    switch (patt[0]) {
        .left => return thisGroup(patt),
        // This function is not called from modifier position by construction,
        // Except for .optional followed by .some, .sometimes, which needs
        // this:
        .some => return patt[0..nextPatternForSome(patt)],
        else => return patt[0..1],
    }
}

/// Returns a whole group, including the ends.
fn thisGroup(patt: []const RegOp) []const RegOp {
    assert(patt[0] == .left);
    var j: usize = 1;
    var pump: usize = 0;
    while (true) : (j += 1) {
        switch (patt[j]) {
            .right => {
                if (pump == 0) {
                    return patt[0 .. j + 1];
                } else {
                    pump -= 1;
                }
            },
            .left => pump += 1,
            else => {},
        }
    }
    unreachable;
}

fn patternAcceptsEmpty(patt: []const RegOp) bool {
    switch (patt[0]) {
        .optional,
        .star,
        .lazy_optional,
        .lazy_star,
        .eager_optional,
        .eager_star,
        .up_to,
        .end,
        => return true,
        .left => {
            if (groupAcceptsEmpty(patt)) {
                return true;
            } else {
                return false;
            }
        },
        else => return false,
    }
}

/// Does the group accept empty matches?
fn groupAcceptsEmpty(patt: []const RegOp) bool {
    if (!hasAlt(patt)) {
        const inner = sliceGroup(patt);
        if (inner.len == 0) {
            return true;
        } else return patternAcceptsEmpty(inner);
    }
    var inner_patt = sliceGroup(patt);
    while (true) {
        const maybe_this_patt = maybeAlt(inner_patt);
        if (maybe_this_patt) |this_patt| {
            if (this_patt.len == 0) return true; // Empty alt matches empty string.
            if (patternAcceptsEmpty(this_patt)) {
                return true;
            } else {
                inner_patt = inner_patt[this_patt.len + 1 ..];
                if (inner_patt.len == 0) return true; // Final empty pattern;
            }
        } else { // final patt
            return (patternAcceptsEmpty(inner_patt));
        }
    }
    unreachable;
}

fn findPatternEnd(regex: *const Regex) usize {
    const patt = regex.patt;
    for (0..patt.len) |i| {
        if (patt[i] == .unused) {
            return i;
        }
    }
    return patt.len;
}

/// Return the first alt, if there is one.
fn maybeAlt(patt: []const RegOp) ?[]const RegOp {
    const alt_at = findAlt(patt, 0);
    if (alt_at) |at| {
        return patt[0..at];
    } else return null;
}

/// Test if a group (must be a group!) has an alt.
fn hasAlt(patt: []const RegOp) bool {
    assert(patt[0] == .left); // We'll use this for a speedup later
    var pump: usize = 0;
    var j: usize = 1;
    while (j < patt.len - 1) : (j += 1) {
        switch (patt[j]) {
            .left => pump += 1,
            .right => {
                if (pump == 0)
                    return true
                else
                    pump -= 1;
            },
            .alt => {
                if (pump == 0) return true;
            },
            else => {},
        }
    }
    return false;
}

/// Returns the *interior* of a group.
fn sliceGroup(patt: []const RegOp) []const RegOp {
    assert(patt[0] == .left);

    var j: usize = 1;
    var pump: usize = 0;
    while (true) : (j += 1) {
        switch (patt[j]) {
            .right => {
                if (pump == 0) {
                    return patt[1..j];
                } else {
                    pump -= 1;
                }
            },
            .left => pump += 1,
            else => {},
        }
    }
    unreachable;
}

// Count alts which aren't in a group

/// Answer if there's an alt in the (outermost) pattern.
fn findAlt(patt: []const RegOp, j_in: usize) ?usize {
    var j = j_in;
    var pump: usize = 0;
    while (j < patt.len) : (j += 1) {
        switch (patt[j]) {
            .left => pump += 1,
            .right => pump -= 1,
            .alt => {
                if (pump == 0) return j;
            },
            else => {},
        }
    }
    return null;
}

fn findRight(patt: []const RegOp, j_in: usize) usize {
    // Compiler made sure these are matched
    var j = j_in;
    var pump: usize = 0;
    while (j < patt.len) : (j += 1) {
        if (patt[j] == .right and pump == 0)
            return j
        else
            continue;
        if (patt[j] == .left) pump += 1;
    }
    unreachable;
}

//| COMPILER

/// (Attempts to) compile a Regex with a decidedly large default of 4K
/// operations and 256 character sets, returning `.{ops, sets}`, representing
/// the minimum necessary `SizedRegex(ops, sets)` for this pattern.  The
/// string provided must be comptime-known.  Since the values returned are
/// themselves only usable at comptime, it is suggested this function only
/// be used to tune the size of a regex during development, rather than
/// called pointlessly every time the program is compiled.
///
/// Note that if you run out of character sets in this function, you're out of
/// luck, that limit is a hard one.  Regexen with more than 4k operations are
/// possible, if you ever find a useful one.
pub fn resourcesNeeded(comptime in: []const u8) struct { comptime_int, comptime_int } {
    // 257 to give room for the logError at the hard limit of 256
    const maybe_out = compileRegex(SizedRegex(4096, 257), in);
    var max_s: usize = 0;
    if (maybe_out) |out| {
        for (&out.patt, 0..) |op, i| {
            switch (op) {
                .class, .not_class => |s_off| {
                    max_s = @max(max_s, s_off);
                },
                .unused => {
                    return .{ i, max_s + 1 };
                },
                else => {},
            }
        }
    } else {
        return .{ 0, 0 };
    }
    return .{ 0, 0 };
}

/// Move modifiers to prefix position.
fn prefixModifier(patt: []RegOp, j: usize, op: RegOp) !usize {
    if (j == 0 or patt[j] == .begin) return BadString;
    var find_j = j - 1;
    // travel back before last group
    switch (patt[find_j]) {
        .right => {
            find_j = beforePriorLeft(patt, find_j);
        },
        else => {},
    }
    // Try to detect multi-byte characters
    switch (patt[find_j]) {
        .char => |c| {
            if (0x80 <= c and c <= 0xbf) {
                // Go back to lead byte:
                while (find_j > 0 and
                    patt[find_j] == .char and
                    0x80 <= patt[find_j].char and
                    patt[find_j].char <= 0xbf) : (find_j -= 1)
                {}
                std.mem.copyBackwards(RegOp, patt[find_j + 2 ..], patt[find_j .. j + 1]);
                patt[find_j] = op;
                patt[find_j + 1] = .left;
                patt[j + 2] = .right;
                return 2;
            }
        },
        else => {},
    }
    // If we already have a modifier, two are not kosher:
    if (find_j > 0) {
        switch (patt[find_j - 1]) {
            .plus,
            .lazy_optional,
            .lazy_star,
            .lazy_plus,
            .eager_optional,
            .eager_star,
            .eager_plus,
            .optional,
            => {
                logError("found a modifier on a modifier", .{});
                return BadString;
            }, // Allowed for {M,} and {M,N} purposes
            .some => {
                if (op != .optional) {
                    logError("found a modifier on a modifier", .{});
                    return BadString;
                } else {
                    find_j -= 1;
                }
            },
            .star => {
                if (op != .some) {
                    logError("found a modifier on a modifier", .{});
                    return BadString;
                }
            },
            .up_to => {
                if (op == .optional) {
                    find_j -= 1;
                    if (find_j > 0 and patt[find_j - 1] == .some) {
                        find_j -= 1;
                    }
                } else if (op != .some) {
                    logError("found a modifier on a modifier", .{});
                    return BadString;
                }
            },
            else => {},
        } // find_j is at our insert offset
    }
    var move_op = patt[find_j];
    if (op == .some and find_j > 0) {
        const prev_op = patt[find_j - 1];
        switch (prev_op) {
            .up_to, .eager_up_to, .star, .optional => {
                find_j -= 1;
                move_op = prev_op;
            },
            else => {},
        }
    }
    patt[find_j] = op;
    find_j += 1;
    while (move_op != .unused) : (find_j += 1) {
        const temp_op = patt[find_j];
        patt[find_j] = move_op;
        move_op = temp_op;
    }
    return 0;
}

fn beforePriorLeft(patt: []RegOp, j: usize) usize {
    std.debug.assert(patt[j] == .right);
    var find_j = j - 1;
    var pump: usize = 0;
    while (find_j != 0) : (find_j -= 1) {
        switch (patt[find_j]) {
            .right => {
                pump += 1;
            },
            .left => {
                if (pump == 0)
                    break
                else
                    pump -= 1;
            },
            else => {},
        }
    }
    if (patt[find_j] != .left) @panic("throw here");
    return find_j;
}

inline fn countDigits(in: []const u8) usize {
    var i: usize = 0;
    while (i < in.len and ascii.isDigit(in[i])) : (i += 1) {}
    return i;
}

fn parseByte(in: []const u8) !struct { usize, u8 } {
    const d1 = countDigits(in);
    if (d1 == 0 or d1 >= 4) return error.BadString;
    const c1 = std.fmt.parseInt(u16, in[0..d1], 10) catch {
        return error.BadString;
    };
    if (c1 > 255) {
        logError("repetition counts must fit in a u8, got {d}\n", .{c1});
        return error.BadString;
    }
    return .{ d1, @intCast(c1) };
}

fn parseHex(in: []const u8) !u8 {
    var out_buf: [1]u8 = undefined;
    const b = try std.fmt.hexToBytes(&out_buf, in[0..2]);
    return b[0];
}

fn findSetIndex(sets: []const CharSet, set: CharSet, s: usize) u8 {
    // We deal with excessive offsets elsewhere
    const trunc_s: u8 = @truncate(s);
    var idx: u8 = 0;
    while (idx < trunc_s) : (idx += 1) {
        if (sets[idx].low == set.low and sets[idx].hi == set.hi) {
            return idx;
        }
    }
    return trunc_s;
}

pub fn compile(in: []const u8) ?Regex {
    return compileRegex(Regex, in);
}

/// Compile a regex.
fn compileRegex(RegexT: type, in: []const u8) ?RegexT {
    var out = RegexT{};
    var patt = &out.patt;
    const sets = &out.sets;
    // TODO make this an inner function which throws errors,
    // and takes patt and sets as slices.  That should minimize
    // the amount of compiler specialization needed; a perfect
    // compiler would know that this function can share almost all
    // of the code per SizedRegex, but I don't want to rely on that.
    var bad_string: bool = false;
    var i: usize = 0;
    var j: usize = 0;
    var s: usize = 0;
    var pump: usize = 0;
    dispatch: while (i < in.len and j < patt.len) : ({
        j += 1;
        i += 1;
    }) {
        const c = in[i];
        switch (c) {
            '^' => {
                if (i != 0) {
                    bad_string = true;
                    break :dispatch;
                }
                patt[j] = RegOp{ .begin = {} };
            },
            '$' => {
                if (i + 1 < in.len) {
                    bad_string = true;
                    break :dispatch;
                }
                patt[j] = RegOp{ .end = {} };
            },
            '.' => {
                patt[j] = RegOp{ .dot = {} };
            },
            '*' => {
                if (i + 1 < in.len and in[i + 1] == '?') {
                    i += 1;
                    j += prefixModifier(patt, j, RegOp{ .lazy_star = {} }) catch {
                        bad_string = true;
                        break :dispatch;
                    };
                } else if (i + 1 < in.len and in[i + 1] == '+') {
                    i += 1;
                    j += prefixModifier(patt, j, RegOp{ .eager_star = {} }) catch {
                        bad_string = true;
                        break :dispatch;
                    };
                } else {
                    j += prefixModifier(patt, j, RegOp{ .star = {} }) catch {
                        bad_string = true;
                        break :dispatch;
                    };
                }
            },
            '?' => {
                if (i + 1 < in.len and in[i + 1] == '?') {
                    i += 1;
                    j += prefixModifier(patt, j, RegOp{ .lazy_optional = {} }) catch {
                        bad_string = true;
                        break :dispatch;
                    };
                } else if (i + 1 < in.len and in[i + 1] == '+') {
                    i += 1;
                    j += prefixModifier(patt, j, RegOp{ .eager_optional = {} }) catch {
                        bad_string = true;
                        break :dispatch;
                    };
                } else {
                    j += prefixModifier(patt, j, RegOp{ .optional = {} }) catch {
                        bad_string = true;
                        break :dispatch;
                    };
                }
            },
            '+' => {
                if (i + 1 < in.len and in[i + 1] == '?') {
                    i += 1;
                    j += prefixModifier(patt, j, RegOp{ .lazy_plus = {} }) catch {
                        bad_string = true;
                        break :dispatch;
                    };
                } else if (i + 1 < in.len and in[i + 1] == '+') {
                    //
                    i += 1;
                    j += prefixModifier(patt, j, RegOp{ .eager_plus = {} }) catch {
                        bad_string = true;
                        break :dispatch;
                    };
                } else {
                    j += prefixModifier(patt, j, RegOp{ .plus = {} }) catch {
                        bad_string = true;
                        break :dispatch;
                    };
                }
            },
            '{' => { // {M,N} etc, or just character literal is fine
                i += 1;
                if (in[i] == ',') { // {,?
                    i += 1;
                    const d, const c1 = parseByte(in[i..]) catch {
                        bad_string = true;
                        break :dispatch;
                    };
                    i += d;
                    if (in[i] == '}') { // {,N}
                        j += prefixModifier(patt, j, RegOp{ .up_to = c1 }) catch
                            {
                                bad_string = true;
                                break :dispatch;
                            };
                        continue :dispatch;
                    } else {
                        bad_string = true;
                        break :dispatch;
                    }
                }
                const d1, const c1 = parseByte(in[i..]) catch {
                    // This is fine, literal `}`
                    // TODO: is it?
                    patt[j] = RegOp{ .char = '}' };
                    continue :dispatch;
                };
                i += d1;
                if (in[i] == ',') { // {M,?
                    i += 1;
                    if (in[i] == '}') { // {M,}
                        j += prefixModifier(patt, j, RegOp{ .star = {} }) catch {
                            bad_string = true;
                            break :dispatch;
                        };
                        j += 1;
                        j += prefixModifier(patt, j, RegOp{ .some = c1 }) catch {
                            bad_string = true;
                            break :dispatch;
                        };
                        continue :dispatch;
                    } // {M,N}
                    const d2, const c2 = parseByte(in[i..]) catch {
                        bad_string = true;
                        break :dispatch;
                    };
                    i += d2;
                    if (in[i] != '}') {
                        bad_string = true;
                        break :dispatch;
                    }
                    if (c1 > c2) {
                        logError("{d} > {d}\n", .{ c1, c2 });
                        bad_string = true;
                        break :dispatch;
                    }
                    const c_rest = c2 - c1;
                    if (i + 1 < in.len and in[i + 1] == '+') {
                        j += prefixModifier(patt, j, RegOp{ .eager_up_to = c_rest }) catch {
                            bad_string = true;
                            break :dispatch;
                        };
                        i += 1;
                    } else {
                        j += prefixModifier(patt, j, RegOp{ .up_to = c_rest }) catch {
                            bad_string = true;
                            break :dispatch;
                        };
                    }
                    j += 1;
                    j += prefixModifier(patt, j, RegOp{ .some = c1 }) catch {
                        bad_string = true;
                        break :dispatch;
                    };
                } else if (in[i] == '}') {
                    // {M}
                    j += prefixModifier(patt, j, RegOp{ .some = c1 }) catch {
                        bad_string = true;
                        break :dispatch;
                    };
                }
            },
            '|' => {
                patt[j] = RegOp{ .alt = {} };
            },
            '(' => {
                pump += 1;
                patt[j] = RegOp{ .left = {} };
            },
            ')' => {
                if (pump == 0) {
                    bad_string = true;
                    break :dispatch;
                }
                pump -= 1;
                patt[j] = RegOp{ .right = {} };
            },
            '\\' => { // character class or escape
                if (i + 1 == in.len) {
                    bad_string = true;
                    break :dispatch;
                } else {
                    i += 1;
                    // char patterns
                    switch (in[i]) {
                        'd' => {
                            patt[j] = RegOp{ .digit = {} };
                        },
                        'D' => {
                            patt[j] = RegOp{ .not_digit = {} };
                        },
                        'w' => {
                            patt[j] = RegOp{ .alpha = {} };
                        },
                        'W' => {
                            patt[j] = RegOp{ .not_alpha = {} };
                        },
                        's' => {
                            patt[j] = RegOp{ .whitespace = {} };
                        },
                        'S' => {
                            patt[j] = RegOp{ .not_whitespace = {} };
                        },
                        'b', 'B' => |ch| {
                            if (j > 0 and (patt[j - 1] == .word_break or patt[j - 1] == .not_word_break)) {
                                logError("Consecutive word breaks are not legal or sensible\n", .{});
                                bad_string = true;
                                break :dispatch;
                            }
                            if (ch == 'b') {
                                patt[j] = RegOp{ .word_break = {} };
                            } else {
                                patt[j] = RegOp{ .not_word_break = {} };
                            }
                        },
                        // character escapes
                        'r', 'n', 't' => {
                            patt[j] = RegOp{ .char = valueFor(in[i..]).? };
                        },
                        // byte literal
                        'x' => {
                            i += 1;
                            const b = parseHex(in[i..]) catch {
                                bad_string = true;
                                break :dispatch;
                            };
                            i += 1;
                            patt[j] = RegOp{ .char = b };
                        },
                        else => |ch| {
                            // Others are accepted as escaped, we don't care
                            // if they're special, you're not special, I'm not
                            // your Dad, you get the regex you give
                            patt[j] = RegOp{ .char = ch };
                        },
                    }
                }
            },
            '[' => {
                // character set
                i, j, s = parseCharSet(in, patt, sets, j, i, s) catch {
                    bad_string = true;
                    break :dispatch;
                };
            },
            else => |ch| { // regular ol' character
                patt[j] = RegOp{ .char = ch };
            },
        }
    } // end :dispatch
    if (j == patt.len and i < in.len) {
        logError("Ran out of regex operations (use bigger SizedRegex(ops++, sets)\n", .{});
        return null;
    }
    if (pump != 0) {
        logError("missing closing parenthesis\n", .{});
        return null;
    }
    if (bad_string) {
        const tail = switch (i) {
            0 => "st",
            1 => "nd",
            2 => "rd",
            else => "th",
        };
        logError("bad string at {d}{s} character\n", .{ i + 1, tail });
        return null;
    }
    return out;
}

const BadString = error.BadString;

// Special set masks
const d_MASK: u64 = 0x03ff000000000000; // low
const w_HI_MASK: u64 = 0x07fffffe87fffffe;
const w_LOW_MASK = d_MASK;
const s_MASK: u64 = 0x0000000100003e00; // low
const ALL_MASK: u64 = ~@as(u64, 0);

/// Returns a value for an escaped character. Does not handle character
/// classes.
fn valueFor(in: []const u8) ?u8 {
    switch (in[0]) {
        't' => return '\t',
        'n' => return '\n',
        'r' => return '\r',
        'w', 'W', 's', 'S', 'd', 'D' => return null,
        'x' => {
            if (in.len >= 3) {
                return parseHex(in[1..4]) catch return null;
            } else {
                // ??? probably malformed but not... yet?
                return 'x';
            }
        }, // No unprintables or high bytes here:
        0x00...0x08,
        0x0b,
        0x0c,
        0x0e...0x1f,
        0x7f,
        0x80...0xff,
        => return null,
        else => return in[0],
    }
}

fn parseCharSet(in: []const u8, patt: []RegOp, sets: []CharSet, j: usize, i_in: usize, s: usize) !struct { usize, usize, usize } {
    var i = i_in;
    var low: u64 = 0;
    var hi: u64 = 0;
    var follow: u64 = 0;
    var lead: u64 = 0;
    const this_kind: RegexType = which: {
        if (i + 1 < in.len and in[i + 1] == '^') {
            i += 1;
            break :which .not_class;
        } else break :which .class;
    };
    i += 1;
    while (i < in.len and in[i] != ']') : (i += 1) {
        // An escape might be a range:
        var c1_x = false; // Was c1 an \x escape?
        const c1 = which: {
            if (in[i] == '\\') {
                const may_b = valueFor(in[i + 1 ..]);
                if (may_b) |b| {
                    if (in[i + 1] == 'x') {
                        c1_x = true;
                        i += 3; // \ + x + 2 digits
                    } else {
                        i += 1; // \? for all other ?
                    }
                    break :which b;
                } else {
                    // handle normal stuff later
                    break :which in[1];
                }
            } else {
                break :which in[i];
            }
        };
        if (i + 1 < in.len and in[i + 1] != '-') {
            // normal character class
            switch (c1) {
                0...0x3f => {
                    const cut_c: u6 = @truncate(c1);
                    low |= one << cut_c;
                },
                0x40...0x5b, 0x5d...0x7f => {
                    const cut_c: u6 = @truncate(c1);
                    hi |= one << cut_c;
                }, // aka 0x5c:
                '\\' => { // escaped value, we don't care what
                    // thought I had established that already but ok
                    if (i + 1 < in.len) {
                        i += 1;
                        const c2 = in[i];
                        switch (c2) {
                            0...63 => {
                                const cut_c: u6 = @truncate(c2);
                                low |= one << cut_c;
                            },
                            'w' => {
                                low |= w_LOW_MASK;
                                hi |= w_HI_MASK;
                            },
                            'W' => {
                                low |= ~w_LOW_MASK;
                                hi |= ~w_HI_MASK;
                            },
                            's' => {
                                low |= s_MASK;
                            },
                            'S' => {
                                low |= ~s_MASK;
                                hi |= ~ALL_MASK;
                            },
                            'd' => {
                                low |= d_MASK;
                            },
                            'D' => {
                                low |= ~d_MASK;
                                hi |= ALL_MASK;
                            }, // TODO these might be unreachable now, kcov it
                            'n' => {
                                low |= one << '\n';
                            },
                            't' => {
                                low |= one << '\t';
                            },
                            'r' => {
                                low |= one << '\r';
                            },
                            'x' => {
                                i += 1;
                                const b = parseHex(in[i..]) catch return BadString;
                                if (b > 127) {
                                    logError("charsets can't fit {d}\n", .{b});
                                    return BadString;
                                }
                                i += 1;
                                const b_trunc: u6 = @truncate(b);
                                switch (b) {
                                    0...63 => low |= one << b_trunc,
                                    64...127 => hi |= one << b_trunc,
                                    else => unreachable,
                                }
                            },
                            128...255 => {
                                return BadString;
                            },
                            else => {
                                const cut_c: u6 = @truncate(c2);
                                hi |= one << cut_c;
                            },
                        }
                    }
                },
                0x80...0xff => {
                    if (!c1_x) {
                        logError("Apologies!!, but multi-byte characters in sets are not supported: 0x{x}.\n", .{c1});
                        return BadString;
                    } else {
                        switch (c1) {
                            0x00...0x7f => unreachable,
                            0x80...0xbf => {
                                const cut_c: u6 = @truncate(c1);
                                follow |= one << cut_c;
                            },
                            0xc0...0xff => {
                                const cut_c: u6 = @truncate(c1);
                                lead |= one << cut_c;
                            },
                        }
                    }
                },
            }
        } else {
            // if paired, it's a range
            if (i + 2 < in.len and in[i + 2] != ']') {
                var c2_x = false;
                const c2 = which: {
                    if (in[i + 2] != '\\') {
                        i += 1; // we get one from the while loop
                        break :which in[i + 1];
                    } else if (i + 3 < in.len) {
                        // try for somthing valid
                        const may_b = valueFor(in[i + 3 ..]);
                        if (may_b) |b| {
                            if (in[i + 3] == 'x') {
                                c2_x = true;
                                i += 5; // - + \ + x + 2 digits
                            } else {
                                i += 2; // \? for all other ?
                            }
                            break :which b;
                        } else { // I've decided this is a `\`
                            i += 1; // let the dang chips fall
                            break :which in[i + 1];
                        }
                    } else {
                        // I guess it's a `\`, and we're almost out of room?
                        break :which '\\';
                        // For now. This will break later
                    }
                };
                if (c1 > 0x80 and !c1_x or c2 > 0x80 and !c2_x) {
                    logError("Invalid multibytes found in range: 0x{x}, 0x{x}\n", .{ c1, c2 });
                    return BadString;
                }
                if (c1 <= c2) {
                    for (c1..c2 + 1) |c_range| {
                        switch (c_range) {
                            0...0x3f => {
                                const cut_c: u6 = @truncate(c_range);
                                low |= one << cut_c;
                            },
                            0x40...0x7f => {
                                const cut_c: u6 = @truncate(c_range);
                                hi |= one << cut_c;
                            },
                            0x80...0xbf => {
                                const cut_c: u6 = @truncate(c_range);
                                follow |= one << cut_c;
                            },
                            0xc0...0xff => {
                                const cut_c: u6 = @truncate(c_range);
                                lead |= one << cut_c;
                            },
                            else => unreachable,
                        }
                    }
                } else {
                    logError("Invalid range: '{u}' > '{u}'\n", .{ c1, c2 });
                    return BadString;
                }
            } else { // '-' in set, add c1
                const c_trunc: u6 = @truncate(c1);
                switch (c1) {
                    0...0x3f => low |= one << c_trunc,
                    0x40...0x7f => hi |= one << c_trunc,
                    0x80...0xff => {
                        if (!c1_x) {
                            logError("Apologies, but multi-byte characters in sets are not supported.\n", .{});
                            return BadString;
                        } else {
                            switch (c1) {
                                0x00...0x7f => unreachable,
                                0x80...0xbf => {
                                    const cut_c: u6 = @truncate(c1);
                                    follow |= one << cut_c;
                                },
                                0xc0...0xff => {
                                    const cut_c: u6 = @truncate(c1);
                                    lead |= one << cut_c;
                                },
                            }
                        }
                    },
                }
            }
        }
    } // end while
    if (i == in.len or in[i] != ']') {
        return BadString;
    }
    if (s > 255) {
        logError("Passed the hard 256 limit on charsets. Cannot compile.\n", .{});
        return BadString;
    }
    const low_fill = low != 0 or hi != 0;
    const high_fill = follow != 0 or lead != 0;
    if (!high_fill) {
        const new_s = try appendSet(
            patt,
            sets,
            CharSet{ .low = low, .hi = hi },
            this_kind,
            j,
            s,
        );
        return .{ i, j, new_s };
    } else if (high_fill and !low_fill) {
        const high_kind: RegexType = if (this_kind == .class) .high_class else .not_high_class;
        const new_s = try appendSet(
            patt,
            sets,
            CharSet{ .low = follow, .hi = lead },
            high_kind,
            j,
            s,
        );
        return .{ i, j, new_s };
    } else {
        assert(high_fill and low_fill);
        if (j + 4 > patt.len) {
            logError("Out of instructions for regex", .{});
            return BadString;
        }
        const high_kind: RegexType = if (this_kind == .class) .high_class else .not_high_class;
        var new_j = j;
        patt[new_j] = .left;
        new_j += 1;
        var new_s = try appendSet(
            patt,
            sets,
            CharSet{ .low = low, .hi = hi },
            this_kind,
            new_j,
            s,
        );
        if (new_s > 255) {
            logError("Passed the hard 256 limit on charsets. Cannot compile.\n", .{});
            return BadString;
        }
        new_j += 1;
        patt[new_j] = .alt;
        new_j += 1;
        new_s = try appendSet(
            patt,
            sets,
            CharSet{ .low = follow, .hi = lead },
            high_kind,
            new_j,
            new_s,
        );
        new_j += 1;
        patt[new_j] = .right;
        return .{ i, new_j, new_s };
    }
}

fn appendSet(patt: []RegOp, sets: []CharSet, set: CharSet, this_kind: RegexType, j: usize, s_in: usize) !usize {
    var s = s_in;
    const this_s = findSetIndex(sets, set, s);
    if (this_s >= sets.len) {
        logError("Ran out of character sets (use bigger SizedRegex(ops, sets++)\n", .{});
        return BadString;
    }
    sets[this_s] = set;
    if (this_s == s) {
        s += 1;
    }
    if (this_kind == .class) {
        patt[j] = RegOp{ .class = this_s };
    } else if (this_kind == .not_class) {
        patt[j] = RegOp{ .not_class = this_s };
    } else if (this_kind == .high_class) {
        patt[j] = RegOp{ .high_class = this_s };
    } else if (this_kind == .not_high_class) {
        patt[j] = RegOp{ .not_high_class = this_s };
    } else unreachable;
    return s;
}

const logger = std.log.scoped(.mvzr);

fn logError(comptime fmt: []const u8, args: anytype) void {
    if (!builtin.is_test) {
        logger.err(fmt, args);
    } else {
        logger.warn(fmt, args);
    }
}

//| TESTS

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

fn testMatchAll(needle: []const u8, haystack: []const u8) !void {
    const maybe_regex = compile(needle);
    if (maybe_regex) |regex| {
        const maybe_match = regex.match(haystack);
        if (maybe_match) |m| {
            try expectEqual(0, m.start);
            try expectEqual(haystack.len, m.end);
        } else {
            try expect(false);
        }
    } else {
        try expect(false);
    }
}

fn testMatchEnd(needle: []const u8, haystack: []const u8) !void {
    const maybe_regex = compile(needle);
    if (maybe_regex) |regex| {
        const maybe_match = regex.match(haystack);
        if (maybe_match) |m| {
            try expectEqual(haystack.len, m.end);
        } else {
            try expect(false);
        }
    } else {
        try expect(false);
    }
}

fn testMatchSlice(needle: []const u8, haystack: []const u8, slice: []const u8) !void {
    const maybe_regex = compile(needle);
    if (maybe_regex) |regex| {
        const maybe_match = regex.match(haystack);
        if (maybe_match) |m| {
            try expectEqualStrings(slice, m.slice);
        } else {
            try expect(false);
        }
    } else {
        try expect(false);
    }
}

fn testFail(needle: []const u8, haystack: []const u8) !void {
    const maybe_regex = compile(needle);
    if (maybe_regex) |regex| {
        try expectEqual(null, regex.match(haystack));
    } else {
        try expect(false);
    }
}

fn downStackRegex(RegexT: type, regex: RegexT, allocator: std.mem.Allocator) !*const RegexT {
    const heap_regex = try regex.toOwnedRegex(allocator);
    return heap_regex;
}

fn downStackMatch(matched: Match, allocator: std.mem.Allocator) !Match {
    const heap_match = try matched.toOwnedMatch(allocator);
    return heap_match;
}

fn testOwnedRegex(needle: []const u8, haystack: []const u8) !void {
    const allocator = std.testing.allocator;
    const maybe_regex = compile(needle);
    if (maybe_regex) |regex| {
        const heap_regex = try downStackRegex(Regex, regex, allocator);
        defer allocator.destroy(heap_regex);
        const maybe_match = heap_regex.match(haystack);
        if (maybe_match) |m| {
            const matched = try downStackMatch(m, allocator);
            defer matched.deinit(allocator);
            try expectEqualStrings(haystack, matched.slice);
        } else try expect(false);
    } else {
        try expect(false);
    }
}

test "match some things" {
    try testMatchAll("abc", "abc");
    try testMatchAll("[a-z]", "d");
    try testMatchAll("\\W\\w", "!a");
    try testMatchAll("\\w+", "abdcdFG");
    try testMatchAll("a*b+", "aaaaabbbbbbbb");
    try testMatchAll("a?b*", "abbbbb");
    try testMatchAll("a?b*", "bbbbbb");
    try testMatchAll("a*", "aaaaa");
    try testFail("a+", "b");
    try testMatchAll("a?", "a");
    try testMatchAll("^\\w*?abc", "qqqqabc");
    // Fail if pattern isn't complete
    try testFail("^\\w*?abcd", "qqqqabc");
    try testMatchAll("^a*?abc", "abc");
    try testMatchAll("^1??abc", "abc");
    try testMatchAll("^1??abc", "1abc");
    try testMatchAll("^1??1abc", "1abc");
    try testMatchAll("[^abc]+", "defgh");
    try testMatchAll("^1??1abc$", "1abc");
    try testFail("^1??1abc$", "1abccc");
    try testMatchAll("foo|bar|baz", "foo");
    try testMatchAll("foo|bar|baz", "bar");
    try testMatchAll("foo|bar|baz", "baz");
    try testMatchAll("foo|bar|baz|quux+", "quuxxxxx");
    try testMatchAll("foo|bar|baz|bux|quux|quuux|quuuux", "quuuux");
    try testMatchAll("foo|bar|(baz|bux|quux|quuux)|quuuux", "quuuux");
    try testMatchAll("(abc)+d", "abcabcabcd");
    try testMatchAll("\t\n\r\xff\xff", "\t\n\r\xff\xff");
    try testMatchAll("[\t\r\n]+", "\t\t\r\r\n\t\n\r");
    try testMatchAll("[fd\\x03\\x04]+", "f\x03d\x04dfd\x03");
    try testMatchAll("a+b", "ab");
    try testMatchAll("a*aaa", "aaaaaaaaaaaaaa");
    try testMatchAll("\\w+foo", "abcdefoo");
    try testFail("\\w+foo", "foo");
    try testMatchAll("\\w*foo", "foo");
    try testFail("a++a", "aaaaaaaa");
    try testFail("a*+a", "aaaaaaaa");
    try testMatchAll("(aaa)?aaa", "aaa");
    try testFail("(aaa)?+aaa", "aaa");
    try testMatchAll("ab?", "ab");
    try testMatchAll("ab?", "a");
    try testMatchAll("^a{3,6}a", "aaaaaa");
    try testMatchAll("^a{3,4}", "aaaa");
    try testMatchAll("^a{3,5}", "aaaaa");
    try testMatchAll("^a{3,5}", "aaa");
    try testMatchAll("\\w{3,5}bc", "abbbc");
    try testMatchAll("\\w{3,5}", "abb");
    try testMatchAll("!{,3}", "!!!");
    try testMatchAll("abc(def(ghi)jkl)mno", "abcdefghijklmno");
    try testMatchAll("abc(def(ghi?)jkl)mno", "abcdefghijklmno");
    try testMatchAll("abc(def(ghi)?jkl)mno", "abcdefjklmno");
    try testMatchAll("abc(def(ghi?)jkl)mno", "abcdefghjklmno");
    try testFail("abc(def(ghi?)jkl)mno", "abcdefjklmno");
    try testMatchAll("abc(def((ghi)?)jkl)mno", "abcdefjklmno");
    try testMatchAll("(abc){5}?", "abcabcabcabcabc");
    try testMatchAll("(abc){3,5}?", "abcabcabcabcabc");
    try testMatchAll("^\\w+?$", "glebarg");
    try testMatchAll("[A-Za-z]+$", "Pabcex");
    try testMatchAll("^[^\n]+$", "a single line");
    try testFail("^[^\n]+$", "several \n lines");
    // Empty stuff
    try testFail("[]+", "abc");
    try testFail("[]", "a");
    try testMatchAll("abc()d", "abcd");
    try testMatchAll("abc(|||)d", "abcd");
    // No infinite loops
    try testMatchAll("(a*?)*aa", "aaa");
    try testMatchAll("(){0,1}q$", "q");
    try testMatchAll("(){1,2}q$", "q");
    try testMatchAll("(abc){3,5}?$", "abcabcabcabcabc");
    try testMatchAll("()+q$", "q");
    try testMatchAll("^(q*)*$", "qqqq");
    try testMatchEnd("[bc]*(cd)+", "cbcdcd");
    // MD5 hash?
    try testMatchAll("^[a-f0-9]{32}", "0800fc577294c34e0b28ad2839435945");
    try testMatchAll("ab+c|de+f", "abbbc");
    try testMatchAll("ab+c|de+f", "deeeef");
    try testFail("^ab+c|de+f", "abdef");
    try testMatchAll("employ(er|ee|ment|ing|able)", "employee");
    try testMatchAll("employ(er|ee|ment|ing|able)", "employer");
    try testMatchAll("employ(er|ee|ment|ing|able)", "employment");
    try testMatchAll("employ(er|ee|ment|ing|able)", "employable");
    try testMatchAll("employ(er|ee|ment|ing|able)", "employing");
    try testMatchAll("employ(|er|ee|ment|ing|able)", "employ");
    try testMatchAll("employ(|er|ee|ment|ing|able)$", "employee");
    // Character escaping
    try testMatchAll("\\$\\.\\(\\)\\*\\+\\?\\[\\\\]\\^\\{\\|\\}", "$.()*+?[\\]^{|}");
    try testMatchAll("[\\x41-\\x5a]+", "ABCDEFGHIJKLMNOPQRSTUVWXYZ");
    // Again, without the doubled backslashes;
    const test_escapes =
        \\\$\.\(\)\*\+\?\[\\]\^\{\|\}
    ;
    try testMatchAll(test_escapes, "$.()*+?[\\]^{|}");
    // Character classes in character sets
    try testMatchAll("[^\\Wf]+", "YyIcMy9Z");
    try testFail("[^\\Wf]+$", "YyIcMy9Zf");
    try testMatchAll("[\\x48-\\x4c$]+", "HIJ$KL");
    try testMatchAll("[^^]+", "abXdea!@#$!%$#$%$&$");
    try testFail("^[^^]+", "^abXdea!@#$!%$#$%$&$");
    // Newlines at end
    try testMatchAll("To the Bitter End$", "To the Bitter End\n");
    try testMatchAll(
        "William Gates Jr. Sucks.$",
        "William Gates Jr. Sucks.\r\n",
    );
    // Backtrack star correctly
    try testMatchAll("(fob)*boba$", "fobboba");
    try testFail("^(fob)*boba$", "fobfobfoboba");
    try testMatchSlice("(fob)*boba", "fobfobfoboba", "boba");
    // Word boundary
    try testMatchAll("\\bsnap\\b", "snap");
    try testMatchAll("\\bsnap\\b!", "snap!");
    try testMatchAll("\\b4\\b", "4");
    try testMatchSlice("\\bword\\b", "an isolated word ", "word");
    try testFail("\\bword\\b", "password");
    try testFail("\\bword\\b", "wordpress");
    try testMatchAll("out\\Brage\\Bous", "outrageous");
    try testMatchSlice("\\Brage\\B", "outrageous", "rage");
    try testFail("\\Brage\\B", "rage within the machine");
    try testMatchAll("a{3,5}+a", "aaaaaa");
    try testFail("(a[bc]){3,5}+ac", "abacabacac");
    try testMatchAll("(a[bc]){3,5}ac", "abacabacac");

    // https://github.com/mnemnion/mvzr/issues/1#issuecomment-2235265209
    try testMatchAll("[0-9]{4}", "1951");
    try testMatchAll("(0[1-9]|1[012])[\\/](0[1-9]|[12][0-9]|3[01])[\\/][0-9]{4}", "10/12/1951");
    try testMatchAll("[\\x09]", "\t");
    // https://github.com/mnemnion/mvzr/issues/1#issuecomment-2238087036
    try testMatchAll("^[a-zA-Z0-9_!#$%&.-]+@([a-zA-Z0-9.-])+$", "myname.myfirst_name@gmail.com");
}

test "heap allocated regex and match" {
    try testOwnedRegex("abcde", "abcde");
    try testOwnedRegex("^[a-f0-9]{32}", "0800fc577294c34e0b28ad2839435945");
}

test "Get the char sets you asked for" { // https://github.com/mnemnion/mvzr/issues/1#issuecomment-2235265209
    const test_patt = "(0[1-9]|1[012])[\\/](0[1-9]|[12][0-9]|3[01])[\\/][0-9]{4}";
    const j, const s = resourcesNeeded(test_patt);
    try expectEqual(6, s); // Deduplicated from 9
    const ProperSize = SizedRegex(j, s);
    const haystack = "10/12/1951";
    const bigger_regex = ProperSize.compile(test_patt);
    if (bigger_regex) |reggie| {
        const match1 = reggie.match(haystack);
        if (match1) |m1| {
            try expectEqual(haystack.len, m1.end);
        } else {
            try expect(false);
        }
    } else {
        try expect(false);
    }
}

test "iteration" {
    const foo_str = "foobarbazfoo";
    var r_iter = compile("foo|bar|baz").?.iterator(foo_str);
    var matched = r_iter.next().?;
    try expectEqualStrings("foo", matched.slice);
    try expectEqualStrings("foo", foo_str[matched.start..matched.end]);
    matched = r_iter.next().?;
    try expectEqualStrings("bar", matched.slice);
    try expectEqualStrings("bar", foo_str[matched.start..matched.end]);
    matched = r_iter.next().?;
    try expectEqualStrings("baz", matched.slice);
    try expectEqualStrings("baz", foo_str[matched.start..matched.end]);
    matched = r_iter.next().?;
    try expectEqualStrings("foo", matched.slice);
    try expectEqualStrings("foo", foo_str[matched.start..matched.end]);
    try expectEqual(null, r_iter.next());
}

test "matchPos" {
    const regex = Regex.compile("abcd").?;
    const matched = regex.matchPos(4, "abcdabcd").?;
    try expectEqual(4, matched.start);
    try expectEqualStrings("abcd", matched.slice);
    try expectEqual(8, matched.end);
}

test "comptime regex" {
    const comp_regex = comptime compile("foo+").?;
    const run_match = comp_regex.match("foofoofoo");
    try expect(run_match != null);
    const comptime_match = comptime comp_regex.match("foofoofoo");
    try expect(comptime_match != null);
}

test "comptime isMatch" {
    const comp_regex = comptime compile("foo+").?;
    const comp_is_match = comptime comp_regex.isMatch("foofoofoo");
    try expect(comp_is_match);

    const comp_regex2 = comptime compile("^[^#]*#?$").?;
    try expect(comptime comp_regex2.isMatch("https://example.com"));
}

test "date regex" {
    const match_date = Regex.compile("[0-9]{4}-[0-9]{2}-[0-9]{2}T([0-9]{2}:){2}[0-9]{2}([+|-][0-9]{2}:[0-9]{2})?").?;
    try expect(match_date.isMatch("2024-01-01T00:00:00"));
}

test "alt | on repetition qualifiers" {
    const regex = Regex.compile("0x[a-fA-F0-9]{2,}|[a-fA-F0-9]{2,}").?;
    try expect(regex.isMatch("derived dedicated cede 0xdeadDEAD"));
}

test "repetition and word break" {
    const regex = Regex.compile("[de]{2,}\\b").?;
    try expect(!regex.isMatch("defense"));
}

test "match end" {
    const regex = Regex.compile("a*$").?;
    try std.testing.expect(regex.isMatch("bb"));
}

test "c0 regex" {
    const regex = Regex.compile(
        \\[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]
    ).?;
    try std.testing.expect(regex.isMatch("\x1b"));
    try std.testing.expect(!regex.isMatch("B"));
    try std.testing.expect(!regex.isMatch("0"));
}

test "c1 regex" {
    const regex = Regex.compile(
        \\\xc2[\x80-\x9f]
    ).?;
    try std.testing.expect(regex.isMatch("\u{80}"));
}

test "low-high combined" {
    const regex = Regex.compile("[\\x1b\\xff]+cd").?;
    try std.testing.expect(regex.isMatch("\x1b\xffcd"));
}

test "Multibyte continues" {
    const regex = Regex.compile("Ṥǎ+").?;
    try std.testing.expect(regex.isMatch("Ṥǎǎǎǎǎ"));
}

test "Uppercase Greek" {
    try testMatchAll("(\\xce[\\x91-\\xa9])+", "ΑΒΓΔΕΖΗΘΙΚΛΜΝΞΟΠΡΣΤΥΦΧΨΩ");
}

test "M of N multibyte" {
    try testMatchEnd("abλ{3,5}", "abλλλλ");
}

test "zero length match on zero length haystack" {
    const regex = Regex.compile(".*");
    const the_match = regex.?.match("");
    try expect(the_match != null);
    try expectEqual(0, the_match.?.start);
    try expectEqual(0, the_match.?.end);
}

test "zero length optional match on zero length haystack" {
    const regex = Regex.compile(".?");
    const the_match = regex.?.match("");
    try expect(the_match != null);
    try expectEqual(0, the_match.?.start);
    try expectEqual(0, the_match.?.end);
}

test "zero length bookended optional match on zero length haystack" {
    const regex = Regex.compile("^.?$");
    const the_match = regex.?.match("");
    try expect(the_match != null);
    try expectEqual(0, the_match.?.start);
    try expectEqual(0, the_match.?.end);
}

test "mandatory a fails on zero length haystack" {
    const regex = Regex.compile("a").?;
    try expectEqual(null, regex.match(""));
}

test "some == 0 is an optional for termination" {
    try testMatchAll("^[A-Za-z][0-9A-Za-z]{0,19}$", "x");
}

test "mvzr compile in releasesafe mode" {
    const hi = compile("test");
    try std.testing.expect(hi != null);
    try std.testing.expect(hi.?.isMatch("test"));
}

test "mvzr is not longest-leftmost" {
    const fubar = compile("(foo|foobar)").?;
    const the_match = fubar.match("foobar");
    if (the_match) |is_foo| {
        try expectEqualStrings("foo", is_foo.slice);
    }
}

test "do not make this test any longer" {
    // Proof of exponential growth due to ?
    try testMatchAll("a?a?a?a?a?a?a?aaaaaaa", "aaaaaaa");
}

test "rewrites coin address at the end" {
    const bogus_coin = compile("7[a-zA-Z0-9]{25,34}+").?;
    const bogo_string = "Send the boguscoins to 7YWHMfk9JZe123123123123123\n";
    try expect(bogus_coin.isMatch(bogo_string));
    const a_match = bogus_coin.match(bogo_string).?;
    _ = a_match;
}

test "word boundary with zero length haystack" {
    // Courtesy apvanzanten: https://github.com/mnemnion/mvzr/pull/8
    try testFail("\\b", "");
}

test "zero-match group after greedy star (issue #11)" {
    const r = compile("^a*(b)*$").?;

    try expect(r.isMatch("aab")); // OK — group matches once
    try expect(r.isMatch("b")); // OK — a* matches 0, group matches once
    try expect(r.isMatch("")); // OK — both match 0 times
    // NB: comments below represent errors corrected, not current behavior
    try expect(r.isMatch("a")); // FAIL — returns false, expected true
    try expect(r.isMatch("aaa")); // FAIL — returns false, expected true
    try expect(compile("^a*(b)*$").?.isMatch("aaa")); // false
    try expect(compile("^[a-z]*([_][a-z]+)*$").?.isMatch("abc")); // false
    try expect(compile("^[a-z][a-z0-9]*([_-][a-z0-9]+)*$").?.isMatch("free")); // false
    try expect(compile("^[a-z][a-z0-9]+([_-][a-z0-9]+)*$").?.isMatch("free")); // false
}

test "nested empty star terminates (issue #15)" {
    const r = compile("(a*)*").?;

    try expect(r.isMatch("ax"));

    var r_iter = r.iterator("ax");
    try expect(r_iter.next() != null);
}

test "iterator with empty regex" {
    const foo_str = "foo";
    var r_iter = compile("").?.iterator(foo_str);
    var matched = r_iter.next().?;
    try expectEqual(0, matched.start);
    try expectEqual(0, matched.end);
    matched = r_iter.next().?;
    try expectEqual(1, matched.start);
    try expectEqual(1, matched.end);
    matched = r_iter.next().?;
    try expectEqual(2, matched.start);
    try expectEqual(2, matched.end);
    matched = r_iter.next().?;
    try expectEqual(3, matched.start);
    try expectEqual(3, matched.end);
    try expectEqual(null, r_iter.next());
}

test "iterator with empty alternation terminates" {
    const foo_str = "foo";
    var r_iter = compile("bar|").?.iterator(foo_str);
    while (r_iter.next()) |_| {}
    try expectEqual(null, r_iter.next());
}
