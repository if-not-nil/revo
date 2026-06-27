pub const bytecode = @import("bytecode.zig");
pub const ChannelID = @import("VM.zig").ChannelID;
pub const ConstantID = @import("VM.zig").ConstantID;
pub const debug = @import("debug.zig");
pub const NativeError = @import("debug.zig").NativeError;
pub const EvalErrorKind = @import("debug.zig").EvalErrorKind;
pub const EvalFailure = @import("debug.zig").EvalFailure;
pub const EvalResult = @import("debug.zig").EvalResult;
pub const functions = @import("functions.zig");
pub const GlobalID = @import("VM.zig").GlobalID;
pub const interner = @import("interner.zig");
pub const lookup = @import("lookup.zig");
pub const memory = @import("memory.zig");
pub const Data = memory.Data;
pub const module = @import("module.zig");
pub const opcode = @import("opcode.zig");
pub const Instruction = opcode.Instruction;
pub const Opcode = opcode.Opcode;
pub const print = @import("print.zig");
pub const ProgramCounter = @import("VM.zig").ProgramCounter;
pub const core_atoms = @import("core.zig").core_atoms;
pub const isFalse = @import("memory.zig").isFalse;
pub const Scheduler = @import("scheduler.zig").Scheduler;
pub const struct_mod = @import("struct.zig");
pub const table = @import("table.zig");
pub const tests = @import("tests.zig");
pub const tuple = @import("tuple.zig");
pub const VM = @import("VM.zig").VM;

// re-exports from root module (source of truth)
// note: also available as revo.core_atoms and revo.isFalse
// root module is revo
test {
    _ = @import("bytecode.zig");
    _ = @import("VM.zig");
    _ = @import("debug.zig");
    _ = @import("functions.zig");
    _ = @import("interner.zig");
    _ = @import("memory.zig");
    _ = @import("module.zig");
    _ = @import("module.zig");
    _ = @import("opcode.zig");
    _ = @import("table.zig");
    _ = @import("tests.zig");
    _ = @import("tuple.zig");
}
