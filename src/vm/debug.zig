const std = @import("std");

const revo = @import("revo");
const diagnostic = revo.lang.diagnostic;
pub const TraceFrame = diagnostic.TraceFrame;

pub const HostError = error{
    StackUnderflow,
    KeyDNE,
    StackOverflow,
    InvalidConstant,
    InvalidLocal,
    ConstantReassignment,
    WrongArity,
    TypeError,
    IncompatibleTypes,
    DivisionByZero,
    UndefinedVariable,
    NotAFunction,
    FrameUnderflow,
    PickedFromVoid,
    FunctionDNE,
    ProgramEnd,
    Panic,
    AssertionFailed,
    OutOfMemory,
    mystery,
    ModuleNotFound,
    IoError,
    CyclicImport,
    ImportFailed,
    InvalidChannel,
    Parked,
    InvalidBytecode,
};

pub const EvalErrorKind = enum {
    StackUnderflow,
    StackOverflow,
    InvalidConstant,
    InvalidLocal,
    TypeError,
    IncompatibleTypes,
    DivisionByZero,
    ShiftAmountOutOfRange,
    UndefinedVariable,
    NotAFunction,
    WrongArity,
    FrameUnderflow,
    PickedFromVoid,
    FunctionDNE,
    KeyDNE,
    Panic,
    OutOfMemory,
    ConstantReassignment,
    ProgramEnd,
    AssertionFailed,
    ModuleNotFound,
    IoError,
    CyclicImport,
    ImportFailed,
    InvalidChannel,
    Parked,
    InvalidBytecode,
    mystery,

    // it would be really cool if i could do this at comptime
    pub fn message(self: EvalErrorKind) []const u8 {
        return switch (self) {
            .StackUnderflow => "stack underflow!",
            .StackOverflow => "stack overflow!",
            .InvalidConstant => "invalid constant!",
            .InvalidLocal => "invalid local!",
            .TypeError => "type error!",
            .IncompatibleTypes => "incompatible types!",
            .DivisionByZero => "division by zero!",
            .ShiftAmountOutOfRange => "shift amount out of range!",
            .UndefinedVariable => "undefined variable!",
            .NotAFunction => "value is not a function!",
            .WrongArity => "wrong arity!",
            .FrameUnderflow => "frame underflow!",
            .PickedFromVoid => "picked from void!",
            .FunctionDNE => "function dne!",
            .Panic => "panic!!",
            .KeyDNE => "key does not exist!",
            .OutOfMemory => "out of memory!",
            .ConstantReassignment => "reassignment to constant!",
            .ProgramEnd => "program end!",
            .AssertionFailed => "assertion failed!",
            .ModuleNotFound => "module not found!",
            .IoError => "io error!",
            .CyclicImport => "cyclic import!",
            .ImportFailed => "import failed!",
            .InvalidChannel => "invalid channel!",
            .Parked => "fiber parked!",
            .InvalidBytecode => "invalid bytecode!",
            .mystery => "mystery!",
        };
    }
};

pub const EvalFailure = struct {
    pub const max_trace_frames = 64;

    kind: EvalErrorKind,
    report: diagnostic.Report,
    part_len: usize = 0,
    parts: [max_trace_frames + 2]diagnostic.Part = @splat(diagnostic.Part{ .@"error" = "" }),
    trace_len: usize = 0,
    trace: [max_trace_frames]TraceFrame = @splat(TraceFrame.empty()),

    pub fn render(self: EvalFailure, alloc: std.mem.Allocator, writer: *std.Io.Writer, source: []const u8) !void {
        return self.renderAt(
            alloc,
            writer,
            self.report.source_name orelse "<source>",
            self.report.source orelse source,
        );
    }

    pub fn renderAt(
        self: EvalFailure,
        alloc: std.mem.Allocator,
        writer: *std.Io.Writer,
        source_name: []const u8,
        source: []const u8,
    ) !void {
        var report = self.report;
        report.source_name = source_name;
        report.source = source;
        report.parts = self.parts[0..self.part_len];
        try diagnostic.renderReport(alloc, writer, report);
    }
};

pub const EvalResult = union(enum) {
    ok,
    err: EvalFailure,
};

pub fn printDisassembly(vm: *revo.VM, artifact: revo.lang.Artifact, source: []const u8) !void {
    const insts = artifact.instructions;
    const spans = artifact.spans;
    const n = insts.len;
    if (n == 0) return;

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const is_target = try aa.alloc(bool, n);
    @memset(is_target, false);
    var entries = std.AutoHashMap(usize, []const u8).init(aa); // fn entry pc -> name
    var jumpers = std.AutoHashMap(usize, usize).init(aa); // target pc -> first jumper

    for (insts, 0..) |inst, pc| {
        switch (inst.op) {
            .jump, .jump_if_false, .jump_if_true, .jump_err => {
                if (inst.bx < n) {
                    is_target[inst.bx] = true;
                    if (!jumpers.contains(inst.bx)) try jumpers.put(inst.bx, pc);
                }
            },
            .closure => {
                const proto_id = inst.bx;
                if (proto_id < vm.functions.prototypes.items.len) {
                    const proto = vm.functions.prototypes.items[proto_id];
                    if (proto.addr < n and proto.addr != 0) try entries.put(proto.addr, proto.name);
                }
            },
            else => {},
        }
    }

    var prev_span: [64]u8 = undefined;
    var prev_len: usize = 0;

    for (insts, 0..) |inst, pc| {
        if (pc == 0) std.debug.print("; module\n", .{});
        if (entries.get(pc)) |name| {
            if (pc != 0) std.debug.print("; fn {s}\n", .{name});
        }
        if (is_target[pc]) {
            std.debug.print("; L{d}", .{pc});
            if (jumpers.get(pc)) |from| std.debug.print(" (from pc {d})", .{from});
            std.debug.print("\n", .{});
        }

        const span = if (pc < spans.len)
            spans[pc]
        else
            revo.lang.Span{ .start = 0, .end = 0, .line = 0, .column = 0 };
        var span_buf: [64]u8 = undefined;
        const st = spanText(source, span, &span_buf);

        var op_buf: [96]u8 = undefined;
        const ops = operandText(vm, inst, &op_buf);

        var base_buf: [200]u8 = undefined;
        const base = fmt(&base_buf, "{d: >4}  {s: <17}  {s}", .{ pc, @tagName(inst.op), ops });

        if (st.len > 0 and !(st.len == prev_len and std.mem.eql(u8, st, prev_span[0..prev_len]))) {
            var full_buf: [320]u8 = undefined;
            const full = fmt(&full_buf, "{s: <44}  ; {s}", .{ base, st });
            std.debug.print("{s}\n", .{full});
            prev_len = @min(st.len, prev_span.len);
            @memcpy(prev_span[0..prev_len], st[0..prev_len]);
        } else {
            std.debug.print("{s}\n", .{base});
        }
    }
}

fn fmt(buf: []u8, comptime format: []const u8, args: anytype) []const u8 {
    return std.fmt.bufPrint(buf, format, args) catch buf[0..0];
}

/// render a constant pool value for load_const operands
fn dataText(vm: *revo.VM, val: revo.Data, buf: []u8) []const u8 {
    if (val.asNum()) |n| {
        if (n == @trunc(n)) {
            if (n < @as(f64, @floatFromInt(std.math.maxInt(i63))) and
                n > @as(f64, @floatFromInt(std.math.minInt(i63))))
            {
                const i: i64 = @intFromFloat(n);
                return fmt(buf, "{d}", .{i});
            }
        }
        return fmt(buf, "{d}", .{n});
    }
    if (val.asAtom()) |id| {
        const name = vm.stringValue(id);
        if (std.mem.eql(u8, name, "<dead>")) return "<dead>";
        return fmt(buf, ":{s}", .{name});
    }
    if (val.asString()) |id| {
        const s = vm.stringValue(id);
        if (s.len > 20) return fmt(buf, "\"{s}...\"", .{s[0..20]});
        return fmt(buf, "\"{s}\"", .{s});
    }
    return "nil";
}

/// collapsed, truncated text of src span an instruction was lowered from
fn spanText(source: []const u8, span: revo.lang.Span, buf: []u8) []const u8 {
    if (source.len == 0 or span.start >= source.len) return "";
    const end = @min(span.end, source.len);
    if (end <= span.start) return "";
    const raw = source[span.start..end];
    var out: usize = 0;
    var in_ws = false;
    for (raw) |ch| {
        const is_ws = ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r';
        if (out >= buf.len - 1) break;
        if (is_ws) {
            if (!in_ws) {
                buf[out] = ' ';
                out += 1;
                in_ws = true;
            }
        } else {
            buf[out] = ch;
            out += 1;
            in_ws = false;
        }
    }
    return buf[0..out];
}

/// decode an instructions operands per-opcode
fn operandText(vm: *revo.VM, inst: revo.Instruction, buf: []u8) []const u8 {
    const op = inst.op;
    const a = inst.a;
    const b = inst.b;
    const c = inst.c;
    const bx = inst.bx;

    switch (op) {
        .move => return fmt(buf, "r{d}, r{d}", .{ a, b }),
        .load_const => {
            if (bx < vm.constants.items.len) {
                var val_buf: [40]u8 = undefined;
                const val = dataText(vm, vm.constants.items[bx], &val_buf);
                return fmt(buf, "r{d}, {s}", .{ a, val });
            }
            return fmt(buf, "r{d}, const#{d}", .{ a, bx });
        },
        .load_nil => return fmt(buf, "r{d}", .{a}),
        .load_small_int => return fmt(buf, "r{d}, {d}", .{ a, bx }),
        .load_global => {
            const name = vm.stringValue(bx);
            if (std.mem.eql(u8, name, "<dead>")) return fmt(buf, "r{d}, ?", .{a});
            return fmt(buf, "r{d}, :{s}", .{ a, name });
        },
        .store_global, .store_global_const => {
            const name = vm.stringValue(bx);
            if (std.mem.eql(u8, name, "<dead>")) return fmt(buf, "?, r{d}", .{a});
            return fmt(buf, ":{s}, r{d}", .{ name, a });
        },
        .load_stdlib_global => return fmt(buf, "r{d}, global#{d}", .{ a, bx }),
        .load_local => return fmt(buf, "r{0}, slot{1}", .{ a, b }),
        .bind_local, .store_local => return fmt(buf, "slot{0}, r{1}", .{ a, b }),
        .load_upval => return fmt(buf, "r{d}, upval#{d}", .{ a, bx }),
        .store_upval => return fmt(buf, "upval#{d}, r{d}", .{ bx, a }),
        .closure => {
            if (bx < vm.functions.prototypes.items.len) {
                const name = vm.functions.prototypes.items[bx].name;
                if (name.len > 0) return fmt(buf, "r{d}, proto#{d} ({s})", .{ a, bx, name });
            }
            return fmt(buf, "r{d}, proto#{d}", .{ a, bx });
        },
        .negate, .negate_int, .not => return fmt(buf, "r{d}, r{d}", .{ a, b }),
        .table_set, .table_get => return fmt(buf, "r{d}, r{d}, r{d}", .{ a, b, c }),
        .table_new => return fmt(buf, "r{d}", .{a}),
        .table_set_atom => {
            const name = vm.stringValue(bx);
            if (std.mem.eql(u8, name, "<dead>")) return fmt(buf, "r{d}, ?, r{d}", .{ a, c });
            return fmt(buf, "r{d}, :{s}, r{d}", .{ a, name, c });
        },
        .table_get_atom => {
            const name = vm.stringValue(bx);
            if (std.mem.eql(u8, name, "<dead>")) return fmt(buf, "r{d}, r{d}, ?", .{ a, b });
            return fmt(buf, "r{d}, r{d}, :{s}", .{ a, b, name });
        },
        .slice => return fmt(buf, "r{d}, r{d}, r{d}, r{d}, r{d}", .{ a, b, b + 1, b + 2, b + 3 }),
        .halt, .join, .ret => return fmt(buf, "r{d}", .{a}),
        .jump => return fmt(buf, "-> L{d}", .{bx}),
        .jump_if_false, .jump_if_true, .jump_err => {
            return fmt(buf, "r{d} -> L{d}", .{ a, bx });
        },
        .call, .spawn => return fmt(buf, "r{d}, args={d}, -> r{d}", .{ a, b, c }),
        .call_field => {
            const argc = b & 0x7f;
            if ((b & 0x80) != 0) return fmt(buf, "r{d}, args={d} (+self), -> r{d}", .{ a, argc, c });
            return fmt(buf, "r{d}, args={d}, -> r{d}", .{ a, argc, c });
        },
        .yield => return "",
        .range_init => return fmt(buf, "r{d}, r{d}..r{d}, step=r{d}", .{ a, b, c, bx }),
        .range_loop => return fmt(buf, "r{d}, state=r{d}, idx=r{d}, -> L{d}", .{ a, b, c, bx }),
        .unwrap_result => return fmt(buf, "r{d}, mode={d}", .{ a, bx }),
        .add_int_imm, .sub_int_imm, .mul_int_imm, .band_int_imm, .lt_int_imm => return fmt(
            buf,
            "r{d}, r{d}, {d}",
            .{ a, b, bx },
        ),

        else => return fmt(buf, "r{d}, r{d}, r{d}", .{ a, b, c }), // bin arith & cmp
    }
}

pub fn printBenchStats(times: []std.Io.Duration) void {
    std.mem.sort(std.Io.Duration, times, {}, struct {
        pub fn lessThan(_: void, a: std.Io.Duration, b: std.Io.Duration) bool {
            return a.nanoseconds < b.nanoseconds;
        }
    }.lessThan);

    const best = if (times.len > 0) times[0].nanoseconds else @as(i96, 0);
    const worst = if (times.len > 0) times[times.len - 1].nanoseconds else @as(i96, 0);
    const median = if (times.len > 0) times[times.len / 2].nanoseconds else @as(i96, 0);
    const p95_idx = if (times.len > 0) @min(times.len - 1, (times.len * 95) / 100) else 0;
    const p95 = if (times.len > 0) times[p95_idx].nanoseconds else @as(i96, 0);

    const best_ms = @as(f64, @floatFromInt(best)) / 1_000_000.0;
    const worst_ms = @as(f64, @floatFromInt(worst)) / 1_000_000.0;
    const median_ms = @as(f64, @floatFromInt(median)) / 1_000_000.0;
    const p95_ms = @as(f64, @floatFromInt(p95)) / 1_000_000.0;

    std.debug.print("+=========================\n", .{});
    std.debug.print("| best    {d:.3}ms / {d}ns\n", .{ best_ms, best });
    std.debug.print("| median  {d:.3}ms / {d}ns\n", .{ median_ms, median });
    std.debug.print("| p95     {d:.3}ms / {d}ns\n", .{ p95_ms, p95 });
    std.debug.print("| worst   {d:.3}ms / {d}ns\n", .{ worst_ms, worst });
}

test "failure rendering includes stack trace frames" {
    var failure = EvalFailure{
        .kind = .TypeError,
        .report = .{
            .source_name = "file.rv",
            .source = "ignored",
            .parts = &.{
                diagnostic.Part{ .@"error" = "boom" },
                .{ .span = .{ .span = .{ .line = 2, .column = 4, .start = 0, .end = 1 }, .role = .primary } },
            },
        },
        .part_len = 2,
        .trace_len = 2,
    };
    failure.parts[0] = diagnostic.Part{ .@"error" = "boom" };
    failure.parts[1] = .{ .span = .{ .span = .{ .line = 2, .column = 4, .start = 0, .end = 1 }, .role = .primary } };
    failure.parts[2] = .{ .trace = .{
        .function_name = "inner",
        .source_name = "file.rv",
        .span = .{
            .line = 2,
            .column = 4,
            .start = 0,
            .end = 1,
        },
    } };
    failure.parts[3] = .{ .trace = .{
        .function_name = "<module>",
        .source_name = "file.rv",
        .pc = 7,
    } };
    failure.part_len = 4;

    var buf = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer buf.deinit();
    try failure.render(std.testing.allocator, &buf.writer, "unused");

    try std.testing.expect(std.mem.find(u8, buf.written(), "stack trace:") != null);
    try std.testing.expect(std.mem.find(u8, buf.written(), "0: inner at file.rv:2:4") != null);
    try std.testing.expect(std.mem.find(u8, buf.written(), "1: <module> at file.rv:pc=7") != null);
}
