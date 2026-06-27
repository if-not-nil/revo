const std = @import("std");

pub var supports_color: bool = true;

pub fn isColorSupported(env: *std.process.Environ.Map, io: std.Io) bool {
    if (env.contains("NO_COLOR")) return false;
    if (env.contains("CLICOLOR_FORCE") or env.contains("FORCE_COLOR")) return true;
    const is_tty = std.Io.File.stdout().isTty(io) catch return false;
    if (!is_tty) return false;
    if (env.get("TERM")) |term| if (std.mem.eql(u8, term, "dumb")) return false;
    return true;
}

fn style(writer: *std.Io.Writer, code: []const u8) !void {
    if (supports_color) {
        try writer.writeAll(code);
    }
}

pub fn printError(writer: *std.Io.Writer, comptime fmt: []const u8, args: anytype) !void {
    try style(writer, "\x1b[1m\x1b[31m");
    try writer.writeAll("error: ");
    try style(writer, "\x1b[0m");
    try style(writer, "\x1b[1m");
    try writer.print(fmt ++ "\n", args);
    try style(writer, "\x1b[0m");
    try writer.flush();
}

pub fn printSuccess(writer: *std.Io.Writer, comptime fmt: []const u8, args: anytype) !void {
    try style(writer, "\x1b[32m");
    try writer.print(fmt ++ "\n", args);
    try style(writer, "\x1b[0m");
    try writer.flush();
}

pub fn replStyleDef(styleName: []const u8) [:0]const u8 {
    if (std.mem.eql(u8, styleName, "keyword")) return "color=magenta bold";
    if (std.mem.eql(u8, styleName, "number")) return "color=green";
    if (std.mem.eql(u8, styleName, "string")) return "color=yellow";
    if (std.mem.eql(u8, styleName, "operator")) return "color=blue";
    if (std.mem.eql(u8, styleName, "function")) return "color=cyan";
    if (std.mem.eql(u8, styleName, "atom")) return "color=yellow";
    if (std.mem.eql(u8, styleName, "hash")) return "color=green";
    return "color=default";
}
