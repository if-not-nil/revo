pub const Operand = usize;
pub const Register = u8;

pub const Opcode = enum(u8) {
    move, // "R[a] <- R[b]"
    load_const, // "R[a] <- constants[bx]"
    load_nil, // "R[a] <- nil"
    load_small_int, // "R[a] <- bx (small int 0..65535)"
    load_global, // "R[a] <- globals[bx]"
    load_stdlib_global, // "R[a] <- stdlib_globals[bx]"
    store_global, // "globals[bx] <- R[a]"
    store_global_const, // "globals[bx] <- R[a], mark const"
    load_local, // "R[a] <- R[b] (local read)"
    bind_local, // "R[a] <- R[b] (local init)"
    store_local, // "R[a] <- R[b] (local write)"
    load_upval, // "R[a] <- upvalue[bx]"
    store_upval, // "upvalue[bx] <- R[a]"
    closure, // "R[a] <- closure(prototype=bx)"
    add, // "R[a] <- R[b] + R[c]"
    concat, // "R[a] <- R[b] ~ R[c]"
    sub, // "R[a] <- R[b] - R[c]"
    mul, // "R[a] <- R[b] * R[c]"
    div, // "R[a] <- R[b] / R[c]"
    mod, // "R[a] <- R[b] % R[c]"
    band, // "R[a] <- R[b] & R[c] (int operands)"
    bor, // "R[a] <- R[b] | R[c] (int operands)"
    bxor, // "R[a] <- R[b] ^ R[c] (int operands)"
    shl, // "R[a] <- R[b] << R[c] (int operands, wraps)"
    shr, // "R[a] <- R[b] >> R[c] (int operands)"
    int_div, // "R[a] <- R[b] // R[c] (floor int division)"
    negate, // "R[a] <- -R[b]"
    // typed arith with an immediate operand (bx = constant)
    add_int_imm, // "R[a] <- (int)R[b] + bx"
    sub_int_imm, // "R[a] <- (int)R[b] - bx"
    mul_int_imm, // "R[a] <- (int)R[b] * bx"
    band_int_imm, // "R[a] <- (int)R[b] & bx"
    pow, // "R[a] <- R[b] ^ R[c] (int if both integral, else float)"
    /// "R[a] <- R[b] == R[c]"
    eq,
    neq, // "R[a] <- R[b] != R[c]"
    lt, // "R[a] <- R[b] < R[c]"
    gt, // "R[a] <- R[b] > R[c]"
    lte, // "R[a] <- R[b] <= R[c]"
    gte, // "R[a] <- R[b] >= R[c]"
    // typed compare
    eq_int, // "R[a] <- (int)R[b] == (int)R[c]"
    neq_int, // "R[a] <- (int)R[b] != (int)R[c]"
    lt_int, // "R[a] <- (int)R[b] < (int)R[c]"
    gt_int, // "R[a] <- (int)R[b] > (int)R[c]"
    lte_int, // "R[a] <- (int)R[b] <= (int)R[c]"
    gte_int, // "R[a] <- (int)R[b] >= (int)R[c]"
    // typed compare with an immediate operand (bx = constant)
    lt_int_imm, // "R[a] <- (int)R[b] < bx"
    @"and", // "R[a] <- bool(R[b] and R[c])"
    @"or", // "R[a] <- bool(R[b] or R[c])"
    not, // "R[a] <- not R[b]"
    table_new, // "R[a] <- table_new()"
    table_set, // "R[a][R[b]] <- R[c]"
    table_get, // "R[a] <- table_get(R[b], R[c])"
    table_set_atom, // "R[a][:atom(bx)] <- R[c]"
    table_get_atom, // "R[a] <- table_get(R[b], :atom(bx))"
    slice, // "R[a] <- slice(R[b], R[b+1], R[b+2], R[b+3])"
    halt, // "halt with R[a]"
    jump, // "pc <- bx"
    jump_if_false, // "if falsey(R[a]) pc <- bx"
    jump_if_true, // "if truthy(R[a]) pc <- bx"
    call, // "call R[a] argc=b -> R[c]"
    call_field, // "call_field from R[a] argc=b -> R[c]"
    ret, // "return R[a]"
    spawn, // "spawn R[a] argc=b -> R[c]"
    join, // "join handle in R[a]"
    yield, // "yield fiber"
    /// init an range iter for really fast forloops
    ///
    /// R[a]   out: current = start
    /// R[b]   in : start
    /// R[c]   in : end/limit
    /// bx     in : register index with step value
    ///
    /// state layout:
    /// R[a]       = current (updated each iteration)
    /// R[a+1]     = step
    /// R[a+2]     = limit (end value)
    ///
    /// notes:
    /// - zero-step ranges are infinite loops (not checked)
    /// - uses 3 consecutive registers for loop state
    range_init,

    /// fused range advance + check + back-branch (bottom-tested)
    ///
    /// R[a]   out: current iteration value (the x in for x in ...)
    /// R[b]   in : current (loop state register)
    /// R[c]   out: current 0-based index (or 0 if not needed)
    /// bx     in : back-jump target (instruction index)
    ///
    /// expects loop state in consecutive registers starting at R[b]:
    /// R[b]   = current
    /// R[b+1] = step
    /// R[b+2] = limit
    ///
    /// behavior:
    /// - checks if current has passed limit (leftinclusive rightexclusive)
    /// - if has_next: writes current to R[a], writes index to R[c],
    ///   advances current += step, index += 1, and jumps to bx
    /// - else: falls through (loop done)
    range_loop,

    /// R[a] is {:ok, x}? extract x into R[a]; or {:err, e}? ret; otherwise pass through
    /// bx = 0: propagate errors
    /// bx = 1: dont propagate
    unwrap_result,
    jump_err, // if not nil/undef and not {:err, ...}, jump to bx
};

pub const Instruction = packed struct {
    op: Opcode,
    a: u8 = 0,
    b: u8 = 0,
    c: u8 = 0,
    bx: u32 = 0,
};
