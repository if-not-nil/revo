//
// c api test suite for revo
// compile and run with: zig build test-c
// or: cc -I zig-out/include src/c/tests.c zig-out/lib/liberevo.a -lm -o
// /tmp/revo-c-test && /tmp/revo-c-test
//

#include "revo.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <string.h>

static int failed = 0;

#define T(name)                                                                \
  do {                                                                         \
    printf("  " name "... ");                                                  \
    fflush(stdout);                                                            \
  } while (0)
#define OK                                                                     \
  do {                                                                         \
    printf("ok\n");                                                            \
  } while (0)
#define FAIL(msg)                                                              \
  do {                                                                         \
    printf("FAIL: %s\n", msg);                                                 \
    failed = 1;                                                                \
  } while (0)

int main(void) {
  puts("c api tests");

  T("vm create");
  ErevoVM *vm = erevo_vm_create();
  assert(vm && "vm should not be null");
  OK;

  T("compile and run 1 + 2");
  ErevoProgram *prog = erevo_compile(vm, "test", "1 + 2");
  if (!prog)
    FAIL(erevo_vm_last_error(vm));
  assert(prog);
  ErevoData val;
  int ok = erevo_run(vm, prog, &val);
  if (!ok)
    FAIL(erevo_vm_last_error(vm));
  assert(ok);
  assert(revo_is_number(val));
  assert(fabs(revo_num_value(val) - 3.0) < 1e-12);
  OK;

  T("compile and run string literal");
  ok = erevo_eval(vm, "test", "\"hello\"", &val);
  if (!ok)
    FAIL(erevo_vm_last_error(vm));
  assert(ok);
  assert(revo_is_string(val));
  uint64_t sid = revo_string_id(val);
  assert(revo_string_length(vm, sid) == 5);
  assert(memcmp(revo_string_data(vm, sid), "hello", 5) == 0);
  OK;

  T("compile and run bool true");
  ok = erevo_eval(vm, "test", ":true", &val);
  if (!ok)
    FAIL(erevo_vm_last_error(vm));
  assert(ok);
  assert(revo_is_bool(val));
  assert(revo_string_id(val) == ra_true);
  OK;

  T("compile and run bool false");
  ok = erevo_eval(vm, "test", ":false", &val);
  if (!ok)
    FAIL(erevo_vm_last_error(vm));
  assert(ok);
  assert(revo_is_bool(val));
  assert(revo_string_id(val) == ra_false);
  OK;

  T("compile and run :nil");
  ok = erevo_eval(vm, "test", ":nil", &val);
  if (!ok)
    FAIL(erevo_vm_last_error(vm));
  assert(ok);
  assert(revo_is_nil(val));
  OK;

  T("compile and run atom :ok");
  ok = erevo_eval(vm, "test", ":ok", &val);
  if (!ok)
    FAIL(erevo_vm_last_error(vm));
  assert(ok);
  assert(revo_is_atom(val));
  assert(revo_string_id(val) == ra_ok);
  OK;

  T("compile and run table literal");
  ok = erevo_eval(vm, "test", "{a = 1}", &val);
  if (!ok)
    FAIL(erevo_vm_last_error(vm));
  assert(ok);
  assert(revo_is_table(val));
  OK;

  T("set and get global");
  revo_setglobal(vm, (uint64_t)(uintptr_t)"pi", 2, revo_num(3.14));
  val = revo_getglobal(vm, (uint64_t)(uintptr_t)"pi", 2);
  assert(revo_is_number(val));
  assert(fabs(revo_num_value(val) - 3.14) < 1e-12);
  OK;

  T("get missing global returns nil");
  val = revo_getglobal(vm, (uint64_t)(uintptr_t)"nope", 4);
  assert(revo_is_nil(val));
  OK;

  T("intern and read back string");
  sid = revo_intern(vm, (uint64_t)(uintptr_t)"world", 5);
  assert(sid != 0);
  assert(revo_string_length(vm, sid) == 5);
  assert(memcmp(revo_string_data(vm, sid), "world", 5) == 0);
  OK;

  T("intern atom");
  uint64_t aid = revo_intern_atom(vm, (uint64_t)(uintptr_t)"hello", 5);
  assert(aid != 0);
  OK;

  //
  // table
  //
  T("create table via eval, read field from c");
  ok = erevo_eval(vm, "test", "do let t = {} t.x = 42 t end", &val);
  if (!ok)
    FAIL(erevo_vm_last_error(vm));
  assert(ok);
  assert(revo_is_table(val));
  uint64_t tid = revo_string_id(val);
  uint64_t x_atom = revo_intern_atom(vm, (uint64_t)(uintptr_t)"x", 1);
  ErevoData tval = revo_table_get(vm, tid, revo_atom_val(x_atom));
  assert(revo_is_number(tval));
  assert(fabs(revo_num_value(tval) - 42.0) < 1e-12);
  OK;

  T("table_set and table_get round-trip");
  revo_table_set(vm, tid, revo_atom_val(x_atom), revo_num(99.0));
  tval = revo_table_get(vm, tid, revo_atom_val(x_atom));
  assert(revo_is_number(tval));
  assert(fabs(revo_num_value(tval) - 99.0) < 1e-12);
  OK;

  T("table_get missing key returns nil");
  uint64_t y_atom = revo_intern_atom(vm, (uint64_t)(uintptr_t)"y", 1);
  tval = revo_table_get(vm, tid, revo_atom_val(y_atom));
  assert(revo_is_nil(tval));
  OK;

  T("revo_table_create returns empty table");
  RevoData t = revo_table_create(vm);
  assert(revo_is_table(t));
  assert(revo_table_len(vm, revo_table_id(t)) == 0);
  OK;

  T("revo_table_create set and get fields");
  uint64_t a_atom = revo_intern_atom(vm, (uint64_t)(uintptr_t)"a", 1);
  uint64_t b_atom = revo_intern_atom(vm, (uint64_t)(uintptr_t)"b", 1);
  revo_table_set(vm, revo_table_id(t), revo_atom_val(a_atom), revo_num(10.0));
  revo_table_set(vm, revo_table_id(t), revo_atom_val(b_atom), revo_num(20.0));
  assert(revo_table_len(vm, revo_table_id(t)) == 2);
  RevoData tv = revo_table_get(vm, revo_table_id(t), revo_atom_val(a_atom));
  assert(revo_is_number(tv));
  assert(fabs(revo_num_value(tv) - 10.0) < 1e-12);
  tv = revo_table_get(vm, revo_table_id(t), revo_atom_val(b_atom));
  assert(revo_is_number(tv));
  assert(fabs(revo_num_value(tv) - 20.0) < 1e-12);
  OK;

  //
  // tuple
  //
  T("revo_tuple_create and read back");
  RevoData items[3];
  items[0] = revo_num(1.0);
  items[1] = revo_num(2.0);
  items[2] = revo_num(3.0);
  RevoData tp = revo_tuple_create(vm, 3, items);
  assert(revo_is_tuple(tp));
  assert(revo_tuple_len(vm, revo_tuple_id(tp)) == 3);
  tv = revo_tuple_get(vm, revo_tuple_id(tp), 0);
  assert(revo_is_number(tv));
  assert(fabs(revo_num_value(tv) - 1.0) < 1e-12);
  tv = revo_tuple_get(vm, revo_tuple_id(tp), 2);
  assert(revo_is_number(tv));
  assert(fabs(revo_num_value(tv) - 3.0) < 1e-12);
  OK;

  T("revo_tuple_get out of bounds returns nil");
  tv = revo_tuple_get(vm, revo_tuple_id(tp), 99);
  assert(revo_is_nil(tv));
  OK;

  T("revo_tuple_create with mixed types");
  {
    uint64_t s_id = revo_intern(vm, (uint64_t)(uintptr_t)"hi", 2);
    RevoData mix[3];
    mix[0] = revo_num(42.0);
    mix[1] = R_STRING(s_id);
    mix[2] = revo_atom_val(ra_true);
    RevoData tp2 = revo_tuple_create(vm, 3, mix);
    assert(revo_is_tuple(tp2));
    assert(revo_tuple_len(vm, revo_tuple_id(tp2)) == 3);
    tv = revo_tuple_get(vm, revo_tuple_id(tp2), 0);
    assert(revo_is_number(tv));
    assert(fabs(revo_num_value(tv) - 42.0) < 1e-12);
    tv = revo_tuple_get(vm, revo_tuple_id(tp2), 1);
    assert(revo_is_string(tv));
    assert(revo_string_length(vm, revo_string_id(tv)) == 2);
    assert(memcmp(revo_string_data(vm, revo_string_id(tv)), "hi", 2) == 0);
    tv = revo_tuple_get(vm, revo_tuple_id(tp2), 2);
    assert(revo_is_bool(tv));
    assert(revo_string_id(tv) == ra_true);
    OK;
  }

  //
  // helper macros and inline functions
  //
  T("revo_nil");
  assert(revo_is_nil(revo_nil()));
  OK;

  T("revo_bool");
  assert(revo_is_bool(revo_bool(1)));
  assert(revo_is_bool(revo_bool(0)));
  assert(revo_string_id(revo_bool(1)) == ra_true);
  assert(revo_string_id(revo_bool(0)) == ra_false);
  OK;

  T("revo_num");
  assert(revo_is_number(revo_num(42.0)));
  assert(fabs(revo_num_value(revo_num(42.0)) - 42.0) < 1e-12);
  assert(revo_is_number(revo_num(-1.5)));
  assert(fabs(revo_num_value(revo_num(-1.5)) + 1.5) < 1e-12);
  OK;

  T("revo_atom_val");
  assert(revo_is_atom(revo_atom_val(ra_ok)));
  assert(revo_string_id(revo_atom_val(ra_ok)) == ra_ok);
  OK;

  T("R_STRING macro");
  sid = revo_intern(vm, (uint64_t)(uintptr_t)"test-str", 8);
  val = R_STRING(sid);
  assert(revo_is_string(val));
  assert(revo_string_id(val) == sid);
  OK;

  //
  // type tag helpers
  //
  T("revo_is_number false on string");
  assert(!revo_is_number(R_STRING(sid)));
  OK;

  T("revo_is_string false on number");
  assert(!revo_is_string(revo_num(1)));
  OK;

  T("revo_is_atom false on number");
  assert(!revo_is_atom(revo_num(1)));
  OK;

  T("revo_is_table false on number");
  assert(!revo_is_table(revo_num(1)));
  OK;

  T("revo_is_bool false on nil");
  assert(!revo_is_bool(revo_nil()));
  OK;

  //
  // error handling
  //
  T("compile error sets last_error");
  ErevoProgram *bad = erevo_compile(vm, "bad", "1 + ");
  assert(bad == NULL);
  assert(strlen(erevo_vm_last_error(vm)) > 0);
  OK;

  T("run null program returns false");
  assert(!erevo_run(vm, NULL, &val));
  OK;

  //
  // eval with output
  //
  T("erevo_eval returns result");
  ok = erevo_eval(vm, "test", "40 + 2", &val);
  if (!ok)
    FAIL(erevo_vm_last_error(vm));
  assert(ok);
  assert(revo_is_number(val));
  assert(fabs(revo_num_value(val) - 42.0) < 1e-12);
  OK;

  T("erevo_eval nil vm returns false");
  assert(!erevo_eval(NULL, "test", "1", &val));
  OK;

  //
  // program lifecycle
  //
  T("erevo_program_destroy null is safe");
  erevo_program_destroy(NULL);
  OK;

  T("erevo_vm_destroy null is safe");
  erevo_vm_destroy(NULL);
  OK;

  T("erevo_vm_last_error null returns empty");
  assert(strcmp(erevo_vm_last_error(NULL), "") == 0);
  OK;

  //
  // cleanup
  //
  erevo_program_destroy(prog);
  erevo_vm_destroy(vm);

  puts(failed ? "\nsome tests FAILED" : "\nall tests passed");
  return failed;
}
