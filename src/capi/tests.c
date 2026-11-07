//
// c api test suite for revo
// compile and run with: zig build test-c
// or: cc -I zig-out/include/revo src/capi/tests.c zig-out/lib/liberevo.a -lm
// -o\
//         /tmp/revo-c-test && /tmp/revo-c-test
//

#include "revo.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#ifndef _WIN32
#include <unistd.h>
#endif

static int failed = 0;

#define FAIL(msg)                                                              \
  do {                                                                         \
    printf("FAIL: %s\n", msg);                                                 \
    failed = 1;                                                                \
  } while (0)

#define T(name)                                                                \
  for (int _t_done = (printf("  " name "... "), fflush(stdout), 0); !_t_done;  \
       _t_done = (printf("ok\n"), 1))

#define check(cond)                                                            \
  do {                                                                         \
    if (!(cond))                                                               \
      FAIL(erevo_vm_last_error(vm));                                           \
    assert(cond);                                                              \
  } while (0)

static int test_double_fn(void *vm, size_t argc, RevoValue *argv,
                          RevoValue *out) {
  if (argc < 1)
    return revo_c_err_arity(vm, argc, 1);

  if (!revo_is_number(argv[0]))
    return revo_c_err_type(vm, 0, "number", argv[0]);

  *out = revo_num(revo_num_value(argv[0]) * 2);
  return REVO_OK;
}

int main(int argc, char **argv) {
  puts("c api tests");

  ErevoVM *vm;
  ErevoProgram *prog;
  ErevoValue val;
  int ok;
  uint64_t sid;
  RevoValue tval;
  RevoValue t;
  int call_ok;
  RevoValue call_result;

  T("vm create") {
    vm = erevo_vm_create();
    assert(vm && "vm should not be null");
  }

  T("compile and run 1 + 2") {
    prog = erevo_compile(vm, "test", "1 + 2");
    check(prog);
    ok = erevo_run(vm, prog, &val);
    check(ok);

    assert(revo_is_number(val));
    assert(fabs(revo_num_value(val) - 3.0) < 1e-12);
  }

  T("compile and run string literal") {
    ok = erevo_eval(vm, "test", "\"hello\"", &val);
    check(ok);

    assert(revo_is_string(val));
    sid = revo_string_id(val);
    assert(revo_string_length(vm, sid) == 5);
    assert(memcmp(revo_string_data(vm, sid), "hello", 5) == 0);
  }

  T("compile and run bool true") {
    ok = erevo_eval(vm, "test", ":true", &val);
    check(ok);

    assert(revo_is_bool(val));
    assert(revo_string_id(val) == ra_true);
  }

  T("compile and run bool false") {
    ok = erevo_eval(vm, "test", ":false", &val);
    check(ok);

    assert(revo_is_bool(val));
    assert(revo_string_id(val) == ra_false);
  }

  T("compile and run :nil") {
    ok = erevo_eval(vm, "test", ":nil", &val);
    check(ok);

    assert(revo_is_nil(val));
  }

  T("compile and run atom :ok") {
    ok = erevo_eval(vm, "test", ":ok", &val);
    check(ok);

    assert(revo_is_atom(val));
    assert(revo_string_id(val) == ra_ok);
  }

  T("compile and run table literal") {
    ok = erevo_eval(vm, "test", "{a = 1}", &val);
    check(ok);

    assert(revo_is_table(val));
  }

  T("set and get global") {
    revo_setglobal(vm, "pi", 2, revo_num(3.14));
    val = revo_getglobal(vm, "pi", 2);

    assert(revo_is_number(val));
    assert(fabs(revo_num_value(val) - 3.14) < 1e-12);
  }

  T("get missing global returns nil") {
    val = revo_getglobal(vm, "nope", 4);

    assert(revo_is_nil(val));
  }

  T("intern and read back string") {
    sid = revo_intern(vm, "world", 5);
    assert(sid != 0);
    assert(revo_string_length(vm, sid) == 5);
    assert(memcmp(revo_string_data(vm, sid), "world", 5) == 0);
  }

  T("intern atom") {
    uint64_t aid = revo_intern_atom(vm, "hello", 5);

    assert(aid != 0);
  }

  //
  // table
  //
  T("create table via eval, read field from c") {
    ok = erevo_eval(vm, "test", "do let t = {} t.x = 42 t end", &val);
    check(ok);
    assert(revo_is_table(val));

    assert(revo_table_get_name(vm, val, "x", 1, &tval));
    assert(revo_is_number(tval));
    assert(fabs(revo_num_value(tval) - 42.0) < 1e-12);
  }

  T("table_set and table_get round-trip") {
    uint64_t x_atom = revo_intern_atom(vm, "x", 1);

    assert(revo_table_set(vm, val, revo_atom_val(x_atom), revo_num(99.0)));
    assert(revo_table_get(vm, val, revo_atom_val(x_atom), &tval));
    assert(revo_is_number(tval));
    assert(fabs(revo_num_value(tval) - 99.0) < 1e-12);
  }

  T("table_get missing key returns false") {
    uint64_t y_atom = revo_intern_atom(vm, "y", 1);

    assert(!revo_table_get(vm, val, revo_atom_val(y_atom), &tval));
    assert(!revo_table_get_name(vm, val, "y", 1, &tval));
  }

  T("revo_table_create returns empty table") {
    t = revo_table_create(vm);

    assert(revo_is_table(t));
    assert(revo_table_len(vm, t) == 0);
    assert(revo_table_alen(vm, t) == 0);
  }

  T("revo_table_create set and get fields") {
    uint64_t a_atom = revo_intern_atom(vm, "a", 1);
    uint64_t b_atom = revo_intern_atom(vm, "b", 1);

    assert(revo_table_set_name(vm, t, "a", 1, revo_num(10.0)));
    assert(revo_table_set(vm, t, revo_atom_val(b_atom), revo_num(20.0)));

    assert(revo_table_len(vm, t) == 2);
    assert(revo_table_get(vm, t, revo_atom_val(a_atom), &tval));
    assert(revo_is_number(tval));
    assert(fabs(revo_num_value(tval) - 10.0) < 1e-12);
    assert(revo_table_get(vm, t, revo_atom_val(b_atom), &tval));
    assert(revo_is_number(tval));
    assert(fabs(revo_num_value(tval) - 20.0) < 1e-12);
  }

  T("revo_table_from_items builds array tables") {
    RevoValue items[3] = {revo_num(1.0), revo_num(2.0), revo_num(3.0)};
    RevoValue arr = revo_table_from_items(vm, 3, items);

    assert(revo_is_table(arr));
    assert(revo_table_len(vm, arr) == 3);
    assert(revo_table_alen(vm, arr) == 3);
    assert(revo_table_get_idx(vm, arr, 1, &tval));
    assert(fabs(revo_num_value(tval) - 2.0) < 1e-12);
    assert(!revo_table_get_idx(vm, arr, 3, &tval));
    assert(revo_table_push(vm, arr, revo_num(4.0)));
    assert(revo_table_alen(vm, arr) == 4);
  }

  T("result helpers classify {:ok}/{:err} tables") {
    RevoValue pok = revo_ok(vm, revo_num(1.0));
    RevoValue perr = revo_err(vm, revo_atom_val(ra_ok));

    assert(revo_is_ok(vm, pok));
    assert(!revo_is_err(vm, pok));
    assert(revo_is_err(vm, perr));
    assert(!revo_is_ok(vm, perr));
    assert(!revo_is_ok(vm, revo_num(1.0)));
    assert(revo_ok_value(vm, pok, &tval));
    assert(fabs(revo_num_value(tval) - 1.0) < 1e-12);
    assert(!revo_ok_value(vm, perr, &tval));
  }

  //
  // revo_table_remove
  //
  T("revo_table_remove removes by key") {
    RevoValue rt = revo_table_create(vm);
    RevoValue rk = revo_atom_val(ra_ok);

    assert(revo_table_set(vm, rt, rk, revo_num(42.0)));
    assert(revo_table_get(vm, rt, rk, &tval));
    assert(revo_is_number(tval));
    int removed = revo_table_remove(vm, rt, rk);
    assert(removed);
    assert(!revo_table_get(vm, rt, rk, &tval));
    // second remove returns false
    assert(!revo_table_remove(vm, rt, rk));
  }

  T("revo_table_remove integer key from array") {
    ok = erevo_eval(vm, "test", "{10, 20, 30}", &val);
    check(ok);
    assert(revo_is_table(val));
    assert(revo_table_len(vm, val) == 3);
    int removed = revo_table_remove(vm, val, revo_num(0.0));
    assert(removed);
    assert(revo_table_len(vm, val) ==
           2); // integer keys compact via orderedRemove
    assert(revo_table_get_idx(vm, val, 0, &tval));
    assert(revo_num_value(tval) == 20.0);
  }

  T("revo_table_remove missing key") {
    RevoValue rt = revo_table_create(vm);

    assert(!revo_table_remove(vm, rt, revo_num(99.0)));
  }

  //
  // revo_call
  //
  T("revo_call a compiled function") {
    ok = erevo_eval(vm, "test", "fn(x) x + 1", &val);
    check(ok);
    assert(revo_is_function(val));

    RevoValue call_args[1] = {revo_num(41.0)};
    call_ok = revo_call(vm, val, 1, call_args, &call_result);

    assert(call_ok);
    assert(revo_is_number(call_result));
    assert(fabs(revo_num_value(call_result) - 42.0) < 1e-12);
  }

  T("revo_call with no args") {
    ok = erevo_eval(vm, "test", "fn() 99", &val);
    check(ok);

    call_ok = revo_call(vm, val, 0, NULL, &call_result);

    assert(call_ok);
    assert(revo_is_number(call_result));
    assert(fabs(revo_num_value(call_result) - 99.0) < 1e-12);
  }

  T("revo_call returning string") {
    ok = erevo_eval(vm, "test", "fn() \"hello\"", &val);
    check(ok);

    call_ok = revo_call(vm, val, 0, NULL, &call_result);

    assert(call_ok);
    assert(revo_is_string(call_result));
    assert(revo_string_length(vm, revo_string_id(call_result)) == 5);
    assert(memcmp(revo_string_data(vm, revo_string_id(call_result)), "hello",
                  5) == 0);
  }

  T("revo_call returning multi-word string") {
    ok = erevo_eval(vm, "test", "fn() \"hello from c\"", &val);
    check(ok);

    call_ok = revo_call(vm, val, 0, NULL, &call_result);

    assert(call_ok);
    assert(revo_is_string(call_result));
    assert(revo_string_length(vm, revo_string_id(call_result)) == 12);
    assert(memcmp(revo_string_data(vm, revo_string_id(call_result)),
                  "hello from c", 12) == 0);
  }

  T("revo_call multiple args") {
    ok = erevo_eval(vm, "test", "fn(a, b, c) a + b * c", &val);
    check(ok);

    RevoValue multi_args[3] = {revo_num(10.0), revo_num(3.0), revo_num(4.0)};
    call_ok = revo_call(vm, val, 3, multi_args, &call_result);

    assert(call_ok);
    assert(revo_is_number(call_result));
    assert(fabs(revo_num_value(call_result) - 22.0) < 1e-12);
  }

  T("revo_call non-function returns false") {
    call_ok = revo_call(vm, revo_num(42.0), 0, NULL, &call_result);

    assert(!call_ok);
  }

  T("revo_cfunc_new registers a callable c function") {
    RevoValue cfn = revo_cfunc_new(vm, (void *)test_double_fn, "double", 6);
    assert(revo_is_function(cfn));

    RevoValue dargs[1] = {revo_num(21.0)};
    call_ok = revo_call(vm, cfn, 1, dargs, &call_result);
    assert(call_ok);
    assert(revo_is_number(call_result));
    assert(fabs(revo_num_value(call_result) - 42.0) < 1e-12);

    // reachable from revo too
    revo_setglobal_cstr(vm, "c_double", cfn);
    ok = erevo_eval(vm, "test", "c_double(21)", &val);
    check(ok);
    assert(revo_is_number(val));
    assert(fabs(revo_num_value(val) - 42.0) < 1e-12);

    // empty name works, null fn gives nil
    assert(
        revo_is_function(revo_cfunc_new(vm, (void *)test_double_fn, NULL, 0)));
    assert(revo_is_nil(revo_cfunc_new(vm, NULL, NULL, 0)));
  }

  //
  // c-string convenience wrappers
  //
  T("revo_getglobal_cstr") {
    revo_setglobal_cstr(vm, "abc", revo_num(123.0));
    RevoValue gv = revo_getglobal_cstr(vm, "abc");

    assert(revo_is_number(gv));
    assert(fabs(revo_num_value(gv) - 123.0) < 1e-12);
    // missing key returns nil
    gv = revo_getglobal_cstr(vm, "does-not-exist");
    assert(revo_is_nil(gv));
  }

  T("revo_atom_id") {
    RevoValue atom_val = revo_atom_val(ra_ok);

    assert(revo_atom_id(atom_val) == ra_ok);
    assert(revo_atom_id(revo_bool(1)) == ra_true);
  }

  //
  // helper macros and inline functions
  //
  T("revo_nil") { assert(revo_is_nil(revo_nil())); }

  T("revo_bool") {
    assert(revo_is_bool(revo_bool(1)));
    assert(revo_is_bool(revo_bool(0)));
    assert(revo_string_id(revo_bool(1)) == ra_true);
    assert(revo_string_id(revo_bool(0)) == ra_false);
  }

  T("revo_num") {
    assert(revo_is_number(revo_num(42.0)));
    assert(fabs(revo_num_value(revo_num(42.0)) - 42.0) < 1e-12);
    assert(revo_is_number(revo_num(-1.5)));
    assert(fabs(revo_num_value(revo_num(-1.5)) + 1.5) < 1e-12);
  }

  T("revo_atom_val") {
    assert(revo_is_atom(revo_atom_val(ra_ok)));
    assert(revo_string_id(revo_atom_val(ra_ok)) == ra_ok);
  }

  T("revo_string macro") {
    sid = revo_intern(vm, "test-str", 8);
    val = revo_string_val(sid);

    assert(revo_is_string(val));
    assert(revo_string_id(val) == sid);
  }

  //
  // type tag helpers
  //
  T("revo_is_number false on string") {
    assert(!revo_is_number(revo_string_val(sid)));
  }

  T("revo_is_string false on number") { assert(!revo_is_string(revo_num(1))); }

  T("revo_is_atom false on number") { assert(!revo_is_atom(revo_num(1))); }

  T("revo_is_table false on number") { assert(!revo_is_table(revo_num(1))); }

  T("revo_is_bool false on nil") { assert(!revo_is_bool(revo_nil())); }

  T("revo_type") {
    assert(revo_type(revo_num(1)) == revo_number);
    assert(revo_type(revo_string_val(sid)) == revo_string);
    assert(revo_type(revo_atom_val(ra_ok)) == revo_atom);
    assert(revo_type(revo_table_val(t)) == revo_table);
  }

  T("revo_bool_val") {
    assert(revo_bool_val(revo_bool(1)) == 1);
    assert(revo_bool_val(revo_bool(0)) == 0);
    assert(revo_bool_val(revo_num(1.0)) == 0); // not a bool
    assert(revo_bool_val(revo_nil()) == 0);
  }

  T("revo_type opaque tag") {
    int marker = 1234;
    RevoValue f = revo_opaque_new(&marker);
    assert(revo_type(f) == revo_opaque);
    assert(revo_opaque == 13);
  }

  T("opaque wrap and unwrap round-trip") {
    int marker = 42;
    RevoValue f = revo_opaque_new(&marker);
    assert(revo_is_opaque(f));
    assert(!revo_is_number(f));
    assert(!revo_is_string(f));
    assert(!revo_is_atom(f));
    assert(!revo_is_table(f));
    assert(!revo_is_function(f));
    assert(!revo_is_nil(f));
    assert(revo_opaque_ptr(f) == &marker);
  }

  T("opaque null needs is_opaque to disambiguate") {
    RevoValue null_opaque = revo_opaque_new(NULL);
    assert(revo_is_opaque(null_opaque));
    assert(revo_opaque_ptr(null_opaque) == NULL);
    assert(revo_opaque_ptr(revo_num(1.0)) == NULL);
    assert(!revo_is_opaque(revo_num(1.0)));
    assert(revo_opaque_ptr(revo_nil()) == NULL);
    assert(!revo_is_opaque(revo_nil()));
  }

  T("opaque survives globals, tables, and calls") {
    static int state = 7;
    RevoValue f = revo_opaque_new(&state);

    revo_setglobal_cstr(vm, "c_opaque", f);
    RevoValue back = revo_getglobal_cstr(vm, "c_opaque");
    assert(revo_is_opaque(back));
    assert(revo_opaque_ptr(back) == &state);

    RevoValue ft = revo_table_create(vm);
    assert(revo_table_set_name(vm, ft, "ptr", 3, f));
    assert(revo_table_get_name(vm, ft, "ptr", 3, &tval));
    assert(revo_is_opaque(tval));
    assert(revo_opaque_ptr(tval) == &state);

    ok = erevo_eval(vm, "test", "fn(x) x", &val);
    check(ok);
    RevoValue farg[1] = {f};
    call_ok = revo_call(vm, val, 1, farg, &call_result);
    assert(call_ok);
    assert(revo_is_opaque(call_result));
    assert(revo_opaque_ptr(call_result) == &state);
  }

  T("revo_ref pins values across gc") {
    RevoValue rt = revo_table_create(vm);
    assert(revo_table_set_name(vm, rt, "v", 1, revo_num(7.0)));
    uint64_t r = revo_ref(vm, rt);
    assert(r != 0);
    assert(revo_ref(vm, revo_nil()) == 0);

    // force collections
    for (int i = 0; i < 5000; i++) {
      ok = erevo_eval(vm, "test", "{1, 2, 3, 4, 5, 6, 7, 8, 9, 10}", &tval);
      check(ok);
    }

    RevoValue pinned = revo_getref(vm, r);
    assert(revo_is_table(pinned));
    assert(revo_table_get_name(vm, pinned, "v", 1, &tval));
    assert(revo_is_number(tval));
    assert(fabs(revo_num_value(tval) - 7.0) < 1e-12);

    revo_unref(vm, r);
    assert(revo_is_nil(revo_getref(vm, r)));
    assert(revo_is_nil(revo_getref(vm, 0)));
    assert(revo_is_nil(revo_getref(vm, 999999)));
    revo_unref(vm, 0);
    revo_unref(vm, 999999);
  }

  T("table finalizer runs on sweep") {
    // finalizer closing over the flag table
    ok = erevo_eval(vm, "test", "fn(flag) fn(t) do flag.hit = 41 t end", &val);
    check(ok);
    assert(revo_is_function(val));

    RevoValue flag = revo_table_create(vm);
    assert(revo_table_set_name(vm, flag, "hit", 3, revo_num(0.0)));
    RevoValue fargs[1] = {flag};
    RevoValue fin_fn;
    call_ok = revo_call(vm, val, 1, fargs, &fin_fn);
    assert(call_ok);
    assert(revo_is_function(fin_fn));
    // pin the finalizer
    uint64_t fin_ref = revo_ref(vm, fin_fn);
    assert(fin_ref != 0);

    RevoValue doomed = revo_table_create(vm);
    assert(revo_table_set_finalizer(vm, doomed, fin_fn));
    assert(!revo_table_set_finalizer(vm, revo_num(1.0), fin_fn));
    assert(!revo_table_set_finalizer(vm, doomed, revo_num(1.0)));
    assert(revo_table_remove_finalizer(vm, doomed));
    assert(!revo_table_remove_finalizer(vm, doomed));
    assert(!revo_table_remove_finalizer(vm, revo_num(1.0)));
    assert(revo_table_set_finalizer(vm, doomed, fin_fn)); // re-arm

    // doomed is c-local only; churn sweeps it
    for (int i = 0; i < 5000; i++) {
      ok = erevo_eval(vm, "test", "{1, 2, 3, 4, 5, 6, 7, 8, 9, 10}", &tval);
      check(ok);
    }

    assert(revo_table_get_name(vm, flag, "hit", 3, &tval));
    assert(revo_is_number(tval));
    assert(fabs(revo_num_value(tval) - 41.0) < 1e-12);
    revo_unref(vm, fin_ref);
  }

  T("revo_type resource tag") {
    int marker = 5;
    RevoValue e = revo_resource_new(vm, &marker);
    assert(revo_type(e) == revo_resource);
    assert(revo_resource == 12);
    assert(revo_is_resource(e));
    assert(!revo_is_opaque(e));
    assert(!revo_is_table(e));
    assert(revo_resource_ptr(vm, e) == &marker);
    assert(revo_resource_ptr(vm, revo_num(1.0)) == NULL);
    assert(!revo_is_resource(revo_num(1.0)));
  }

  T("resource metatables attach and read back") {
    int marker = 6;
    RevoValue e = revo_resource_new(vm, &marker);
    RevoValue mt = revo_table_create(vm);
    RevoValue got;
    assert(!revo_resource_getmetatable(vm, e, &got));
    assert(revo_resource_setmetatable(vm, e, mt));
    assert(revo_resource_getmetatable(vm, e, &got));
    assert(revo_is_table(got));
    assert(revo_table_id(got) == revo_table_id(mt));
    assert(!revo_resource_setmetatable(vm, revo_num(1.0), mt));
    assert(!revo_resource_setmetatable(vm, e, revo_num(1.0)));
    assert(revo_resource_setmetatable(vm, e, revo_nil()));
    assert(!revo_resource_getmetatable(vm, e, &got));
  }

  T("resource methods dispatch through the metatable") {
    ok = erevo_eval(vm, "test", "fn(self) 42", &val);
    check(ok);
    uint64_t who_ref = revo_ref(vm, val);
    assert(who_ref != 0);

    RevoValue methods = revo_table_create(vm);
    uint64_t methods_ref = revo_ref(vm, methods);
    assert(methods_ref != 0);
    assert(revo_table_set_name(vm, methods, "who", 3, val));

    RevoValue emt = revo_table_create(vm);
    uint64_t emt_ref = revo_ref(vm, emt);
    assert(emt_ref != 0);
    assert(revo_table_set_name(vm, emt, "__index", 7, methods));

    int mstate = 3;
    RevoValue mu = revo_resource_new(vm, &mstate);
    uint64_t mu_ref = revo_ref(vm, mu);
    assert(mu_ref != 0);
    assert(revo_resource_setmetatable(vm, mu, emt));

    ok = erevo_eval(vm, "test", "fn(u) u:who()", &val);
    check(ok);
    RevoValue margs[1] = {mu};
    call_ok = revo_call(vm, val, 1, margs, &call_result);
    assert(call_ok);
    assert(revo_is_number(call_result));
    assert(fabs(revo_num_value(call_result) - 42.0) < 1e-12);

    revo_unref(vm, who_ref);
    revo_unref(vm, methods_ref);
    revo_unref(vm, emt_ref);
    revo_unref(vm, mu_ref);
  }

  T("resource __gc runs once on sweep") {
    ok = erevo_eval(vm, "test",
                    "fn(flag) fn(t) do flag.hit = flag.hit + 1 t end", &val);
    check(ok);
    RevoValue eflag = revo_table_create(vm);
    assert(revo_table_set_name(vm, eflag, "hit", 3, revo_num(0.0)));
    RevoValue gargs[1] = {eflag};
    RevoValue gc_fn;
    call_ok = revo_call(vm, val, 1, gargs, &gc_fn);
    assert(call_ok);
    uint64_t gc_ref = revo_ref(vm, gc_fn);
    assert(gc_ref != 0);
    uint64_t eflag_ref = revo_ref(vm, eflag);
    assert(eflag_ref != 0);

    RevoValue emt = revo_table_create(vm);
    uint64_t emt_ref = revo_ref(vm, emt);
    assert(emt_ref != 0);
    assert(revo_table_set_name(vm, emt, "__gc", 4, gc_fn));

    int estate = 9;
    RevoValue doom = revo_resource_new(vm, &estate);
    assert(revo_resource_setmetatable(vm, doom, emt));

    for (int i = 0; i < 5000; i++) {
      ok = erevo_eval(vm, "test", "{1, 2, 3, 4, 5, 6, 7, 8, 9, 10}", &tval);
      check(ok);
    }
    assert(revo_table_get_name(vm, eflag, "hit", 3, &tval));
    assert(fabs(revo_num_value(tval) - 1.0) < 1e-12);

    // one-shot: second storm, no re-run
    for (int i = 0; i < 5000; i++) {
      ok = erevo_eval(vm, "test", "{1, 2, 3, 4, 5, 6, 7, 8, 9, 10}", &tval);
      check(ok);
    }
    assert(revo_table_get_name(vm, eflag, "hit", 3, &tval));
    assert(fabs(revo_num_value(tval) - 1.0) < 1e-12);

    revo_unref(vm, gc_ref);
    revo_unref(vm, eflag_ref);
    revo_unref(vm, emt_ref);
  }

  //
  // error handling
  //
  T("compile error sets last_error") {
    ErevoProgram *bad = erevo_compile(vm, "bad", "1 + ");

    assert(bad == NULL);
    assert(strlen(erevo_vm_last_error(vm)) > 0);
  }

  T("run null program returns false") { assert(!erevo_run(vm, NULL, &val)); }

  //
  // eval with output
  //
  T("erevo_eval returns result") {
    ok = erevo_eval(vm, "test", "40 + 2", &val);
    check(ok);

    assert(revo_is_number(val));
    assert(fabs(revo_num_value(val) - 42.0) < 1e-12);
  }

  T("erevo_eval nil vm returns false") {
    assert(!erevo_eval(NULL, "test", "1", &val));
  }

  //
  // program lifecycle
  //
  T("erevo_program_destroy null is safe") { erevo_program_destroy(NULL); }

  T("erevo_vm_destroy null is safe") { erevo_vm_destroy(NULL); }

  T("erevo_vm_last_error null returns empty") {
    assert(strcmp(erevo_vm_last_error(NULL), "") == 0);
  }

  //
  // cfn errors end to end (needs the test .so path as argv[1];
  // skipped when built standalone)
  //
  if (argc > 1) {
    T("revo.dload test extension") {
      char src[4096];
      snprintf(src, sizeof(src), "revo.dload(\"%s\")", argv[1]);
      ok = erevo_eval(vm, "test", src, &val);
      check(ok);
      assert(revo_is_table(val));
      revo_setglobal_cstr(vm, "tmod", val);
    }

    T("cfn ok path through the .so") {
      ok = erevo_eval(vm, "test", "tmod.add(3, 4)", &val);
      check(ok);
      assert(revo_is_number(val));
      assert(fabs(revo_num_value(val) - 7.0) < 1e-12);
    }

    T("cfn arity error fails eval with message") {
      ok = erevo_eval(vm, "test", "tmod.add(1)", &val);
      assert(!ok);
      assert(strlen(erevo_vm_last_error(vm)) > 0);
    }

    T("cfn type error fails eval with message") {
      ok = erevo_eval(vm, "test", "tmod.add(1, \"x\")", &val);
      assert(!ok);
      assert(strlen(erevo_vm_last_error(vm)) > 0);
    }

    T("cfn other error fails eval with message") {
      ok = erevo_eval(vm, "test", "tmod.concat({1}, \"-\")", &val);
      assert(!ok);
      assert(strlen(erevo_vm_last_error(vm)) > 0);
    }

#ifndef _WIN32
    T("revo.dload types through a wrapper module") {
      char dir[] = "/tmp/revo-dload-XXXXXX";
      assert(mkdtemp(dir) != NULL);
      char lib[4096];
      assert(realpath(argv[1], lib) != NULL);

      char wrapper[4200];
      snprintf(wrapper, sizeof(wrapper), "%s/wrapper.rv", dir);
      FILE *f = fopen(wrapper, "w");
      assert(f != NULL);
      fprintf(f,
              "const t: {\n  add: fn(a: number, b: number) -> number,\n} = "
              "revo.dload(\"%s\")\n\nreturn t\n",
              lib);
      fclose(f);
      char main_name[4200];
      snprintf(main_name, sizeof(main_name), "%s/main.rv", dir);

      ok = erevo_eval(vm, main_name, "import(\"./wrapper\").add(3, 4)", &val);
      check(ok);
      assert(revo_is_number(val));
      assert(fabs(revo_num_value(val) - 7.0) < 1e-12);

      // the bindings type is the modules type
      // , so this canr to compile
      ok = erevo_eval(vm, main_name, "import(\"./wrapper\").add(\"x\", 4)",
                      &val);
      assert(!ok);
      assert(strstr(erevo_vm_last_error(vm), "wants number") != NULL);

      remove(wrapper);
      rmdir(dir);
    }
#endif

    T("revo_call errors land in last_error") {
      RevoValue tmod = revo_getglobal_cstr(vm, "tmod");
      assert(revo_is_table(tmod));
      RevoValue add_fn;
      assert(revo_table_get_name(vm, tmod, "add", 3, &add_fn));
      assert(revo_is_function(add_fn));

      RevoValue one_arg[1] = {revo_num(1.0)};
      assert(!revo_call(vm, add_fn, 1, one_arg, &call_result));
      assert(strstr(revo_call_last_error(vm), "wants 2 args, got 1") != NULL);

      RevoValue call_ok_args[2] = {revo_num(3.0), revo_num(4.0)};
      assert(revo_call(vm, add_fn, 2, call_ok_args, &call_result));
      assert(fabs(revo_num_value(call_result) - 7.0) < 1e-12);
      assert(strcmp(revo_call_last_error(vm), "") == 0);
    }
  }

  //
  // ffi e2e through eval (needs the fixture .so path as argv[2])
  //
  if (argc > 2) {
    T("ffi calls plain c through decls") {
      char src[4096];
      snprintf(src, sizeof(src), "ffi.load(\"%s\")", argv[2]);
      ok = erevo_eval(vm, "test", src, &val);
      check(ok);
      revo_setglobal_cstr(vm, "flib", val);

      ok = erevo_eval(vm, "test",
                      "ffi.func(flib, \"ffi_test_add\", :i32, {:i32, :i32})",
                      &val);
      check(ok);
      revo_setglobal_cstr(vm, "fadd", val);

      ok = erevo_eval(vm, "test", "fadd(30, 12)", &val);
      check(ok);
      assert(revo_is_number(val));
      assert(fabs(revo_num_value(val) - 42.0) < 1e-12);
    }

    T("ffi decl errors fail with messages") {
      ok = erevo_eval(vm, "test",
                      "ffi.func(flib, \"ffi_test_add\", :nope, {:i32})", &val);
      assert(!ok);
      assert(strlen(erevo_vm_last_error(vm)) > 0);

      ok = erevo_eval(vm, "test", "ffi.func(flib, \"missing_sym\", :i32, {})",
                      &val);
      assert(!ok);
      assert(strlen(erevo_vm_last_error(vm)) > 0);
    }

    T("ffi call errors fail with messages") {
      ok = erevo_eval(vm, "test", "fadd(1)", &val);
      assert(!ok);
      assert(strlen(erevo_vm_last_error(vm)) > 0);

      ok = erevo_eval(vm, "test", "fadd(\"x\", 1)", &val);
      assert(!ok);
      assert(strlen(erevo_vm_last_error(vm)) > 0);
    }

    T("ffi errno reads back") {
      ok = erevo_eval(vm, "test", "ffi.func(flib, \"ffi_test_fail\", :i32, {})",
                      &val);
      check(ok);
      revo_setglobal_cstr(vm, "ffail", val);

      ok = erevo_eval(vm, "test", "ffail()", &val);
      check(ok);
      assert(fabs(revo_num_value(val) + 1.0) < 1e-12);

      ok = erevo_eval(vm, "test", "ffi.errno()", &val);
      check(ok);
      assert(fabs(revo_num_value(val) - 22.0) < 1e-12);
    }
  }

  //
  // cleanup
  //
  erevo_program_destroy(prog);
  erevo_vm_destroy(vm);

  puts(failed ? "\nsome tests FAILED" : "\nall tests passed");
  return failed;
}
