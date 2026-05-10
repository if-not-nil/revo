#include "../../revo.h"
#include <stdio.h>

static void print_value(ErevoData value) {
  if (value.tag == revo_number) {
    double n = *(double *)&value.value;
    printf("%.0f\n", n);
    return;
  }

  printf("%llu:%llu\n", (unsigned long long)value.tag,
         (unsigned long long)value.value);
}

int main(void) {
  ErevoVM *vm = erevo_vm_create();
  if (!vm)
    return 1;

  ErevoProgram *program = erevo_compile(vm, "basic.rv", "1 + 2");
  if (!program) {
    puts(erevo_vm_last_error(vm));
    erevo_vm_destroy(vm);
    return 1;
  }

  ErevoData value;
  if (!erevo_run(vm, program, &value)) {
    puts(erevo_vm_last_error(vm));
    erevo_program_destroy(program);
    erevo_vm_destroy(vm);
    return 1;
  }
  print_value(value);

  if (!erevo_eval(vm, "basic.rv", "1 + 2", &value)) {
    puts(erevo_vm_last_error(vm));
    erevo_program_destroy(program);
    erevo_vm_destroy(vm);
    return 1;
  }
  print_value(value);

  erevo_program_destroy(program);
  erevo_vm_destroy(vm);
  return 0;
}
