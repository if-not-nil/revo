//
// c extensions, for revo
// build: make extension   (produces extension.so on mac)
//
// the shared lib exports revo_bindings which import(".so") picks up
//
// values cross the boundary nanboxed: a RevoData is a u64. numbers are raw
// f64 bits, boxed values carry an intern id in the low 48 bits, never a
// pointer. read strings with revo_string_data / revo_string_length and
// create them with revo_intern + revo_string.
//

#include "revo.h"
#include <regex.h>
#include <stdlib.h>
#include <string.h>

static void greet_fn(void *vm, size_t argc, RevoData *argv, RevoData *out_result) {
  if (argc < 1 || !revo_is_string(argv[0])) {
    *out_result = revo_nil();
    return;
  }

  const char *name = (const char *)revo_string_data(vm, revo_string_id(argv[0]));
  size_t name_len = revo_string_length(vm, revo_string_id(argv[0]));

  // build "hello, <name>!" and intern it
  char buf[256];
  memcpy(buf, "hello, ", 7);
  memcpy(buf + 7, name, name_len);
  buf[7 + name_len] = '!';

  uint64_t sid = revo_intern(vm, (uint64_t)(uintptr_t)buf, 7 + name_len + 1);
  *out_result = revo_string(sid);
}

static void add_fn(void *vm, size_t argc, RevoData *argv, RevoData *out_result) {
  (void)vm;
  if (argc < 2 || !revo_is_number(argv[0]) || !revo_is_number(argv[1])) {
    *out_result = revo_nil();
    return;
  }
  *out_result = revo_num(revo_num_value(argv[0]) + revo_num_value(argv[1]));
}

static void echo_fn(void *vm, size_t argc, RevoData *argv, RevoData *out_result) {
  (void)vm;
  if (argc < 1 || !revo_is_string(argv[0])) {
    *out_result = revo_nil();
    return;
  }
  // string ids pass through as-is, no re-intern needed
  *out_result = revo_string(revo_string_id(argv[0]));
}

static void strlen_fn(void *vm, size_t argc, RevoData *argv, RevoData *out_result) {
  if (argc < 1 || !revo_is_string(argv[0])) {
    *out_result = revo_num(0);
    return;
  }
  *out_result = revo_num((double)revo_string_length(vm, revo_string_id(argv[0])));
}

static void concat_fn(void *vm, size_t argc, RevoData *argv, RevoData *out_result) {
  if (argc < 2 || !revo_is_table(argv[0]) || !revo_is_string(argv[1])) {
    *out_result = revo_nil();
    return;
  }
  uint64_t n = revo_table_alen(vm, argv[0]);
  const char *sep = (const char *)revo_string_data(vm, revo_string_id(argv[1]));
  size_t seplen = revo_string_length(vm, revo_string_id(argv[1]));

  // two passes: first sum the lengths (also validates elements), then fill
  size_t total = 1;
  for (size_t i = 0; i < n; i++) {
    RevoData el;
    if (!revo_table_get_idx(vm, argv[0], i, &el) || !revo_is_string(el)) {
      *out_result = revo_nil();
      return;
    }
    total += revo_string_length(vm, revo_string_id(el));
    if (i > 0) total += seplen;
  }
  if (total > 8192) {
    *out_result = revo_nil();
    return;
  }

  char *buf = (char *)malloc(total);
  if (!buf) {
    *out_result = revo_nil();
    return;
  }
  size_t off = 0;
  for (size_t i = 0; i < n; i++) {
    if (i > 0) {
      memcpy(buf + off, sep, seplen);
      off += seplen;
    }
    RevoData el;
    revo_table_get_idx(vm, argv[0], i, &el);
    size_t elen = revo_string_length(vm, revo_string_id(el));
    memcpy(buf + off, revo_string_data(vm, revo_string_id(el)), elen);
    off += elen;
  }
  buf[off] = '\0';

  uint64_t sid = revo_intern(vm, (uint64_t)(uintptr_t)buf, off);
  free(buf);
  *out_result = revo_string(sid);
}

static void typ_fn(void *vm, size_t argc, RevoData *argv, RevoData *out_result) {
  (void)vm;
  if (argc < 1) {
    *out_result = revo_nil();
    return;
  }
  *out_result = revo_num((double)revo_type(argv[0]));
}

static void regex_fn(void *vm, size_t argc, RevoData *argv, RevoData *out_result) {
  if (argc < 2 || !revo_is_string(argv[0]) || !revo_is_string(argv[1])) {
    *out_result = revo_bool(0);
    return;
  }

  // intern ids are slices without a nul terminator; copy for regcomp
  char pattern[256];
  char text[256];
  {
    const char *p = (const char *)revo_string_data(vm, revo_string_id(argv[0]));
    size_t plen = revo_string_length(vm, revo_string_id(argv[0]));
    if (plen >= sizeof(pattern)) {
      *out_result = revo_bool(0);
      return;
    }
    memcpy(pattern, p, plen);
    pattern[plen] = '\0';

    const char *t = (const char *)revo_string_data(vm, revo_string_id(argv[1]));
    size_t tlen = revo_string_length(vm, revo_string_id(argv[1]));
    if (tlen >= sizeof(text)) {
      *out_result = revo_bool(0);
      return;
    }
    memcpy(text, t, tlen);
    text[tlen] = '\0';
  }

  regex_t regex;
  if (regcomp(&regex, pattern, REG_EXTENDED | REG_NOSUB) != 0) {
    regfree(&regex);
    *out_result = revo_bool(0);
    return;
  }

  int match = regexec(&regex, text, 0, NULL, 0);
  regfree(&regex);

  *out_result = revo_bool(match == 0);
}

// the type interface lives in the sibling extension.d.rv manifest, not here.
// every binding lands in this module's table at import time
__attribute__((visibility("default"))) const RevoBinding revo_bindings[] = {
  {"greet", greet_fn},
  {"add", add_fn},
  {"echo", echo_fn},
  {"strlen", strlen_fn},
  {"typ", typ_fn},
  {"regex", regex_fn},
  {"concat", concat_fn},
  {NULL, NULL},
};