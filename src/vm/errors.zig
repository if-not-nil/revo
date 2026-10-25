const std = @import("std");

const revo = @import("revo");
const diagnostic = revo.lang.diagnostic;
pub const TraceFrame = diagnostic.TraceFrame;

pub const RunError = error{
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

pub const RunErrorKind = enum {
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
    pub fn message(self: RunErrorKind) []const u8 {
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

pub const RunFailure = struct {
    pub const max_trace_frames = 64;

    kind: RunErrorKind,
    report: diagnostic.Report,
    part_len: usize = 0,
    parts: [max_trace_frames + 2]diagnostic.Part = @splat(diagnostic.Part{ .@"error" = "" }),
    trace_len: usize = 0,
    trace: [max_trace_frames]TraceFrame = @splat(TraceFrame.empty()),

    pub fn render(
        self: RunFailure,
        writer: *std.Io.Writer,
        source: []const u8,
        color: bool,
    ) !void {
        return self.renderAt(
            writer,
            self.report.source_name orelse "<source>",
            self.report.source orelse source,
            color,
        );
    }

    pub fn renderAt(
        self: RunFailure,
        writer: *std.Io.Writer,
        source_name: []const u8,
        source: []const u8,
        color: bool,
    ) !void {
        var report = self.report;
        report.source_name = source_name;
        report.source = source;
        report.parts = self.parts[0..self.part_len];
        try diagnostic.renderReport(writer, report, .{ .color = color });
    }
};

pub const RunResult = union(enum) {
    ok,
    err: RunFailure,
};
