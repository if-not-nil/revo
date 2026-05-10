// this file, revo.h is public domain.
#ifndef REVO_FFI_H
#define REVO_FFI_H

#include <stddef.h>
#include <stdint.h>

typedef struct {
  uint64_t tag;
  uint64_t value;
} RevoData;

typedef enum {
  revo_number = 0,
  revo_string,
  revo_atom,
  revo_function,
  revo_table,
  revo_tuple,
} RevoType;

typedef enum {
  ra_nil,
  ra_missing,
  ra_undef,
  ra_none,
  ra_no_result,
  ra_false,
  ra_true,
  ra_range,
  ra_ok,
  ra_err,
  ra_some,
} RevoAtom;

#define revo_nil()                                                             \
  (RevoData) { .tag = revo_atom, .value = ra_nil }
#define revo_bool(v)                                                           \
  (RevoData) { .tag = revo_atom, .value = v ? ra_true : ra_false }
#define revo_ok()                                                              \
  (RevoData) { .tag = revo_atom, .value = ra_ok }

typedef void (*RevoFn)(void *vm, size_t argc, RevoData *argv,
                       RevoData *out_result);

typedef struct {
  const char *name;
  RevoFn fn;
} RevoBinding;
#define REVO_BINDINGS_END {NULL, NULL}

// intern a string into revo's string pool
// ptr must stay valid for the duration of the call
uint64_t revo_intern(void *vm, uint64_t ptr, size_t len);

#define R_STRING(id)                                                           \
  (RevoData) { .tag = revo_string, .value = id }

RevoData revo_getglobal(void *vm, uint64_t name_ptr, size_t name_len);

void revo_setglobal(void *vm, uint64_t name_ptr, size_t name_len,
                    RevoData value);

RevoData revo_table_get(void *vm, uint64_t table_id, RevoData key);

void revo_table_set(void *vm, uint64_t table_id, RevoData key, RevoData value);

#define R_EXPORT(...)                                                          \
  __attribute__((visibility("default")))                                       \
  const RevoBinding revo_bindings[] = {__VA_ARGS__, {NULL, NULL}};

#define R_SIG(fname)                                                           \
  void fname(void *vm, size_t argc, RevoData *argv, RevoData *out_result)

// erevo is the small embedding api
// these are opaque handles on purpose
typedef struct ErevoVM ErevoVM;
typedef struct ErevoProgram ErevoProgram;
typedef RevoData ErevoData;
typedef RevoType ErevoType;

// create and destroy a vm
ErevoVM *erevo_vm_create(void);
void erevo_vm_destroy(ErevoVM *vm);

// last error message on a vm, or null
const char *erevo_vm_last_error(ErevoVM *vm);

// compile a source string into a program
ErevoProgram *erevo_compile(ErevoVM *vm, const char *name, const char *source);
void erevo_program_destroy(ErevoProgram *program);

// run a compiled program or a source string
int erevo_run(ErevoVM *vm, ErevoProgram *program, ErevoData *out_value);
int erevo_eval(ErevoVM *vm, const char *name, const char *source,
               ErevoData *out_value);

#endif
