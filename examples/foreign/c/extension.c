//
// c extensions, for revo
// build: make extension   (produces extension.so on mac)
//
// the shared lib exports revo_bindings which import(".so") picks up
//
// boundary :nanboxed RevoValue (u64)
// . numbers are raw f64 bits
// . boxed carry tag + payload: intern id,
//   ptr bits for opaque
// strings- data/length to read, intern + string to make
// native state: opaque_new/ptr, caller owns
//

#include "revo.h"
#include <regex.h>
#include <stdlib.h>
#include <string.h>

static int greet_fn(void *vm, size_t argc, RevoValue *argv,
                    RevoValue *out_result) {
  if (argc < 1)
    return revo_c_err_arity(vm, argc, 1);
  if (!revo_is_string(argv[0]))
    return revo_c_err_type(vm, 0, "string", argv[0]);

  const char *name =
      (const char *)revo_string_data(vm, revo_string_id(argv[0]));
  size_t name_len = revo_string_length(vm, revo_string_id(argv[0]));

  // build "hello, <name>!" and intern it
  char buf[256];
  memcpy(buf, "hello, ", 7);
  memcpy(buf + 7, name, name_len);
  buf[7 + name_len] = '!';

  uint64_t sid = revo_intern(vm, buf, 7 + name_len + 1);
  *out_result = revo_string_val(sid);
  return REVO_OK;
}

static int add_fn(void *vm, size_t argc, RevoValue *argv, RevoValue *out_result) {
  if (argc < 2)
    return revo_c_err_arity(vm, argc, 2);
  if (!revo_is_number(argv[0]))
    return revo_c_err_type(vm, 0, "number", argv[0]);
  if (!revo_is_number(argv[1]))
    return revo_c_err_type(vm, 1, "number", argv[1]);
  *out_result = revo_num(revo_num_value(argv[0]) + revo_num_value(argv[1]));
  return REVO_OK;
}

static int echo_fn(void *vm, size_t argc, RevoValue *argv,
                   RevoValue *out_result) {
  if (argc < 1)
    return revo_c_err_arity(vm, argc, 1);
  if (!revo_is_string(argv[0]))
    return revo_c_err_type(vm, 0, "string", argv[0]);
  // string ids pass through as-is, no re-intern needed
  *out_result = revo_string_val(revo_string_id(argv[0]));
  return REVO_OK;
}

static int strlen_fn(void *vm, size_t argc, RevoValue *argv,
                     RevoValue *out_result) {
  if (argc < 1)
    return revo_c_err_arity(vm, argc, 1);
  if (!revo_is_string(argv[0]))
    return revo_c_err_type(vm, 0, "string", argv[0]);
  *out_result =
      revo_num((double)revo_string_length(vm, revo_string_id(argv[0])));
  return REVO_OK;
}

static int concat_fn(void *vm, size_t argc, RevoValue *argv,
                     RevoValue *out_result) {
  if (argc < 2)
    return revo_c_err_arity(vm, argc, 2);
  if (!revo_is_table(argv[0]))
    return revo_c_err_type(vm, 0, "table", argv[0]);
  if (!revo_is_string(argv[1]))
    return revo_c_err_type(vm, 1, "string", argv[1]);
  uint64_t n = revo_table_alen(vm, argv[0]);
  const char *sep = (const char *)revo_string_data(vm, revo_string_id(argv[1]));
  size_t seplen = revo_string_length(vm, revo_string_id(argv[1]));

  // two passes: first sum the lengths (also validates elements), then fill
  size_t total = 1;
  for (size_t i = 0; i < n; i++) {
    RevoValue el;
    if (!revo_table_get_idx(vm, argv[0], i, &el) || !revo_is_string(el)) {
      return revo_c_err_other(vm, "parts must be strings");
    }
    total += revo_string_length(vm, revo_string_id(el));
    if (i > 0)
      total += seplen;
  }
  if (total > 8192) {
    return revo_c_err_other(vm, "concat result too long");
  }

  char *buf = (char *)malloc(total);
  if (!buf) {
    return revo_c_err_other(vm, "out of memory");
  }
  size_t off = 0;
  for (size_t i = 0; i < n; i++) {
    if (i > 0) {
      memcpy(buf + off, sep, seplen);
      off += seplen;
    }
    RevoValue el;
    revo_table_get_idx(vm, argv[0], i, &el);
    size_t elen = revo_string_length(vm, revo_string_id(el));
    memcpy(buf + off, revo_string_data(vm, revo_string_id(el)), elen);
    off += elen;
  }
  buf[off] = '\0';

  uint64_t sid = revo_intern(vm, buf, off);
  free(buf);

  *out_result = revo_string_val(sid);
  return REVO_OK;
}

static int typ_fn(void *vm, size_t argc, RevoValue *argv, RevoValue *out_result) {
  (void)vm;
  if (argc < 1)
    return revo_c_err_arity(vm, argc, 1);
  *out_result = revo_num((double)revo_type(argv[0]));
  return REVO_OK;
}

static int regex_fn(void *vm, size_t argc, RevoValue *argv,
                    RevoValue *out_result) {
  if (argc < 2)
    return revo_c_err_arity(vm, argc, 2);
  if (!revo_is_string(argv[0]))
    return revo_c_err_type(vm, 0, "string", argv[0]);
  if (!revo_is_string(argv[1]))
    return revo_c_err_type(vm, 1, "string", argv[1]);

  // intern ids are slices without a nul terminator; copy for regcomp
  char pattern[256];
  char text[256];
  {
    const char *p = (const char *)revo_string_data(vm, revo_string_id(argv[0]));
    size_t plen = revo_string_length(vm, revo_string_id(argv[0]));
    if (plen >= sizeof(pattern)) {
      return revo_c_err_other(vm, "pattern too long");
    }
    memcpy(pattern, p, plen);
    pattern[plen] = '\0';

    const char *t = (const char *)revo_string_data(vm, revo_string_id(argv[1]));
    size_t tlen = revo_string_length(vm, revo_string_id(argv[1]));
    if (tlen >= sizeof(text)) {
      return revo_c_err_other(vm, "text too long");
    }
    memcpy(text, t, tlen);
    text[tlen] = '\0';
  }

  regex_t regex;
  if (regcomp(&regex, pattern, REG_EXTENDED | REG_NOSUB) != 0) {
    regfree(&regex);
    return revo_c_err_other(vm, "bad pattern");
  }

  int match = regexec(&regex, text, 0, NULL, 0);
  regfree(&regex);

  *out_result = revo_bool(match == 0);
  return REVO_OK;
}

// resource demo ::: an opaque native counter
// . revo holds the malloc'd struct in a gc cell and
// hands it back on each call; free it explicitly
typedef struct {
  double total;
} total_t;

static int total_new_fn(void *vm, size_t argc, RevoValue *argv,
                        RevoValue *out_result) {
  (void)argc;
  (void)argv;
  total_t *t = (total_t *)malloc(sizeof(total_t));
  if (!t) {
    return revo_c_err_other(vm, "out of memory");
  }
  t->total = 0;
  *out_result = revo_resource_new(vm, t);
  return REVO_OK;
}

static int total_add_fn(void *vm, size_t argc, RevoValue *argv,
                        RevoValue *out_result) {
  if (argc < 2)
    return revo_c_err_arity(vm, argc, 2);
  if (!revo_is_resource(argv[0]))
    return revo_c_err_type(vm, 0, "resource", argv[0]);
  if (!revo_is_number(argv[1]))
    return revo_c_err_type(vm, 1, "number", argv[1]);
  total_t *t = (total_t *)revo_resource_ptr(vm, argv[0]);
  if (!t) {
    return revo_c_err_other(vm, "null handle");
  }
  t->total += revo_num_value(argv[1]);
  *out_result = revo_num(t->total);
  return REVO_OK;
}

static int total_free_fn(void *vm, size_t argc, RevoValue *argv,
                         RevoValue *out_result) {
  if (argc >= 1 && revo_is_resource(argv[0])) {
    free(revo_resource_ptr(vm, argv[0]));
  }
  *out_result = revo_nil();
  return REVO_OK;
}

// every binding lands flat in the module table at import time
__attribute__((visibility("default"))) const RevoBinding revo_bindings[] = {
    {"greet", greet_fn},
    {"add", add_fn},
    {"echo", echo_fn},
    {"strlen", strlen_fn},
    {"typ", typ_fn},
    {"regex", regex_fn},
    {"concat", concat_fn},
    {"total_new", total_new_fn},
    {"total_add", total_add_fn},
    {"total_free", total_free_fn},
    {NULL, NULL},
};
