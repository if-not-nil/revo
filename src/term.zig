const revo = @import("revo");
const std = @import("std");

pub fn defaultSupportsColor() bool {
    return !revo.is_freestanding;
}

pub fn isColorSupported(env: *std.process.Environ.Map, io: std.Io) bool {
    if (env.contains("NO_COLOR")) return false;
    if (env.contains("CLICOLOR_FORCE") or env.contains("FORCE_COLOR")) return true;
    const is_tty = revo.stdout().isTty(io) catch return false;
    if (!is_tty) return false;
    if (env.get("TERM")) |term| if (std.mem.eql(u8, term, "dumb")) return false;
    return true;
}

pub fn style(writer: *std.Io.Writer, code: []const u8, color: bool) !void {
    if (color) {
        try writer.writeAll(code);
    }
}

pub fn printError(writer: *std.Io.Writer, color: bool, comptime fmt: []const u8, args: anytype) !void {
    try style(writer, "\x1b[1m\x1b[31m", color);
    try writer.writeAll("error: ");
    try style(writer, "\x1b[0m", color);
    try style(writer, "\x1b[1m", color);
    try writer.print(fmt ++ "\n", args);
    try style(writer, "\x1b[0m", color);
    try writer.flush();
}

pub fn printWarning(writer: *std.Io.Writer, color: bool, comptime fmt: []const u8, args: anytype) !void {
    try style(writer, "\x1b[1m\x1b[33m", color);
    try writer.writeAll("warning: ");
    try style(writer, "\x1b[0m", color);
    try style(writer, "\x1b[1m", color);
    try writer.print(fmt ++ "\n", args);
    try style(writer, "\x1b[0m", color);
    try writer.flush();
}

pub fn printNote(writer: *std.Io.Writer, color: bool, comptime fmt: []const u8, args: anytype) !void {
    try style(writer, "\x1b[1m\x1b[34m", color);
    try writer.writeAll("note: ");
    try style(writer, "\x1b[0m", color);
    try style(writer, "\x1b[1m", color);
    try writer.print(fmt ++ "\n", args);
    try style(writer, "\x1b[0m", color);
    try writer.flush();
}

pub fn printHelp(writer: *std.Io.Writer, color: bool, comptime fmt: []const u8, args: anytype) !void {
    try style(writer, "\x1b[1m\x1b[36m", color);
    try writer.writeAll("help: ");
    try style(writer, "\x1b[0m", color);
    try style(writer, "\x1b[1m", color);
    try writer.print(fmt ++ "\n", args);
    try style(writer, "\x1b[0m", color);
    try writer.flush();
}

pub fn printSuccess(writer: *std.Io.Writer, color: bool, comptime fmt: []const u8, args: anytype) !void {
    try style(writer, "\x1b[32m", color);
    try writer.print(fmt ++ "\n", args);
    try style(writer, "\x1b[0m", color);
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

pub fn fatal(comptime format: []const u8, args: anytype, vm: ?*revo.VM) noreturn {
    if (comptime !revo.is_freestanding) {
        std.debug.print("a very unexpected error occurred. please report to https://github.com/if-not-nil/revo", .{});
        if (vm) |v|
            std.debug.print("info:\npc {}", .{v.currentFiber().pc});
        std.debug.panic(format, args);
    } else {
        // no os level panic handler on freestanding so just trap directly
        @trap();
    }
}
