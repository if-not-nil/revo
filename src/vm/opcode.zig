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
    negate, // "R[a] <- -R[b]"
    // typed unary
    negate_int, // "R[a] <- -(int)R[b]"
    negate_float, // "R[a] <- -(float)R[b]"
    // typed arith
    add_int, // "R[a] <- (int)R[b] + (int)R[c]"
    sub_int, // "R[a] <- (int)R[b] - (int)R[c]"
    mul_int, // "R[a] <- (int)R[b] * (int)R[c]"
    mod_int, // "R[a] <- (int)R[b] % (int)R[c]"
    div_float, // "R[a] <- (float)R[b] / (float)R[c]"
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
    @"and", // "R[a] <- bool(R[b] and R[c])"
    @"or", // "R[a] <- bool(R[b] or R[c])"
    not, // "R[a] <- not R[b]"
    tuple_new, // "R[a] <- tuple(R[b .. b+bx))"
    tuple_get, // "R[a] <- tuple_get(R[b], R[c])"
    table_new, // "R[a] <- table_new()"
    table_set, // "R[a][R[b]] <- R[c]"
    table_get, // "R[a] <- table_get(R[b], R[c])"
    table_set_atom, // "R[a][:atom(bx)] <- R[c]"
    table_get_atom, // "R[a] <- table_get(R[b], :atom(bx))"
    struct_new, // "R[a] <- struct_new(typeid=bx)" (new struct instance with defaults)
    struct_set_method, // "struct_add_method(R[a]=type_val, R[b]=name_atom, R[c]=method)"
    struct_get_offset, // "R[a] <- struct_field(R[b], offset=bx)" (fast fixed-offset field access on struct_val)
    struct_set_offset, // "struct_field(R[a])[bx] <- R[c]" (fast fixed-offset field write on struct_val)
    tuple_get_const, // "R[a] <- tuple_get(R[b], bx)"
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

    /// advance range iterator and emit value/index
    ///
    /// R[a]   out: current iteration value (the x in for x in ...)
    /// R[b]   in : current (loop state register)
    /// R[c]   out: current 0-based index (or 0 if not needed)
    /// bx     in : register index to write `has_next` boolean
    ///
    /// expects loop state in consecutive registers starting at R[b]:
    /// R[b]   = current
    /// R[b+1] = step
    /// R[b+2] = limit
    ///
    /// behavior:
    /// - checks if current has passed limit (leftinclusive rightexclusive)
    /// - writes has_next to R[bx]
    /// - writes current to R[a] (value for loop body)
    /// - writes index to R[c] (if c != 0)
    /// - advances current += step, index += 1 if has_next
    range_next,

    /// loop counter for unrolled range iterations
    ///
    /// R[a] in/out: current
    /// R[b] in:     step
    /// R[c] in:     limit
    /// bx   in:     max iterations to unroll
    ///
    /// advances current up to bx times, stops early if past limit
    /// returns actual iterations completed in R[a]
    range_for,
    /// R[a] is (:ok, x)? extract x into R[a]; or (:err, e)? ret; otherwise pass through
    /// bx = 0: propagate errors
    /// bx = 1: dont propagate
    unwrap_result,
    /// TODO: maybe merge these two
    jump_if_not_nil_and_not_err, // if not nil and not (:err, ...), jump to bx
    jump_if_err, // if (:err, ...), jump to bx
};

pub const Instruction = packed struct {
    op: Opcode,
    a: u8 = 0,
    b: u8 = 0,
    c: u8 = 0,
    bx: u32 = 0,
};
