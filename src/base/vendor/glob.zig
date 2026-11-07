// Copyright (c) 2025 xcaeser, MIT License
// https://github.com/xcaeser/glob.zig/tree/master

//! Allocation-free glob matching for byte strings.
//!
//! The default API supports `*`, `?`, character classes, ranges, escaping,
//! and a leading `!` for whole-pattern negation. Use `Options` for pathname,
//! leading-period, no-escape, or ASCII case-insensitive matching.
//!
//! Public API:
//! - `match` for ordinary matching
//! - `matchWithOptions` for configurable, error-reporting matching
//! - `validate` to check a default-syntax pattern without matching
//! - `matchAny` and `matchAll` for default-syntax pattern lists

const std = @import("std");
const expect = std.testing.expect;
const expectError = std.testing.expectError;

/// Errors returned for malformed patterns.
pub const ValidationError = error{
    UnclosedBracket,
    EmptyBracket,
    InvalidRange,
    TrailingBackslash,
};

/// Byte comparison mode used by `Options`.
pub const CaseSensitivity = enum {
    sensitive,
    insensitive_ascii,
};

/// Matching behavior. Defaults preserve the original string-matching API.
pub const Options = struct {
    case_sensitivity: CaseSensitivity = .sensitive,
    /// Wildcards and character classes cannot match `/`.
    pathname: bool = false,
    /// A leading `.` must be matched by a literal `.` in the pattern.
    period: bool = false,
    /// Treat `\` as an ordinary byte instead of an escape character.
    no_escape: bool = false,
};

/// Validates default pattern syntax without matching text.
pub fn validate(pattern: []const u8) ValidationError!void {
    return validateWithOptions(pattern, .{});
}

fn validateWithOptions(pattern: []const u8, options: Options) ValidationError!void {
    var i: usize = 0;
    while (i < pattern.len) {
        switch (pattern[i]) {
            '\\' => {
                if (options.no_escape) {
                    i += 1;
                    continue;
                }
                if (i + 1 >= pattern.len) return error.TrailingBackslash;
                i += 2;
            },
            '[' => {
                i = (try parseCharacterClass(pattern, i, null, options)).next;
            },
            else => i += 1,
        }
    }
}

/// Matches a text string against a glob-style pattern.
///
/// Supported wildcards:
///
/// - `*` — matches any number of any characters, including none.
///   Example: `Law*` matches `Law`, `Laws`, and `Lawyer`,
///   but not `GrokLaw`, `La`, or `aw`.
///
/// - `?` — matches any single character.
///   Example: `?at` matches `Cat`, `Bat`, `cat`, and `bat`,
///   but not `at`.
///
/// - `[abc]` — matches one character from the set inside the brackets.
///   Example: `[CB]at` matches `Cat` and `Bat`,
///   but not `cat`, `bat`, or `CBat`.
///
/// - `[a-z]` — matches one character from the given range.
///   Example: `Letter[0-9]` matches `Letter0` through `Letter9`,
///   but not `Letters`, `Letter`, or `Letter10`.
///
/// - `[!abc]` or `[^abc]` — matches one character outside the set.
///
/// - `\` — escapes the next pattern byte.
///
/// - `!` prefix — negates the whole pattern (must be first character).
///   Example: `!*.tmp` matches anything except files ending in `.tmp`.
///
/// Invalid patterns do not match. Use `matchWithOptions` to receive the error.
/// Matching is byte-oriented: `?` consumes one byte, not one Unicode scalar.
///
/// Returns `true` if the given text matches the pattern, otherwise `false`.
pub fn match(pattern: []const u8, text: []const u8) bool {
    return matchWithOptions(pattern, text, .{}) catch false;
}

/// Matches using `options` and returns `ValidationError` for malformed syntax.
/// Use this instead of `match` when patterns come from user input and the
/// caller must distinguish an invalid pattern from a valid non-match.
pub fn matchWithOptions(pattern: []const u8, text: []const u8, options: Options) ValidationError!bool {
    try validateWithOptions(pattern, options);

    const negated = pattern.len > 0 and pattern[0] == '!';
    const matched = matchImpl(if (negated) pattern[1..] else pattern, text, options);
    return if (negated) !matched else matched;
}

const Star = struct {
    pattern: usize,
    text: usize,
};

fn matchImpl(pattern: []const u8, text: []const u8, options: Options) bool {
    var pattern_index: usize = 0;
    var text_index: usize = 0;
    var star: ?Star = null;

    while (true) {
        if (pattern_index < pattern.len and pattern[pattern_index] == '*') {
            while (pattern_index < pattern.len and pattern[pattern_index] == '*') pattern_index += 1;
            star = .{ .pattern = pattern_index, .text = text_index };
            continue;
        }

        if (pattern_index == pattern.len and text_index == text.len) return true;

        if (text_index < text.len) {
            const protected_period = isProtectedPeriod(text, text_index, options);
            if (!protected_period or isLiteralPeriod(pattern, pattern_index, options)) {
                if (matchToken(pattern, pattern_index, text[text_index], options)) |next| {
                    pattern_index = next;
                    text_index += 1;
                    continue;
                }
            }
        }

        if (star) |*retry| {
            if (retry.text < text.len and canStarConsume(text, retry.text, options)) {
                retry.text += 1;
                pattern_index = retry.pattern;
                text_index = retry.text;
                continue;
            }
        }

        return false;
    }
}

fn matchToken(pattern: []const u8, index: usize, target: u8, options: Options) ?usize {
    if (index >= pattern.len) return null;

    switch (pattern[index]) {
        '\\' => if (!options.no_escape) {
            return if (bytesEqual(pattern[index + 1], target, options)) index + 2 else null;
        },
        '?' => {
            if (options.pathname and target == '/') return null;
            return index + 1;
        },
        '[' => {
            if (options.pathname and target == '/') return null;
            const class = parseCharacterClass(pattern, index, target, options) catch unreachable;
            return if (class.matched) class.next else null;
        },
        else => {},
    }

    return if (bytesEqual(pattern[index], target, options)) index + 1 else null;
}

fn canStarConsume(text: []const u8, index: usize, options: Options) bool {
    return !(options.pathname and text[index] == '/') and !isProtectedPeriod(text, index, options);
}

fn isProtectedPeriod(text: []const u8, index: usize, options: Options) bool {
    return options.period and text[index] == '.' and
        (index == 0 or (options.pathname and text[index - 1] == '/'));
}

fn isLiteralPeriod(pattern: []const u8, index: usize, options: Options) bool {
    if (index >= pattern.len) return false;
    if (pattern[index] == '.') return true;
    return !options.no_escape and pattern[index] == '\\' and
        index + 1 < pattern.len and pattern[index + 1] == '.';
}

const CharacterClass = struct {
    next: usize,
    matched: bool,
};

fn parseCharacterClass(
    pattern: []const u8,
    start: usize,
    target: ?u8,
    options: Options,
) ValidationError!CharacterClass {
    var index = start + 1;
    var negated = false;
    if (index < pattern.len and (pattern[index] == '!' or pattern[index] == '^')) {
        negated = true;
        index += 1;
    }

    if (index >= pattern.len) return error.UnclosedBracket;
    if (pattern[index] == ']') return error.EmptyBracket;

    var matched = false;
    var invalid_range = false;
    while (index < pattern.len and pattern[index] != ']') {
        const range_start = try takeClassByte(pattern, &index, options);

        if (index + 1 < pattern.len and pattern[index] == '-' and pattern[index + 1] != ']') {
            index += 1;
            const range_end = try takeClassByte(pattern, &index, options);
            invalid_range = invalid_range or range_start > range_end;
            if (target) |byte| matched = matched or byteInRange(byte, range_start, range_end, options);
        } else if (target) |byte| {
            matched = matched or bytesEqual(range_start, byte, options);
        }
    }

    if (index >= pattern.len) return error.UnclosedBracket;
    if (invalid_range) return error.InvalidRange;
    return .{ .next = index + 1, .matched = if (negated) !matched else matched };
}

fn takeClassByte(pattern: []const u8, index: *usize, options: Options) ValidationError!u8 {
    if (!options.no_escape and pattern[index.*] == '\\') {
        index.* += 1;
        if (index.* >= pattern.len) return error.UnclosedBracket;
    }

    const byte = pattern[index.*];
    index.* += 1;
    return byte;
}

fn bytesEqual(a: u8, b: u8, options: Options) bool {
    return switch (options.case_sensitivity) {
        .sensitive => a == b,
        .insensitive_ascii => std.ascii.toLower(a) == std.ascii.toLower(b),
    };
}

fn byteInRange(target: u8, start: u8, end: u8, options: Options) bool {
    if (target >= start and target <= end) return true;
    if (options.case_sensitivity == .sensitive) return false;

    const alternate = if (std.ascii.isLower(target)) std.ascii.toUpper(target) else std.ascii.toLower(target);
    return alternate >= start and alternate <= end;
}

/// Returns `true` when `text` matches at least one pattern using default
/// options. Empty lists and malformed patterns do not match.
///
/// Example:
/// ```zig
/// const patterns = &[_][]const u8{ "*.zig", "*.c", "*.h" };
/// matchAny(patterns, "main.zig") // true
/// matchAny(patterns, "main.py")  // false
/// ```
pub fn matchAny(patterns: []const []const u8, text: []const u8) bool {
    for (patterns) |pattern| {
        if (match(pattern, text)) return true;
    }
    return false;
}

/// Returns `true` when `text` matches every pattern using default options.
/// An empty list returns `true`; a malformed pattern returns `false`.
///
/// Example:
/// ```zig
/// const patterns = &[_][]const u8{ "test_*", "*.zig" };
/// matchAll(patterns, "test_foo.zig") // returns true
/// matchAll(patterns, "test_foo.py")  // returns false
/// matchAll(patterns, "foo.zig")      // returns false
/// ```
pub fn matchAll(patterns: []const []const u8, text: []const u8) bool {
    for (patterns) |pattern| {
        if (!match(pattern, text)) return false;
    }
    return true;
}

// ============================================================================
// Tests
// ============================================================================

test "validate - valid patterns" {
    try validate("");
    try validate("*.zig");
    try validate("test_??.c");
    try validate("[a-z]*");
    try validate("\\*literal\\?");
    try validate("![abc]");
}

test "validate - unclosed bracket" {
    try expectError(error.UnclosedBracket, validate("[abc"));
    try expectError(error.UnclosedBracket, validate("test["));
    try expectError(error.UnclosedBracket, validate("test[a-z"));
}

test "validate - empty bracket" {
    try expectError(error.EmptyBracket, validate("[]"));
    try expectError(error.EmptyBracket, validate("test[]"));
}

test "validate - trailing backslash" {
    try expectError(error.TrailingBackslash, validate("\\"));
    try expectError(error.TrailingBackslash, validate("test\\"));
}

test "validate - character class syntax" {
    try validate("[!a-z]");
    try validate("[a\\]]");
    try validate("[a-]");
    try expectError(error.InvalidRange, validate("[z-a]"));
    try expectError(error.EmptyBracket, validate("[!]"));
    try expectError(error.UnclosedBracket, validate("[z-a\\]"));
}

test "negation - basic" {
    try expect(match("!*.tmp", "file.txt"));
    try expect(!match("!*.tmp", "file.tmp"));
    try expect(match("!test*", "production"));
    try expect(!match("!test*", "test_file"));
}

test "negation - with wildcards" {
    try expect(!match("!a*c", "abc"));
    try expect(match("!a*c", "abd"));
    try expect(!match("!?at", "cat"));
    try expect(match("!?at", "cats"));
}

test "negation - with character classes" {
    try expect(!match("![0-9]", "5"));
    try expect(match("![0-9]", "a"));
    try expect(!match("!Letter[0-9]", "Letter5"));
    try expect(match("!Letter[0-9]", "Letter"));
}

test "matchAny - basic" {
    const patterns = &[_][]const u8{ "*.zig", "*.c", "*.h" };

    try expect(matchAny(patterns, "main.zig"));
    try expect(matchAny(patterns, "test.c"));
    try expect(matchAny(patterns, "header.h"));
    try expect(!matchAny(patterns, "script.py"));
    try expect(!matchAny(patterns, "README.md"));
}

test "matchAny - with negation" {
    const patterns = &[_][]const u8{ "*.txt", "!test_*" };

    try expect(matchAny(patterns, "file.txt"));
    try expect(matchAny(patterns, "production.log"));
    try expect(matchAny(patterns, "test_file.txt")); // matches *.txt
}

test "matchAny - empty patterns" {
    const patterns = &[_][]const u8{};
    try expect(!matchAny(patterns, "anything"));
}

test "matchAll - basic" {
    const patterns = &[_][]const u8{ "test_*", "*.zig" };

    try expect(matchAll(patterns, "test_main.zig"));
    try expect(!matchAll(patterns, "test_main.c"));
    try expect(!matchAll(patterns, "main.zig"));
    try expect(!matchAll(patterns, "production.rs"));
}

test "matchAll - single pattern" {
    const patterns = &[_][]const u8{"*.txt"};

    try expect(matchAll(patterns, "file.txt"));
    try expect(!matchAll(patterns, "file.md"));
}

test "matchAll - empty patterns" {
    const patterns = &[_][]const u8{};
    try expect(matchAll(patterns, "anything")); // vacuous truth
}

test "matchAll - with wildcards" {
    const patterns = &[_][]const u8{ "src/*", "*.zig", "*main*" };

    try expect(matchAll(patterns, "src/main.zig"));
    try expect(!matchAll(patterns, "src/test.zig"));
    try expect(!matchAll(patterns, "lib/main.zig"));
}

test "matchAll - with negation" {
    const patterns = &[_][]const u8{ "*.txt", "!test_*" };

    try expect(matchAll(patterns, "file.txt"));
    try expect(!matchAll(patterns, "test_file.txt"));
    try expect(!matchAll(patterns, "test_file.md"));
}

test "empty strings" {
    try expect(match("", ""));
    try expect(!match("", "a"));
    try expect(!match("a", ""));
}

test "single character matches" {
    try expect(match("a", "a"));
    try expect(!match("a", "b"));
    try expect(match("abc", "abc"));
    try expect(!match("abc", "abd"));
}

test "question mark wildcard" {
    try expect(match("?", "a"));
    try expect(match("a?", "ab"));
    try expect(match("?b", "ab"));
    try expect(match("a?c", "abc"));
    try expect(!match("?", ""));
    try expect(!match("", "?"));
    try expect(!match("??", "a"));
    try expect(match("??", "ab"));
}

test "asterisk wildcard" {
    try expect(match("*", ""));
    try expect(match("*", "abc"));
    try expect(match("a*", "a"));
    try expect(match("a*", "abc"));
    try expect(match("*c", "abc"));
    try expect(match("a*c", "abc"));
    try expect(match("a*c", "ac"));
    try expect(match("a*c", "abbc"));
    try expect(!match("a*c", "abd"));
    try expect(match("*a*", "aaa"));
    try expect(match("a**b", "ab"));
    try expect(match("*a*b", "xaaab"));
    try expect(match("*", "anystring"));
    try expect(match("*.zig", "main.zig"));
    try expect(match("src/*.zig", "src/main.zig"));
    try expect(!match("src/*.zig", "main.zig"));
}

test "character class" {
    try expect(match("[abc]", "a"));
    try expect(match("[abc]", "b"));
    try expect(match("[abc]", "c"));
    try expect(!match("[abc]", "d"));
    try expect(match("a[bc]", "ab"));
    try expect(match("a[bc]", "ac"));
    try expect(!match("a[bc]", "ad"));
    try expect(match("[CB]at", "Cat"));
    try expect(match("[CB]at", "Bat"));
    try expect(!match("[CB]at", "cat"));
    try expect(!match("[CB]at", "bat"));
    try expect(!match("[CB]at", "CBat"));
}

test "negated and escaped character classes" {
    try expect(match("[!a-c]", "z"));
    try expect(!match("[!a-c]", "b"));
    try expect(match("[^0-9]", "x"));
    try expect(!match("[^0-9]", "5"));
    try expect(match("[-a]", "-"));
    try expect(match("[a-]", "-"));
    try expect(match("[a\\]]", "]"));
    try expect(match("[a\\-c]", "-"));
}

test "matchWithOptions reports malformed patterns" {
    try expectError(error.UnclosedBracket, matchWithOptions("[abc", "a", .{}));
    try expectError(error.EmptyBracket, matchWithOptions("[]", "a", .{}));
    try expectError(error.InvalidRange, matchWithOptions("[z-a]", "z", .{}));
    try expectError(error.TrailingBackslash, matchWithOptions("\\", "\\", .{}));
    try expect(!match("[z-a]", "z"));
}

test "matching options" {
    try expect(try matchWithOptions("*.ZIG", "main.zig", .{ .case_sensitivity = .insensitive_ascii }));
    try expect(try matchWithOptions("[A-Z]", "q", .{ .case_sensitivity = .insensitive_ascii }));

    try expect(match("src/*.zig", "src/lib/main.zig"));
    try expect(!(try matchWithOptions("src/*.zig", "src/lib/main.zig", .{ .pathname = true })));
    try expect(try matchWithOptions("src/?/main.zig", "src/x/main.zig", .{ .pathname = true }));
    try expect(!(try matchWithOptions("src/?/main.zig", "src/x/y/main.zig", .{ .pathname = true })));
    try expect(!(try matchWithOptions("[/]", "/", .{ .pathname = true })));

    try expect(match("*", ".env"));
    try expect(!(try matchWithOptions("*", ".env", .{ .period = true })));
    try expect(!(try matchWithOptions("[.]env", ".env", .{ .period = true })));
    try expect(try matchWithOptions(".*", ".env", .{ .period = true }));
    try expect(!(try matchWithOptions("src/*", "src/.env", .{ .pathname = true, .period = true })));
    try expect(try matchWithOptions("src/.*", "src/.env", .{ .pathname = true, .period = true }));

    try expect(try matchWithOptions("\\", "\\", .{ .no_escape = true }));
    try expect(try matchWithOptions("\\*", "\\anything", .{ .no_escape = true }));
}

test "complex patterns" {
    try expect(match("test_*.zig", "test_foo.zig"));
    try expect(match("*/*.zig", "src/main.zig"));
    try expect(match("?at", "Cat"));
    try expect(match("?at", "Bat"));
    try expect(!match("?at", "at"));
    try expect(match("Law*", "Law"));
    try expect(match("Law*", "Laws"));
    try expect(match("Law*", "Lawyer"));
    try expect(!match("Law*", "GrokLaw"));
    try expect(!match("Law*", "La"));
    try expect(!match("Law*", "aw"));
    try expect(match("Letter[0-9]", "Letter0"));
    try expect(match("Letter[0-9]", "Letter5"));
    try expect(match("Letter[0-9]", "Letter9"));
    try expect(!match("Letter[0-9]", "Letter"));
    try expect(!match("Letter[0-9]", "Letters"));
    try expect(!match("Letter[0-9]", "Letter10"));
}

test "edge cases and robustness" {
    // Pattern longer than text
    try expect(!match("abc", "ab"));
    // Text longer than pattern
    try expect(!match("ab", "abc"));
    // Multiple wildcards
    try expect(match("?*?", "abc"));
    try expect(match("*?*", "abc"));
    try expect(match("*?*?", "abcd"));
    // Invalid brackets
    try expect(!match("[", "a"));
    try expect(!match("[a", "a"));
    try expect(!match("[]", "a"));
    // Special characters as literals
    try expect(match("\\*", "*"));
    try expect(!match("\\*", "a"));
    // Case sensitivity
    try expect(!match("A", "a"));
    try expect(match("a", "a"));
    // A failed match with many stars stays bounded and does not recurse.
    const repetitions = 512;
    var hostile_pattern: [repetitions * 2 + 1]u8 = undefined;
    var hostile_text: [repetitions]u8 = undefined;
    for (0..repetitions) |i| {
        hostile_pattern[i * 2] = '*';
        hostile_pattern[i * 2 + 1] = 'a';
    }
    hostile_pattern[hostile_pattern.len - 1] = 'b';
    @memset(&hostile_text, 'a');
    try expect(!match(&hostile_pattern, &hostile_text));
}
