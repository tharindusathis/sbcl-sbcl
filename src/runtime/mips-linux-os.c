/*
 * This is the MIPS Linux incarnation of arch-dependent OS-dependent
 * routines. See also "linux-os.c".
 */

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

#include <stdio.h>
#include <sys/param.h>
#include <sys/file.h>
#include "sbcl.h"
#include "./signal.h"
#include "os.h"
#include "arch.h"
#include "globals.h"
#include "interrupt.h"
#include "interr.h"
#include "lispregs.h"
#include <sys/socket.h>
#include <sys/utsname.h>

#include <sys/types.h>
#include <signal.h>
#include <sys/time.h>
#include <sys/stat.h>
#include <unistd.h>

#include "validate.h"
/* for cacheflush() */
#include <asm/cachectl.h>

/* FIXME: For CAUSEF_BD */
#include <asm/mipsregs.h>
size_t os_vm_page_size;

#ifdef LISP_FEATURE_SB_THREAD
#error "Define threading support functions"
#else
int arch_os_thread_init(struct thread *thread) {
    return 1;                  /* success */
}
int arch_os_thread_cleanup(struct thread *thread) {
    return 1;                  /* success */
}
#endif

os_context_register_t *
os_context_register_addr(os_context_t *context, int offset)
{
    if (offset == 0) {
	/* KLUDGE: I'm not sure, but it's possible that Linux puts the
           contents of the Processor Status Word in the (wired-zero)
           slot in the mcontext. In any case, the following is
           unlikely to do any harm: */
	static unsigned long long zero;
	zero = 0;
	return &zero;
    } else {
	return &(((struct sigcontext *) &(context->uc_mcontext))->sc_regs[offset]);
    }
}

os_context_register_t *
os_context_pc_addr(os_context_t *context)
{
    /* Why do I get all the silly ports? -- CSR, 2002-08-11 */
    return &(((struct sigcontext *) &(context->uc_mcontext))->sc_pc);
}

sigset_t *
os_context_sigmask_addr(os_context_t *context)
{
    return &(context->uc_sigmask);
}

void 
os_restore_fp_control(os_context_t *context)
{
    /* FIXME: Probably do something. */
}

unsigned int
os_context_bd_cause(os_context_t *context)
{
    /* We need to see if whatever happened, happened because of a
       branch delay event */
    /* FIXME: However, I'm not convinced that the values that Linux
       puts in this slot are actually right; specifically, attempting
       to compile sbcl with sbcl-0.7.7.7 lead to an "infinite SIGTRAP
       loop" where a (BREAK 16) not in a branch delay slot would have
       CAUSEF_BD filled. So, we comment

        return (((struct sigcontext *) &(context->uc_mcontext))->sc_cause 
	        & CAUSEF_BD);

       out and return 0 always.  -- CSR, 2002-09-02 */
    return 0;
}

void 
os_flush_icache(os_vm_address_t address, os_vm_size_t length)
{
    if (cacheflush(address, length, ICACHE) == -1)
	perror("cacheflush");
}
