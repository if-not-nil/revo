---
title: two-way c interop
---

<div style="display:flex; gap:1rem; align-items:flex-start; flex-wrap:wrap;">

<div style="flex:1; min-width:250px;">

## two-way c<->revo interop

[docs](docs/basics) | [codeberg](https://codeberg.org/lung/revo) | [github (mirror)](https://github.com/if-not-nil/revo) | [license](#license)

> c is the only language that has everything a computer can do implemented in it
</div>

<pre class="ascii small">
⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⡰⣿⡆⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⣀⢀⣠⢤⡤⡤⠤⣤⠄⠀⠀⠀⠀⠀⠀⠀⠀⠀
⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⣀⢾⣥⢻⣿⣆⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⢀⣤⣶⣿⡱⣆⠤⡁⢎⡡⢵⠀⡄⠀⠀⠀⠀⠀⠀⠀⠀⠀
⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⢠⠆⣾⠸⣿⡎⢿⣿⣶⡀⠀⠀⠀⠀⠀⠀⢀⣴⣿⣿⣿⣿⡿⢘⣠⠞⡧⣙⠤⠏⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⡼⢸⢿⡇⣿⣿⡘⣿⣿⣿⡀⠀⠀⠀⠀⢠⣼⣿⣿⣿⣿⡿⣃⣿⠣⢤⣤⢛⠇⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⡰⢥⣃⣏⣷⡜⣿⣧⠹⣿⣿⣿⡄⠀⠀⣴⣿⣿⣿⣿⣿⣯⢾⣿⣿⣾⡿⠶⠃⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠵⣣⣟⣼⣷⣻⠸⣿⣦⠹⣿⣿⣿⡄⣸⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⡿⣿⡏⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⢀⠭⣘⠻⣿⣧⣿⣾⣧⠘⣿⡿⣹⣽⣿⡟⢿⣿⣿⣿⣿⣿⣿⣿⡧⣼⠄⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⢀⠠⠤⡤⢤⠶⡤⣆⣤⡀⡄⠀⠀⠀⠈⠐⠃⢈⠻⢿⣿⣿⡇⠘⡍⡷⢘⣿⣌⡄⠀⣼⣿⣿⣿⣿⣿⡗⠺⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
⠀⠀⠀⠀⠀⠀⠀⠰⠀⣀⠦⣑⢦⡙⡲⢍⡶⣋⠶⣡⠞⡝⢯⢷⣞⣶⢠⠀⠀⠀⠠⠀⠙⢿⡝⡄⡇⢱⢸⡏⢸⠆⢸⡟⣿⣿⣿⣿⣿⣟⠥⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
⠀⠀⠀⠀⠀⠀⠆⠀⠌⡄⡙⡘⠎⢷⡩⢏⠶⣩⠳⣡⠛⢬⢣⡍⠺⢞⢇⣾⠿⠆⠀⢎⡀⡄⠙⢡⣎⠞⡘⢿⡐⢀⡟⣲⢻⣿⣿⣿⣿⣏⡅⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
⠀⠀⠀⠀⠀⠀⠈⠀⢂⠌⡑⢹⣛⢦⠹⢜⡲⡡⠜⡤⢃⠀⠁⠺⢑⢪⣌⢋⣄⠀⠡⠈⠳⣦⠅⠀⠻⡆⠇⣾⡄⢸⠘⢰⣼⣿⣿⣿⡟⠒⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
⠀⠀⠀⠀⠀⠀⠀⠀⠠⠂⠍⢢⠘⢎⠵⢢⠔⣉⡘⠔⠫⠜⢦⠠⡄⢌⠂⠳⣎⠷⣄⡀⠀⠀⠙⣆⠐⣿⡆⣿⠀⡧⠰⣟⣿⣻⣿⡟⠑⠀⢀⡀⣄⣀⡀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
⠀⠀⠀⠀⠀⠀⠀⠀⠀⠈⠒⡄⠉⠎⡔⢃⠎⡱⠌⣙⠒⡆⣆⠀⠈⠃⠙⠀⠙⢼⣉⠷⢦⡐⠢⡘⢆⠙⢿⣿⠐⣱⠿⣀⣡⡶⠇⠀⢀⡐⣤⣻⣽⣯⣿⣶⣥⡄⠀⠀⠀⠀⠀⠀⠀
⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠈⠃⡴⢠⢈⡐⠡⠒⠤⡈⢄⡘⢀⠀⠆⡡⠤⣀⣄⠰⠬⠡⢙⡳⢾⣮⣡⢌⠻⠀⡿⠙⡳⢃⠉⠀⠀⠈⣁⢋⠟⡻⠿⣿⣿⣿⣿⣷⣄⡀⠀⠀⠀⠀
⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠁⠲⢤⠓⣌⠲⠤⣄⣈⢂⠒⡌⢰⡐⠤⡈⢍⡛⡫⢭⣍⣓⢾⣿⣝⢷⠤⠀⠀⠀⠤⢒⡈⣋⢛⡒⠾⠶⣴⣦⣀⡈⠍⠛⢿⣿⣽⢦⠀⠀⠀
⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠉⠚⠥⡳⡄⣙⢪⣝⠺⣧⢟⣷⡾⣧⣱⣦⠚⢀⣉⣓⣊⡙⣻⣆⠒⠄⡀⠈⢆⢳⡸⢯⣿⣿⣷⣶⣬⣙⣛⠻⢦⣤⣌⠛⣯⠓⠀⠀
⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠉⣀⠃⠮⢣⡹⢦⣛⠶⠛⠋⠀⢠⣳⡿⠟⠉⡼⢳⢌⡃⠌⠐⠀⠀⠎⠳⡛⠿⠛⡟⠿⠻⠿⢶⣻⠰⢦⡻⣝⢠⠏⠀⠀
⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⡀⠄⢢⠐⠈⠄⠀⢄⠠⠀⢀⠀⡔⢁⠣⢃⠁⡐⢨⠑⡱⢊⠔⠈⠀⠀⢠⡈⡆⢁⣤⠡⠄⠄⠆⢁⡂⠰⠨⣥⢛⠬⡣⠍⠀⠀
⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⢠⢂⠔⠈⣠⢮⡑⠊⠁⠈⠀⡠⠂⣸⠁⠨⠑⡂⢌⠀⢄⢣⣿⢨⠀⠰⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠐⠋⠺⠥⠃⠀⠀
⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⡴⢡⡞⣨⣾⣿⡗⠈⠁⠄⡡⢐⡁⢀⡏⣘⠀⢰⢁⡂⠀⣺⣼⣵⡎⠡⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⡸⢡⡗⣰⣿⣿⣿⣼⣷⡏⣄⠣⢠⠂⢸⣷⣿⡀⣿⡘⢇⢲⣿⣿⣿⣏⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⡏⡟⣰⣿⣿⣿⣿⣿⡿⣟⡽⡂⠧⠀⣾⣿⣿⡟⣿⡇⣾⣿⣿⣿⣿⣿⠇⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⡧⢁⣿⡟⣽⣿⣿⣿⡿⣉⡴⠳⠀⠀⣿⣿⣿⣧⢻⣇⢿⢾⣿⣿⣿⣿⠇⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠠⢻⡼⣽⣿⣿⣿⡿⠓⠈⠀⠀⠀⠀⢸⡟⢿⣿⣟⣿⣷⡌⢹⣿⣿⢿⠃⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠄⠻⣜⣿⠟⠁⠀⠀⠀⠀⠀⠀⠀⠘⣿⣼⣿⣿⡿⣽⣷⠀⡟⢿⣽⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠈⠘⡇⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠐⢣⡝⣿⣷⣿⣿⣧⠙⣿⣧⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠭⠁⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠉⢾⣿⣿⣷⣿⣿⡄⣻⠆⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠠⠌⠛⠿⡏⠙⠁⠆⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠉⠀⠀⠀⠁⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
</pre>
</div>

despite being written in zig, revo gives you a real c api for embedding
and extensions. the header is auto-generated from zig `callconv(.c)`
functions, always in sync with what the library actually exports.
{{< ref "src/c/ffi.zig" >}}
{{< ref "src/c/bindings.zig" >}}

### build

```bash
zig build lib
```

you get a static library and an auto-generated header:

~ `zig-out/lib/liberevo.a`
~ `zig-out/include/revo.h`

{{< ref "src/c/erevo.zig" >}}

the `extern struct`s in `erevo.zig` dictate are the ones you get in your C code

### vm lifecycle

```c
#include "revo.h"

ErevoVM *vm = erevo_vm_create();
if (!vm) return 1;

// ... use vm ...

erevo_vm_destroy(vm);
```

`ErevoVM` is an opaque handle

### compile and run

```c
ErevoProgram *prog = erevo_compile(vm, "main.rv", "1 + 2");
if (!prog) {
    puts(erevo_vm_last_error(vm));
    return 1;
}

RevoData result;
if (!erevo_run(vm, prog, &result)) {
    puts(erevo_vm_last_error(vm));
}

// eval does compile + run + free in one step
if (!erevo_eval(vm, "main.rv", "1 + 2", &result)) {
    puts(erevo_vm_last_error(vm));
}

erevo_program_destroy(prog);
```

{{< ref "pub fn erevo_compile(" >}}
{{< ref "pub fn erevo_run(" >}}
{{< ref "pub fn erevo_eval(" >}}

`erevo_run` writes the result value through the optional `result` pointer

### errors

```c
const char *msg = erevo_vm_last_error(vm);
```

returns a null-terminated string, valid until the next api call on the
same vm

### value type

all values are a single nanboxed `uint64_t`:

```c
typedef uint64_t RevoData;
```

numbers are the raw f64 bits; boxed values pack the type nibble (bits
51-48) and an intern id (low 48 bits, never a pointer) behind a box tag:

```c
typedef enum {
    revo_number = 0,
    revo_string = 8,
    revo_atom = 9,
    revo_function = 10,
    revo_table = 11,
    revo_foreign = 15,
} RevoType;
```

**constructors**

```c
RevoData v = revo_nil();              // :nil
RevoData v = revo_bool(1);            // :true / :false
RevoData v = revo_string(string_id);  // from interned id
RevoData v = revo_num(3.14);          // number
RevoData v = revo_atom_val(atom_id);  // atom by raw id
RevoData v = revo_table(table_id);    // from table id
RevoData v = revo_function(func_id);  // from function id
```

**extractors**

```c
double   revo_num_value(RevoData);
uint64_t revo_string_id(RevoData);
uint64_t revo_atom_id(RevoData);
uint64_t revo_table_id(RevoData);
int      revo_bool_val(RevoData);   // 0 or 1, 0 if not bool
int      revo_type(RevoData);       // the RevoType of the value
```

**type checks**

```c
int revo_is_nil(RevoData);
int revo_is_number(RevoData);
int revo_is_string(RevoData);
int revo_is_atom(RevoData);
int revo_is_function(RevoData);
int revo_is_table(RevoData);
int revo_is_bool(RevoData);
```

built-in atoms have guaranteed and consistent values in the `RevoAtom` enum, such as

`ra_nil`, `ra_true`, `ra_false`, `ra_ok`, `ra_err`, `ra_some`,
`ra_none`, `ra_undef`, `ra_missing`, `ra_no_result`, `ra_range`

this means you don't have to intern them manually

{{< ref "pub const RevoAtom" >}}

### foreign

this is how you trade data between c and revo

wrap and unwrap raw `void*` pointers. the caller manages the pointer's lifetime

```c
RevoData v = revo_foreign_new(ptr);    // wrap
void *p = revo_foreign_ptr(v);         // unwrap, null if not foreign
```

{{< ref "pub fn revo_foreign_new(" >}}
{{< ref "pub fn revo_foreign_ptr(" >}}

### strings

strings are interned! every unique string has a stable `uint64_t` id

```c
uint64_t sid = revo_intern(vm, (uint64_t)(uintptr_t)"hello", 5);
RevoData val = revo_string(sid);
```

the pointer must stay valid for the duration of the call

to read string data back:

```c
const unsigned char *data = revo_string_data(vm, sid);
uint64_t len = revo_string_length(vm, sid);
```

`revo_string_data` returns a pointer to the internal string buffer
(valid until the string is gc'd) and is **not** nul-terminated!!! use
`revo_string_length` for the byte count, copy when you need a c string
{{< ref "pub fn revo_intern(" >}}
{{< ref "pub fn revo_string_data(" >}}

### calling revo functions from c

```c
RevoData fn_val;             // get from eval, global, etc.
RevoData args[2] = { revo_num(10.0), revo_num(20.0) };
RevoData result;

int ok = revo_call(vm, fn_val, 2, args, &result);
```

returns 0 if the value wasn't callable or the call threw. max 16 args.
{{< ref "pub fn revo_call(" >}}

### globals

```c
revo_setglobal(vm, (uint64_t)(uintptr_t)"name", 4, revo_num(42.0));
RevoData v = revo_getglobal(vm, (uint64_t)(uintptr_t)"name", 4);

// or via c-string wrappers (call strlen internally)
revo_setglobal_cstr(vm, "name", revo_num(42.0));
RevoData v = revo_getglobal_cstr(vm, "name");
```

missing keys return `:nil`
{{< ref "pub fn revo_getglobal(" >}}
{{< ref "pub fn revo_setglobal(" >}}

### tables

functions take the table value itself, lookups report presence
through the return value so missing keys are distinct from nil values:

```c
RevoData t = revo_table_create(vm);

// named fields
revo_table_set_name(vm, t, (uint64_t)"x", 1, revo_num(42.0));
RevoData v;
bool found = revo_table_get_name(vm, t, (uint64_t)"x", 1, &v);  // true

// generic keys (metatable-aware, like t[k])
RevoData key = revo_atom_val(revo_intern_atom(vm, ...));
revo_table_set(vm, t, key, revo_num(42.0));

// array part
RevoData arr = revo_table_from_items(vm, 2, (RevoData[]){ revo_num(1.0), revo_num(2.0) });
revo_table_push(vm, arr, revo_num(3.0));
revo_table_get_idx(vm, arr, 1, &v);   // 2.0, false when out of range

uint64_t n = revo_table_len(vm, t);    // total entries
uint64_t a = revo_table_alen(vm, arr); // array part only
```

{{< ref "pub fn revo_table_create(" >}}
{{< ref "pub fn revo_table_set(" >}}
{{< ref "pub fn revo_table_get(" >}}

### results

host functions answer with `{:ok, v}` / `{:err, e}` tables:

```c
if (bad) {
    *out_result = revo_err(vm, revo_atom_val(
        revo_intern_atom(vm, (uint64_t)"BadInput", 8)));
    return;
}
// ... later, on the receiving side:
if (revo_is_ok(vm, val)) {
    RevoData payload;
    revo_ok_value(vm, val, &payload);
}
```

{{< ref "pub fn revo_ok(" >}}
{{< ref "pub fn revo_is_ok(" >}}

### writing c extensions

extensions are shared libraries that export a `revo_bindings` array.
every c function follows this signature:

```c
typedef void (*RevoFn)(void *vm, size_t argc, RevoData *argv, RevoData *out);
```

a minimal extension:

```c
#include "revo.h"

void greet(void *vm, size_t argc, RevoData *argv, RevoData *out) {
    *out = revo_num(42.0);
}

__attribute__((visibility("default")))
const RevoBinding revo_bindings[] = {
    {"greet", greet},
    {NULL, NULL},
};
```

each binding is just `name` and `fn_ptr`. the typed interface lives in a
sibling `.d.rv` manifest, and every binding lands in the module table under
the import's name

the last row is an all-null terminator

a worked-through example is at {{< ref "examples/c/extension.c" >}}, rebuild the `.so` after editing

**data conversion**

`RevoData` is nanboxed: numbers are the raw f64 bits, everything else
is the type nibble plus an interned id packed into the low 48 bits.
the type helpers read a c value out of the same word:

```ruby
`revo type`    - `c check`          - `c extractor`

42 (number)    - revo_is_number   - revo_num_value
"hi" (string)  - revo_is_string   - revo_string_id
:atom          - revo_is_atom     - revo_atom_id
fn()           - revo_is_function - revo_function_id
{} (table)     - revo_is_table    - revo_table_id
{1, 2} (table) - revo_is_table    - revo_table_id
foreign ptr    - revo_type(v) == revo_foreign - revo_foreign_ptr
```

a value can be moved through any of the constructors in its row
(the word is self-describing, no separate tag field)

strings must be interned before returning:

```c
const char *msg = "hello";
uint64_t id = revo_intern(vm, (uint64_t)(uintptr_t)msg, 5);
*out = revo_string(id);
```

**loading from revo**

module members come from the sibling manifest, so call the import directly
and the calls are checked:

```revo
# extension.d.rv: the interface, plain revo
pub declare add = fn(a: number, b: number) -> number
pub declare concat = fn(parts: table, sep: string) -> string
```

```revo
import "extension.so"
extension.add 3, 4
extension.concat ({"a", "b", "c"}, "-")   # typed from the manifest
```

`import "extension.so"` finds `extension.d.rv` next to it by stem, types every
call against the `pub declare`s, and loads every binding into the module table.
the manifest is the whole description:

manifests are real revo source, so there's no grammar ceiling: unions,
nullables, error unions, varargs, and keyword names all work.

without a manifest the bindings still load into the module table, just untyped:
the `.so` is opaque to the compiler, so nothing checks those calls

for scripts where a `.d.rv` shows up without a library, the import still
typechecks but resolves to an empty table at runtime (edit-time only)

{{< ref "fn cload(" >}}

**building**

```bash
# linux
cc -shared -fPIC -o extension.so extension.c -I/path/to/zig-out/include

# macos
cc -shared -fPIC -o extension.dylib extension.c -I/path/to/zig-out/include
```

#### best practices

- validate arguments manually (functions are variadic for now)
- always set `*out`, even for nil
- `-fPIC` for shared libraries
- don't store `RevoData` values past the call; intern or copy what
  you need
- if you need persistent state, make a table in revo and pass it as
  context
