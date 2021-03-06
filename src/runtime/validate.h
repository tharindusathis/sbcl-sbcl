/*
 * This software is part of the SBCL system. See the README file for
 * more information.
 *
 * This software is derived from the CMU CL system, which was
 * written at Carnegie Mellon University and released into the
 * public domain. The software is in the public domain and is
 * provided with absolutely no warranty. See the COPYING and CREDITS
 * files for more information.
 */

#if !defined(_INCLUDE_VALIDATE_H_)
#define _INCLUDE_VALIDATE_H_

/* constants derived from the fundamental constants in passed by GENESIS */
#define   BINDING_STACK_SIZE (1024*1024) /* chosen at random */
#define   DYNAMIC_SPACE_SIZE (  DYNAMIC_SPACE_END -   DYNAMIC_SPACE_START)
#define READ_ONLY_SPACE_SIZE (READ_ONLY_SPACE_END - READ_ONLY_SPACE_START)
#define    STATIC_SPACE_SIZE (   STATIC_SPACE_END -    STATIC_SPACE_START)
#define THREAD_CONTROL_STACK_SIZE (2*1024*1024)	/* eventually this'll be choosable per-thread */

#ifdef LISP_FEATURE_LINKAGE_TABLE
#define LINKAGE_TABLE_SPACE_SIZE (LINKAGE_TABLE_SPACE_END - LINKAGE_TABLE_SPACE_START)
#endif

#if !defined(LANGUAGE_ASSEMBLY)
#include <thread.h>
#ifdef LISP_FEATURE_STACK_GROWS_DOWNWARD_NOT_UPWARD 
#define CONTROL_STACK_GUARD_PAGE(th) ((void *)(th->control_stack_start))
#define CONTROL_STACK_RETURN_GUARD_PAGE(th) (CONTROL_STACK_GUARD_PAGE(th) + os_vm_page_size)
#else
#define CONTROL_STACK_GUARD_PAGE(th) (((void *)(th->control_stack_end)) - os_vm_page_size)
#define CONTROL_STACK_RETURN_GUARD_PAGE(th) (CONTROL_STACK_GUARD_PAGE(th) - os_vm_page_size)
#endif

extern void validate(void);
extern void protect_control_stack_guard_page(pid_t t_id, int protect_p);
extern void protect_control_stack_return_guard_page(pid_t t_id, int protect_p);
extern os_vm_address_t undefined_alien_address;
#endif

/* note for anyone trying to port an architecture's support files
 * from CMU CL to SBCL:
 *
 * CMU CL had architecture-dependent header files included here to
 * define memory map data:
 *   #ifdef LISP_FEATURE_X86
 *   #include "x86-validate.h"
 *   #endif
 * and so forth. In SBCL, the memory map data are defined at the Lisp
 * level (compiler/target/parms.lisp) and stuffed into the sbcl.h file
 * created by GENESIS, so there's no longer a need for an
 * architecture-dependent header file of memory map data. 
 */

#endif
