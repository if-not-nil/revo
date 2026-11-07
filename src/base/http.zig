const revo = @import("../root.zig");
const root = @import("root.zig");
const std = @import("std");

const Args = root.host.ArgTypes;
const Value = revo.Value;
const VM = revo.VM;
const HostResult = root.host.HostResult;

const Client = std.http.Client;
const Table = revo.table.Table;
const Header = std.http.Header;
const Method = std.http.Method;
const RedirectBehavior = std.http.Client.Request.RedirectBehavior;

pub const Impl = struct {
    pub fn fetch(vm: *VM, raw_method: Args.atom, url: Args.any, opts: Args.table_sentinel) !HostResult {
        // both this and the ambient sig intentionally omit CONNECT,
        //   bc that opens a tunnel and is not fetch-able
        const method = try buildMethod(raw_method, vm);

        const response_has_body = method.responseHasBody();

        const url_string = switch (try urlToString(url, vm)) {
            .err => |e| return HostResult{ .err = e },
            .value => |v| v,
        };
        const redirects: ?u16 = switch (try buildMaxRedirects(Value.new.table(@backingInt(opts.value)), vm)) {
            .err => |e| return HostResult{ .err = e },
            .value => |v| v,
        };
        const redirect_behavior =
            if (redirects) |r|
                if (r == 0) .unhandled else RedirectBehavior.init(r)
            else
                .unhandled;

        var client = Client{ .allocator = vm.runtime.alloc, .io = vm.runtime.io };
        defer client.deinit();

        // build fetch request options
        var request: std.http.Client.FetchOptions = .{ .location = .{ .url = url_string }, .method = method, .redirect_behavior = redirect_behavior, .keep_alive = false };

        // add body to the request, if provided
        const body = try buildBody(method, opts.value, vm);
        defer if (body) |b| {
            if (b.owned) vm.runtime.alloc.free(b.slice);
        };
        if (body) |b| {
            request.payload = b.slice;
        } else if (method.requestHasBody()) {
            request.payload = "";
        }
        var response_writer = std.Io.Writer.Allocating.init(vm.runtime.alloc);
        defer response_writer.deinit();
        if (response_has_body) {
            request.response_writer = &response_writer.writer;
        }

        // add provided headers to the request
        const max_headers = 50;
        var extra_headers = try std.ArrayList(std.http.Header).initCapacity(vm.runtime.alloc, max_headers);
        defer extra_headers.deinit(vm.runtime.alloc);
        const headers = switch (try buildHeaders(opts.value, &extra_headers, vm)) {
            .err => |e| return HostResult{ .err = e },
            .value => |v| v,
        };
        request.headers = headers;
        request.extra_headers = extra_headers.items;

        if (body != null) {
            // default content-type to json
            if (request.headers.content_type == .default) {
                request.headers.content_type = .{ .override = "application/json" };
            }
        }

        // fetch the request and build the result
        const response = try client.fetch(request);
        const result_atom = try vm.internAtom(switch (response.status.class()) {
            .informational => "informational",
            .success => "success",
            .redirect => "redirect",
            .client_error => "client_error",
            .server_error => "server_error",
        });

        const status = try vm.tableOfSlice(&[_]Value{
            Value.new.atom(result_atom),
            Value.new.num(@as(usize, @backingInt(response.status))),
        });

        const id = try vm.tables.create();
        try vm.putField(id, "status", status);
        if (response_has_body) {
            try vm.putField(id, "body", try vm.ownValueString(try response_writer.toOwnedSlice()));
        }

        return HostResult.Ok(vm, Value.new.table(id));
    }
};

pub const impls = root.host.impls(Impl).val;

fn buildMethod(raw_method: Args.atom, vm: *VM) !Method {
    const m = vm.stringValue(@backingInt(raw_method));

    var buf: [16]u8 = undefined;
    if (m.len > buf.len) return error.InvalidMethod;
    const upper = std.ascii.upperString(&buf, m);

    // TODO: add custom methods?
    return std.meta.stringToEnum(Method, upper) orelse error.InvalidMethod;
}

/// normalize url param into a string
fn urlToString(url: Value, vm: *VM) !HostErrOr([]const u8) {
    // TODO: Handle URL table
    return if (url.asStr()) |s|
        .{ .value = vm.stringValue(s) }
    else
        .{ .err = HostResult.errType(0, "string or table", revo.base.typeof(url, vm)).err };
}

fn buildMaxRedirects(options: Value, vm: *VM) !HostErrOr(?u16) {
    if (options.asTable()) |tid| {
        if (!vm.tables.isValid(tid)) return .{ .value = null };
    }
    if (vm.getField(options, "max_redirects")) |id| {
        if (id.asNumOpt()) |num| {
            const max_redirects: u16 = @trunc(num);
            return .{ .value = max_redirects };
        }
    }
    return .{ .value = null };
}

fn buildHeaders(options: Args.table, extra_headers: *std.ArrayList(std.http.Header), vm: *VM) !HostErrOr(std.http.Client.Request.Headers) {
    var headers = std.http.Client.Request.Headers{};

    const opts_id: usize = @backingInt(options);
    if (!vm.tables.isValid(opts_id)) return .{ .value = headers };

    if (vm.getField(Value.new.table(@backingInt(options)), "headers")) |id| {
        if (id.asTable()) |table_id| {
            if (!vm.tables.isValid(table_id)) return .{ .value = headers };
            var table: *Table = try vm.tables.get(table_id);
            // hash part only: array entries are not headers
            var it = table.hash.orderedIterator();
            while (it.next()) |header| {
                // only `:nil` values mean "omit this header"
                if (header.value.asAtom()) |a|
                    if (a == revo.CoreAtoms.nil.atomId()) continue;

                const key = try headerToString(header.key, vm);
                const val = try headerToString(header.value, vm);
                if (!setKnownHeader(&headers, key, val))
                    try extra_headers.append(vm.runtime.alloc, Header{ .name = key, .value = val });
            }
        }
    }

    return .{ .value = headers };
}

const known_headers = [_]struct { name: []const u8, field: []const u8 }{
    .{ .name = "Host", .field = "host" },
    .{ .name = "Authorization", .field = "authorization" },
    .{ .name = "User-Agent", .field = "user_agent" },
    .{ .name = "Connection", .field = "connection" },
    .{ .name = "Accept-Encoding", .field = "accept_encoding" },
    .{ .name = "Content-Type", .field = "content_type" },
};

fn setKnownHeader(headers: *std.http.Client.Request.Headers, key: []const u8, val: []const u8) bool {
    inline for (known_headers) |kh| {
        if (std.ascii.eqlIgnoreCase(key, kh.name)) {
            @field(headers, kh.field) = .{ .override = val };
            return true;
        }
    }
    return false;
}

fn buildBody(method: Method, opts: Args.table, vm: *VM) !?Body {
    if (!method.requestHasBody()) {
        return null;
    }
    const opts_id: usize = @backingInt(opts);
    if (!vm.tables.isValid(opts_id)) return null;

    if (vm.getField(Value.new.table(@backingInt(opts)), "body")) |id| {
        // explicit :nil is rejected (omit the key instead); anything else
        // non-string is json, the default content-type is json too (TODO detect it)
        if (id.asAtom()) |a| {
            if (a == revo.CoreAtoms.nil.atomId()) return error.TypeError;
        }
        if (id.asStr()) |s| {
            return .{ .slice = vm.stringValue(s) };
        }
        return .{ .slice = try @import("json.zig").encodeAlloc(id, vm), .owned = true };
    }

    return null;
}

/// borrowed from vm string unless json
const Body = struct {
    slice: []const u8,
    owned: bool = false,
};

fn HostErrOr(comptime T: type) type {
    return union(enum) {
        value: T,
        err: revo.base.host.HostErrPayload,
    };
}

fn headerToString(value: Value, vm: *VM) anyerror![]const u8 {
    return switch (value.tag()) {
        .atom => vm.stringValue(value.asAtom().?),
        .string => vm.stringValue(value.asStr().?),
        .number => try vm.runtime.alloc.print("{d}", .{value.asNumOpt().?}),
        else => error.InvalidHeaderType,
    };
}
