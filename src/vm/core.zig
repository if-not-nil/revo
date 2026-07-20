//
// core atoms enum and isFalse truth check
// defined here so vm files can import them without going through revo
//

pub const core_atoms = enum(usize) {
    nil,
    missing,
    undef,
    none,
    no_result,
    no,
    false,
    // false atoms all above to check faster
    true,
    range,
    ok,
    err,
    some,
    __index,
    __newindex,
    __tostring,
    __debug,
    __call,
    __iter,
    __len,
    done,
    obj,
    pos,
    iter,
    pred,
    index,
    items,
    len,
    type,
    tuple,
    to_iter,
    chan,
    eof,
    next,
    import,
    __is_server,
    __entry_ptr,
    socket,
    port,
    max_bytes,
    delimiter,
    mode,
    read_some,
    read_all,
    read_line,
    path,
    file,
    SocketClosed,
    InvalidAddress,
    ConnectionFailed,
    SocketSetupFailed,
    NotServerSocket,
    AcceptFailed,
    CannotSendOnServer,
    SendFailed,
    CannotRecvOnServer,
    RecvFailed,
    int,
    bool,
    integer,
    float,
    number,
    num,

    pub const lastFalse = @intFromEnum(@This().false);

    pub inline fn atom_id(comptime a: @This()) usize {
        return @intFromEnum(a);
    }

    pub inline fn str(comptime a: @This()) []const u8 {
        return @tagName(a);
    }
};
