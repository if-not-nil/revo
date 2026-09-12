//
// embedding revo, in c
// build: make basic (or just `make`)
// links against liberevo.a from zig build lib
// requires zig-out/include/revo.h and zig-out/lib/liberevo.a
//

#include "revo.h"
#include <stdio.h>
#include <string.h>

static void print_value(void *vm, RevoData value) {
  if (revo_is_number(value)) {
    printf("number: %.0f\n", revo_num_value(value));
  } else if (revo_is_string(value)) {
    uint64_t sid = revo_string_id(value);
    size_t len = revo_string_length(vm, sid);
    const char *data = revo_string_data(vm, sid);
    printf("string: \"%.*s\" (len=%zu)\n", (int)len, data, len);
  } else if (revo_is_nil(value)) {
    printf("nil\n");
  } else if (revo_is_bool(value)) {
    printf("bool: %s\n", revo_string_id(value) == ra_true ? "true" : "false");
  } else if (revo_is_atom(value)) {
    printf("atom id=%llu\n", (unsigned long long)revo_string_id(value));
  } else {
    printf("tag=%d\n", revo_type(value));
  }
}

int main(void) {
  // create vm
  ErevoVM *vm = erevo_vm_create();
  if (!vm) return 1;

	//
  // compile and run a numeric expression
  ErevoProgram *prog = erevo_compile(vm, "ex", "1 + 2");
  if (!prog) {
    puts(erevo_vm_last_error(vm));
    erevo_vm_destroy(vm);
    return 1;
  }

  ErevoData val;
  if (!erevo_run(vm, prog, &val)) {
    puts(erevo_vm_last_error(vm));
    erevo_program_destroy(prog);
    erevo_vm_destroy(vm);
    return 1;
  }
  printf("1 + 2 = ");
  print_value(vm, val);

	//
  // eval a string literal
  if (!erevo_eval(vm, "ex", "\"hello world\"", &val)) {
    puts(erevo_vm_last_error(vm));
    erevo_program_destroy(prog);
    erevo_vm_destroy(vm);
    return 1;
  }
  printf("string  = ");
  print_value(vm, val);

	//
  // set a global from C, then read it back
  revo_setglobal(vm, (uint64_t)(uintptr_t)"answer", 6, revo_num(42.0));
  val = revo_getglobal(vm, (uint64_t)(uintptr_t)"answer", 6);
  printf("global  = ");
  print_value(vm, val);

	//
  // create a table with eval, then access it from C
  // revo uses newlines to separate expressions (no semicolons)
  if (!erevo_eval(vm, "ex", "do const t = {} t.x = 10 t end", &val)) {
    puts(erevo_vm_last_error(vm));
    erevo_program_destroy(prog);
    erevo_vm_destroy(vm);
    return 1;
  }

  // val is the table, read its field by name
  RevoData tval;
  if (!revo_table_get_name(vm, val, (uint64_t)(uintptr_t)"x", 1, &tval)) return 1;
  printf("table.x = ");
  print_value(vm, tval);

	//
  // check nil, bool helpers
  printf("nil is_nil? %d\n", revo_is_nil(revo_nil()));
  printf("true is_bool? %d\n", revo_is_bool(revo_bool(1)));
  printf("42 is_number? %d\n", revo_is_number(revo_num(42.0)));

  erevo_program_destroy(prog);
  erevo_vm_destroy(vm);
  return 0;
}
