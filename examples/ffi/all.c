#include "../../revo.h"
#include <regex.h>
#include <string.h>

static RevoData make_string(void *vm, const char *str) {
  return (RevoData){
      .tag = revo_string,
      .value = revo_intern(vm, (uint64_t)(uintptr_t)str, strlen(str)),
  };
}

/// > echo(s) -> string
void echo(void *vm, size_t argc, RevoData *argv, RevoData *out_result) {
  if (argc < 1 || argv[0].tag != revo_string) {
    *out_result = revo_nil();
    return;
  }
  const char *str = (const char *)(uintptr_t)argv[0].value;
  *out_result = make_string(vm, str);
}

/// > strlen(s) -> number
void strlen_fn(void *vm, size_t argc, RevoData *argv, RevoData *out_result) {
  if (argc < 1 || argv[0].tag != revo_string) {
    *out_result = (RevoData){.tag = revo_number, .value = 0};
    return;
  }
  const char *str = (const char *)(uintptr_t)argv[0].value;
  double len = strlen(str);
  *out_result = (RevoData){.tag = revo_number, .value = *(uint64_t *)&len};
}

/// > add(a, b) -> number
void add(void *vm, size_t argc, RevoData *argv, RevoData *out_result) {
  if (argc < 2) {
    *out_result = (RevoData){.tag = revo_number, .value = 0};
    return;
  }
  double a = argv[0].tag == revo_number ? *(double *)&argv[0].value : 0;
  double b = argv[1].tag == revo_number ? *(double *)&argv[1].value : 0;
  double result = a + b;
  *out_result = (RevoData){.tag = revo_number, .value = *(uint64_t *)&result};
}

/// > type(x) -> number
/// returns type tag: 0=number, 1=string, 2=atom, etc
void type(void *vm, size_t argc, RevoData *argv, RevoData *out_result) {
  if (argc < 1) {
    *out_result = revo_nil();
    return;
  }
  double tag = (double)argv[0].tag;
  *out_result = (RevoData){.tag = revo_number, .value = *(uint64_t *)&tag};
}

/// > regex(pattern, text) -> number
/// returns 1 if pattern matches, 0 if not
void regex(void *vm, size_t argc, RevoData *argv, RevoData *out_result) {
  if (argc < 2 || argv[0].tag != revo_string || argv[1].tag != revo_string) {
    *out_result = (RevoData){.tag = revo_number, .value = 0};
    return;
  }
  const char *pattern = (const char *)(uintptr_t)argv[0].value;
  const char *text = (const char *)(uintptr_t)argv[1].value;

  regex_t regex;
  if (regcomp(&regex, pattern, REG_EXTENDED | REG_NOSUB) != 0) {
    regfree(&regex);
    *out_result = (RevoData){.tag = revo_number, .value = 0};
    return;
  }

  int match = regexec(&regex, text, 0, NULL, 0);
  regfree(&regex);

  double result = (match == 0) ? 1.0 : 0.0;
  *out_result = (RevoData){.tag = revo_number, .value = *(uint64_t *)&result};
}

__attribute__((visibility("default"))) const RevoBinding revo_bindings[] = {
    {"echo", echo}, {"strlen_fn", strlen_fn}, {"add", add},
    {"type", type}, {"regex", regex},         {((void *)0), ((void *)0)}};
