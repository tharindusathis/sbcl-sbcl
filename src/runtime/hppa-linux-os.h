#ifndef _HPPA_LINUX_OS_H
#define _HPPA_LINUX_OS_H

typedef struct ucontext os_context_t;
/* FIXME: This will change if the parisc-linux people implement
   wide-sigcontext for 32-bit kernels */
typedef unsigned long os_context_register_t;

static inline os_context_t *arch_os_get_context(void **void_context) {
    return (os_context_t *) *void_context;
}

unsigned long os_context_fp_control(os_context_t *context);
void os_restore_fp_control(os_context_t *context);

#endif /* _HPPA_LINUX_OS_H */
