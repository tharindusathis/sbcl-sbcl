;;;; function call for the x86 VM

;;;; This software is part of the SBCL system. See the README file for
;;;; more information.
;;;;
;;;; This software is derived from the CMU CL system, which was
;;;; written at Carnegie Mellon University and released into the
;;;; public domain. The software is in the public domain and is
;;;; provided with absolutely no warranty. See the COPYING and CREDITS
;;;; files for more information.

(in-package "SB!VM")

;;;; interfaces to IR2 conversion

;;; Return a wired TN describing the N'th full call argument passing
;;; location.
(!def-vm-support-routine standard-arg-location (n)
  (declare (type unsigned-byte n))
  (if (< n register-arg-count)
      (make-wired-tn *backend-t-primitive-type* descriptor-reg-sc-number
		     (nth n *register-arg-offsets*))
      (make-wired-tn *backend-t-primitive-type* control-stack-sc-number n)))

;;; Make a passing location TN for a local call return PC.
;;;
;;; Always wire the return PC location to the stack in its standard
;;; location.
(!def-vm-support-routine make-return-pc-passing-location (standard)
  (declare (ignore standard))
  (make-wired-tn (primitive-type-or-lose 'system-area-pointer)
		 sap-stack-sc-number return-pc-save-offset))

;;; This is similar to MAKE-RETURN-PC-PASSING-LOCATION, but makes a
;;; location to pass OLD-FP in.
;;;
;;; This is wired in both the standard and the local-call conventions,
;;; because we want to be able to assume it's always there. Besides,
;;; the x86 doesn't have enough registers to really make it profitable
;;; to pass it in a register.
(!def-vm-support-routine make-old-fp-passing-location (standard)
  (declare (ignore standard))
  (make-wired-tn *fixnum-primitive-type* control-stack-sc-number
		 ocfp-save-offset))

;;; Make the TNs used to hold OLD-FP and RETURN-PC within the current
;;; function. We treat these specially so that the debugger can find
;;; them at a known location.
;;;
;;; Without using a save-tn - which does not make much sense if it is
;;; wired to the stack? 
(!def-vm-support-routine make-old-fp-save-location (physenv)
  (physenv-debug-live-tn (make-wired-tn *fixnum-primitive-type*
					control-stack-sc-number
					ocfp-save-offset)
			 physenv))
(!def-vm-support-routine make-return-pc-save-location (physenv)
  (physenv-debug-live-tn
   (make-wired-tn (primitive-type-or-lose 'system-area-pointer)
		  sap-stack-sc-number return-pc-save-offset)
   physenv))

;;; Make a TN for the standard argument count passing location. We only
;;; need to make the standard location, since a count is never passed when we
;;; are using non-standard conventions.
(!def-vm-support-routine make-arg-count-location ()
  (make-wired-tn *fixnum-primitive-type* any-reg-sc-number rcx-offset))

;;; Make a TN to hold the number-stack frame pointer. This is allocated
;;; once per component, and is component-live.
(!def-vm-support-routine make-nfp-tn ()
  (make-restricted-tn *fixnum-primitive-type* ignore-me-sc-number))

(!def-vm-support-routine make-stack-pointer-tn ()
  (make-normal-tn *fixnum-primitive-type*))

(!def-vm-support-routine make-number-stack-pointer-tn ()
  (make-restricted-tn *fixnum-primitive-type* ignore-me-sc-number))

;;; Return a list of TNs that can be used to represent an unknown-values
;;; continuation within a function.
(!def-vm-support-routine make-unknown-values-locations ()
  (list (make-stack-pointer-tn)
	(make-normal-tn *fixnum-primitive-type*)))

;;; This function is called by the ENTRY-ANALYZE phase, allowing
;;; VM-dependent initialization of the IR2-COMPONENT structure. We
;;; push placeholder entries in the CONSTANTS to leave room for
;;; additional noise in the code object header.
(!def-vm-support-routine select-component-format (component)
  (declare (type component component))
  ;; The 1+ here is because for the x86 the first constant is a
  ;; pointer to a list of fixups, or NIL if the code object has none.
  ;; (If I understand correctly, the fixups are needed at GC copy
  ;; time because the X86 code isn't relocatable.)
  ;;
  ;; KLUDGE: It'd be cleaner to have the fixups entry be a named
  ;; element of the CODE (aka component) primitive object. However,
  ;; it's currently a large, tricky, error-prone chore to change
  ;; the layout of any primitive object, so for the foreseeable future
  ;; we'll just live with this ugliness. -- WHN 2002-01-02
  (dotimes (i (1+ code-constants-offset))
    (vector-push-extend nil
			(ir2-component-constants (component-info component))))
  (values))

;;;; frame hackery

;;; This is used for setting up the Old-FP in local call.
(define-vop (current-fp)
  (:results (val :scs (any-reg control-stack)))
  (:generator 1
    (move val rbp-tn)))

;;; We don't have a separate NFP, so we don't need to do anything here.
(define-vop (compute-old-nfp)
  (:results (val))
  (:ignore val)
  (:generator 1
    nil))

(define-vop (xep-allocate-frame)
  (:info start-lab copy-more-arg-follows)
  (:vop-var vop)
  (:generator 1
    (align n-lowtag-bits)
    (trace-table-entry trace-table-fun-prologue)
    (emit-label start-lab)
    ;; Skip space for the function header.
    (inst simple-fun-header-word)
    (dotimes (i (* n-word-bytes (1- simple-fun-code-offset)))
      (inst byte 0))
    
    ;; The start of the actual code.
    ;; Save the return-pc.
    (popw rbp-tn (- (1+ return-pc-save-offset)))

    ;; If copy-more-arg follows it will allocate the correct stack
    ;; size. The stack is not allocated first here as this may expose
    ;; args on the stack if they take up more space than the frame!
    (unless copy-more-arg-follows
      ;; The args fit within the frame so just allocate the frame.
      (inst lea rsp-tn
	    (make-ea :qword :base rbp-tn
		     :disp (- (* n-word-bytes
				 (max 3 (sb-allocated-size 'stack)))))))

    (trace-table-entry trace-table-normal)))

;;; This is emitted directly before either a known-call-local, call-local,
;;; or a multiple-call-local. All it does is allocate stack space for the
;;; callee (who has the same size stack as us).
(define-vop (allocate-frame)
  (:results (res :scs (any-reg control-stack))
	    (nfp))
  (:info callee)
  (:ignore nfp callee)
  (:generator 2
    (move res rsp-tn)
    (inst sub rsp-tn (* n-word-bytes (sb-allocated-size 'stack)))))

;;; Allocate a partial frame for passing stack arguments in a full
;;; call. NARGS is the number of arguments passed. We allocate at
;;; least 3 slots, because the XEP noise is going to want to use them
;;; before it can extend the stack.
(define-vop (allocate-full-call-frame)
  (:info nargs)
  (:results (res :scs (any-reg control-stack)))
  (:generator 2
    (move res rsp-tn)
    (inst sub rsp-tn (* (max nargs 3) n-word-bytes))))

;;; Emit code needed at the return-point from an unknown-values call
;;; for a fixed number of values. Values is the head of the TN-REF
;;; list for the locations that the values are to be received into.
;;; Nvals is the number of values that are to be received (should
;;; equal the length of Values).
;;;
;;; MOVE-TEMP is a DESCRIPTOR-REG TN used as a temporary.
;;;
;;; This code exploits the fact that in the unknown-values convention,
;;; a single value return returns at the return PC + 2, whereas a
;;; return of other than one value returns directly at the return PC.
;;;
;;; If 0 or 1 values are expected, then we just emit an instruction to
;;; reset the SP (which will only be executed when other than 1 value
;;; is returned.)
;;;
;;; In the general case we have to do three things:
;;;  -- Default unsupplied register values. This need only be done
;;;     when a single value is returned, since register values are
;;;     defaulted by the called in the non-single case.
;;;  -- Default unsupplied stack values. This needs to be done whenever
;;;     there are stack values.
;;;  -- Reset SP. This must be done whenever other than 1 value is
;;;     returned, regardless of the number of values desired.
(defun default-unknown-values (vop values nvals)
  (declare (type (or tn-ref null) values)
	   (type unsigned-byte nvals))
  (cond
   ((<= nvals 1)
    (note-this-location vop :single-value-return)
    (inst mov rsp-tn rbx-tn))
   ((<= nvals register-arg-count)
    (let ((regs-defaulted (gen-label)))
      (note-this-location vop :unknown-return)
      (inst nop)
      (inst jmp-short regs-defaulted)
      ;; Default the unsupplied registers.
      (let* ((2nd-tn-ref (tn-ref-across values))
	     (2nd-tn (tn-ref-tn 2nd-tn-ref)))
	(inst mov 2nd-tn nil-value)
	(when (> nvals 2)
	  (loop
	    for tn-ref = (tn-ref-across 2nd-tn-ref)
	    then (tn-ref-across tn-ref)
	    for count from 2 below register-arg-count
	    do (inst mov (tn-ref-tn tn-ref) 2nd-tn))))
      (inst mov rbx-tn rsp-tn)
      (emit-label regs-defaulted)
      (inst mov rsp-tn rbx-tn)))
   ((<= nvals 7)
    ;; The number of bytes depends on the relative jump instructions.
    ;; Best case is 31+(n-3)*14, worst case is 35+(n-3)*18. For
    ;; NVALS=6 that is 73/89 bytes, and for NVALS=7 that is 87/107
    ;; bytes which is likely better than using the blt below.
    (let ((regs-defaulted (gen-label))
	  (defaulting-done (gen-label))
	  (default-stack-slots (gen-label)))
      (note-this-location vop :unknown-return)
      ;; Branch off to the MV case.
      (inst nop)
      (inst jmp-short regs-defaulted)
      ;; Do the single value case.
      ;; Default the register args
      (inst mov rax-tn nil-value)
      (do ((i 1 (1+ i))
	   (val (tn-ref-across values) (tn-ref-across val)))
	  ((= i (min nvals register-arg-count)))
	(inst mov (tn-ref-tn val) rax-tn))

      ;; Fake other registers so it looks like we returned with all the
      ;; registers filled in.
      (move rbx-tn rsp-tn)
      (inst push rdx-tn)
      (inst jmp default-stack-slots)

      (emit-label regs-defaulted)

      (inst mov rax-tn nil-value)
      (storew rdx-tn rbx-tn -1)
      (collect ((defaults))
	(do ((i register-arg-count (1+ i))
	     (val (do ((i 0 (1+ i))
		       (val values (tn-ref-across val)))
		      ((= i register-arg-count) val))
		  (tn-ref-across val)))
	    ((null val))
	  (let ((default-lab (gen-label))
		(tn (tn-ref-tn val)))
	    (defaults (cons default-lab tn))

	    (inst cmp rcx-tn (fixnumize i))
	    (inst jmp :be default-lab)
	    (loadw rdx-tn rbx-tn (- (1+ i)))
	    (inst mov tn rdx-tn)))

	(emit-label defaulting-done)
	(loadw rdx-tn rbx-tn -1)
	(move rsp-tn rbx-tn)

	(let ((defaults (defaults)))
	  (when defaults
	    (assemble (*elsewhere*)
	      (trace-table-entry trace-table-fun-prologue)
	      (emit-label default-stack-slots)
	      (dolist (default defaults)
		(emit-label (car default))
		(inst mov (cdr default) rax-tn))
	      (inst jmp defaulting-done)
	      (trace-table-entry trace-table-normal)))))))
   (t
    (let ((regs-defaulted (gen-label))
	  (restore-edi (gen-label))
	  (no-stack-args (gen-label))
	  (default-stack-vals (gen-label))
	  (count-okay (gen-label)))
      (note-this-location vop :unknown-return)
      ;; Branch off to the MV case.
      (inst nop)
      (inst jmp-short regs-defaulted)

      ;; Default the register args, and set up the stack as if we
      ;; entered the MV return point.
      (inst mov rbx-tn rsp-tn)
      (inst push rdx-tn)
      (inst mov rdi-tn nil-value)
      (inst push rdi-tn)
      (inst mov rsi-tn rdi-tn)
      ;; Compute a pointer to where to put the [defaulted] stack values.
      (emit-label no-stack-args)
      (inst lea rdi-tn
	    (make-ea :qword :base rbp-tn
		     :disp (* (- (1+ register-arg-count)) n-word-bytes)))
      ;; Load RAX with NIL so we can quickly store it, and set up
      ;; stuff for the loop.
      (inst mov rax-tn nil-value)
      (inst std)
      (inst mov rcx-tn (- nvals register-arg-count))
      ;; Jump into the default loop.
      (inst jmp default-stack-vals)

      ;; The regs are defaulted. We need to copy any stack arguments,
      ;; and then default the remaining stack arguments.
      (emit-label regs-defaulted)
      ;; Save EDI.
      (storew rdi-tn rbx-tn (- (1+ 1)))
      ;; Compute the number of stack arguments, and if it's zero or
      ;; less, don't copy any stack arguments.
      (inst sub rcx-tn (fixnumize register-arg-count))
      (inst jmp :le no-stack-args)

      ;; Throw away any unwanted args.
      (inst cmp rcx-tn (fixnumize (- nvals register-arg-count)))
      (inst jmp :be count-okay)
      (inst mov rcx-tn (fixnumize (- nvals register-arg-count)))
      (emit-label count-okay)
      ;; Save the number of stack values.
      (inst mov rax-tn rcx-tn)
      ;; Compute a pointer to where the stack args go.
      (inst lea rdi-tn
	    (make-ea :qword :base rbp-tn
		     :disp (* (- (1+ register-arg-count)) n-word-bytes)))
      ;; Save ESI, and compute a pointer to where the args come from.
      (storew rsi-tn rbx-tn (- (1+ 2)))
      (inst lea rsi-tn
	    (make-ea :qword :base rbx-tn
		     :disp (* (- (1+ register-arg-count)) n-word-bytes)))
      ;; Do the copy.
      (inst shr rcx-tn word-shift)		; make word count
      (inst std)
      (inst rep)
      (inst movs :qword)
      ;; Restore RSI.
      (loadw rsi-tn rbx-tn (- (1+ 2)))
      ;; Now we have to default the remaining args. Find out how many.
      (inst sub rax-tn (fixnumize (- nvals register-arg-count)))
      (inst neg rax-tn)
      ;; If none, then just blow out of here.
      (inst jmp :le restore-edi)
      (inst mov rcx-tn rax-tn)
      (inst shr rcx-tn word-shift)	; word count
      ;; Load RAX with NIL for fast storing.
      (inst mov rax-tn nil-value)
      ;; Do the store.
      (emit-label default-stack-vals)
      (inst rep)
      (inst stos rax-tn)
      ;; Restore EDI, and reset the stack.
      (emit-label restore-edi)
      (loadw rdi-tn rbx-tn (- (1+ 1)))
      (inst mov rsp-tn rbx-tn))))
  (values))

;;;; unknown values receiving

;;; Emit code needed at the return point for an unknown-values call
;;; for an arbitrary number of values.
;;;
;;; We do the single and non-single cases with no shared code: there
;;; doesn't seem to be any potential overlap, and receiving a single
;;; value is more important efficiency-wise.
;;;
;;; When there is a single value, we just push it on the stack,
;;; returning the old SP and 1.
;;;
;;; When there is a variable number of values, we move all of the
;;; argument registers onto the stack, and return ARGS and NARGS.
;;;
;;; ARGS and NARGS are TNs wired to the named locations. We must
;;; explicitly allocate these TNs, since their lifetimes overlap with
;;; the results start and count. (Also, it's nice to be able to target
;;; them.)
(defun receive-unknown-values (args nargs start count)
  (declare (type tn args nargs start count))
  (let ((variable-values (gen-label))
	(done (gen-label)))
    (inst nop)
    (inst jmp-short variable-values)

    (cond ((location= start (first *register-arg-tns*))
           (inst push (first *register-arg-tns*))
           (inst lea start (make-ea :qword :base rsp-tn :disp 8)))
          (t (inst mov start rsp-tn)
             (inst push (first *register-arg-tns*))))
    (inst mov count (fixnumize 1))
    (inst jmp done)

    (emit-label variable-values)
    ;; dtc: this writes the registers onto the stack even if they are
    ;; not needed, only the number specified in rcx are used and have
    ;; stack allocated to them. No harm is done.
    (loop
      for arg in *register-arg-tns*
      for i downfrom -1
      do (storew arg args i))
    (move start args)
    (move count nargs)

    (emit-label done))
  (values))

;;; VOP that can be inherited by unknown values receivers. The main thing this
;;; handles is allocation of the result temporaries.
(define-vop (unknown-values-receiver)
  (:temporary (:sc descriptor-reg :offset rbx-offset
		   :from :eval :to (:result 0))
	      values-start)
  (:temporary (:sc any-reg :offset rcx-offset
	       :from :eval :to (:result 1))
	      nvals)
  (:results (start :scs (any-reg control-stack))
	    (count :scs (any-reg control-stack))))

;;;; local call with unknown values convention return

;;; Non-TR local call for a fixed number of values passed according to
;;; the unknown values convention.
;;;
;;; FP is the frame pointer in install before doing the call.
;;;
;;; NFP would be the number-stack frame pointer if we had a separate
;;; number stack.
;;;
;;; Args are the argument passing locations, which are specified only
;;; to terminate their lifetimes in the caller.
;;;
;;; VALUES are the return value locations (wired to the standard
;;; passing locations). NVALS is the number of values received.
;;;
;;; Save is the save info, which we can ignore since saving has been
;;; done.
;;;
;;; TARGET is a continuation pointing to the start of the called
;;; function.
(define-vop (call-local)
  (:args (fp)
	 (nfp)
	 (args :more t))
  (:temporary (:sc unsigned-reg) return-label)
  (:results (values :more t))
  (:save-p t)
  (:move-args :local-call)
  (:info arg-locs callee target nvals)
  (:vop-var vop)
  (:ignore nfp arg-locs args #+nil callee)
  (:generator 5
    (trace-table-entry trace-table-call-site)
    (move rbp-tn fp)

    (let ((ret-tn (callee-return-pc-tn callee)))
      #+nil
      (format t "*call-local ~S; tn-kind ~S; tn-save-tn ~S; its tn-kind ~S~%"
	      ret-tn (sb!c::tn-kind ret-tn) (sb!c::tn-save-tn ret-tn)
	      (sb!c::tn-kind (sb!c::tn-save-tn ret-tn)))

      ;; Is the return-pc on the stack or in a register?
      (sc-case ret-tn
	((sap-stack)
	 #+nil (format t "*call-local: ret-tn on stack; offset=~S~%"
		       (tn-offset ret-tn))
	 (inst lea return-label (make-fixup nil :code-object return))
	 (storew return-label rbp-tn (- (1+ (tn-offset ret-tn)))))
	((sap-reg)
	 (inst lea ret-tn (make-fixup nil :code-object return)))))

    (note-this-location vop :call-site)
    (inst jmp target)
    RETURN
    (default-unknown-values vop values nvals)
    (trace-table-entry trace-table-normal)))

;;; Non-TR local call for a variable number of return values passed according
;;; to the unknown values convention. The results are the start of the values
;;; glob and the number of values received.
(define-vop (multiple-call-local unknown-values-receiver)
  (:args (fp)
	 (nfp)
	 (args :more t))
  (:temporary (:sc unsigned-reg) return-label)
  (:save-p t)
  (:move-args :local-call)
  (:info save callee target)
  (:ignore args save nfp #+nil callee)
  (:vop-var vop)
  (:generator 20
    (trace-table-entry trace-table-call-site)
    (move rbp-tn fp)

    (let ((ret-tn (callee-return-pc-tn callee)))
      #+nil
      (format t "*multiple-call-local ~S; tn-kind ~S; tn-save-tn ~S; its tn-kind ~S~%"
	      ret-tn (sb!c::tn-kind ret-tn) (sb!c::tn-save-tn ret-tn)
	      (sb!c::tn-kind (sb!c::tn-save-tn ret-tn)))

      ;; Is the return-pc on the stack or in a register?
      (sc-case ret-tn
	((sap-stack)
	 #+nil (format t "*multiple-call-local: ret-tn on stack; offset=~S~%"
		       (tn-offset ret-tn))
	 ;; Stack
	 (inst lea return-label (make-fixup nil :code-object return))
	 (storew return-label rbp-tn (- (1+ (tn-offset ret-tn)))))
	((sap-reg)
	 ;; Register
	 (inst lea ret-tn (make-fixup nil :code-object return)))))

    (note-this-location vop :call-site)
    (inst jmp target)
    RETURN
    (note-this-location vop :unknown-return)
    (receive-unknown-values values-start nvals start count)
    (trace-table-entry trace-table-normal)))

;;;; local call with known values return

;;; Non-TR local call with known return locations. Known-value return
;;; works just like argument passing in local call.
;;;
;;; Note: we can't use normal load-tn allocation for the fixed args,
;;; since all registers may be tied up by the more operand. Instead,
;;; we use MAYBE-LOAD-STACK-TN.
(define-vop (known-call-local)
  (:args (fp)
	 (nfp)
	 (args :more t))
  (:temporary (:sc unsigned-reg) return-label)
  (:results (res :more t))
  (:move-args :local-call)
  (:save-p t)
  (:info save callee target)
  (:ignore args res save nfp #+nil callee)
  (:vop-var vop)
  (:generator 5
    (trace-table-entry trace-table-call-site)
    (move rbp-tn fp)

    (let ((ret-tn (callee-return-pc-tn callee)))

      #+nil
      (format t "*known-call-local ~S; tn-kind ~S; tn-save-tn ~S; its tn-kind ~S~%"
	      ret-tn (sb!c::tn-kind ret-tn) (sb!c::tn-save-tn ret-tn)
	      (sb!c::tn-kind (sb!c::tn-save-tn ret-tn)))

      ;; Is the return-pc on the stack or in a register?
      (sc-case ret-tn
	((sap-stack)
	 #+nil (format t "*known-call-local: ret-tn on stack; offset=~S~%"
		       (tn-offset ret-tn))
	 ;; Stack
	 (inst lea return-label (make-fixup nil :code-object return))
	 (storew return-label rbp-tn (- (1+ (tn-offset ret-tn)))))
	((sap-reg)
	 ;; Register
	 (inst lea ret-tn (make-fixup nil :code-object return)))))

    (note-this-location vop :call-site)
    (inst jmp target)
    RETURN
    (note-this-location vop :known-return)
    (trace-table-entry trace-table-normal)))

;;; Return from known values call. We receive the return locations as
;;; arguments to terminate their lifetimes in the returning function. We
;;; restore FP and CSP and jump to the Return-PC.
;;;
;;; We can assume we know exactly where old-fp and return-pc are because
;;; make-old-fp-save-location and make-return-pc-save-location always
;;; return the same place.
#+nil
(define-vop (known-return)
  (:args (old-fp)
	 (return-pc :scs (any-reg immediate-stack) :target rpc)
	 (vals :more t))
  (:move-args :known-return)
  (:info val-locs)
  (:temporary (:sc unsigned-reg :from (:argument 1)) rpc)
  (:ignore val-locs vals)
  (:vop-var vop)
  (:generator 6
    (trace-table-entry trace-table-fun-epilogue)
    ;; Save the return-pc in a register 'cause the frame-pointer is
    ;; going away. Note this not in the usual stack location so we
    ;; can't use RET
    (move rpc return-pc)
    ;; Restore the stack.
    (move rsp-tn rbp-tn)
    ;; Restore the old fp. We know OLD-FP is going to be in its stack
    ;; save slot, which is a different frame that than this one,
    ;; so we don't have to worry about having just cleared
    ;; most of the stack.
    (move rbp-tn old-fp)
    (inst jmp rpc)
    (trace-table-entry trace-table-normal)))

;;; From Douglas Crosher
;;; Return from known values call. We receive the return locations as
;;; arguments to terminate their lifetimes in the returning function. We
;;; restore FP and CSP and jump to the Return-PC.
;;;
;;; The old-fp may be either in a register or on the stack in its
;;; standard save locations - slot 0.
;;;
;;; The return-pc may be in a register or on the stack in any slot.
(define-vop (known-return)
  (:args (old-fp)
	 (return-pc)
	 (vals :more t))
  (:move-args :known-return)
  (:info val-locs)
  (:ignore val-locs vals)
  (:vop-var vop)
  (:generator 6
    (trace-table-entry trace-table-fun-epilogue)
    ;; return-pc may be either in a register or on the stack.
    (sc-case return-pc
      ((sap-reg)
       (sc-case old-fp
	 ((control-stack)
	  (cond ((zerop (tn-offset old-fp))
		 ;; Zot all of the stack except for the old-fp.
		 (inst lea rsp-tn (make-ea :qword :base rbp-tn
					   :disp (- (* (1+ ocfp-save-offset)
						       n-word-bytes))))
		 ;; Restore the old fp from its save location on the stack,
		 ;; and zot the stack.
		 (inst pop rbp-tn))

		(t
		 (cerror "Continue anyway"
			 "VOP return-local doesn't work if old-fp (in slot ~
                          ~S) is not in slot 0"
			 (tn-offset old-fp)))))

	 ((any-reg descriptor-reg)
	  ;; Zot all the stack.
	  (move rsp-tn rbp-tn)
	  ;; Restore the old-fp.
	  (move rbp-tn old-fp)))

       ;; Return; return-pc is in a register.
       (inst jmp return-pc))

      ((sap-stack)
       (inst lea rsp-tn
	     (make-ea :qword :base rbp-tn
		      :disp (- (* (1+ (tn-offset return-pc)) n-word-bytes))))
       (move rbp-tn old-fp)
       (inst ret (* (tn-offset return-pc) n-word-bytes))))

    (trace-table-entry trace-table-normal)))

;;;; full call
;;;
;;; There is something of a cross-product effect with full calls.
;;; Different versions are used depending on whether we know the
;;; number of arguments or the name of the called function, and
;;; whether we want fixed values, unknown values, or a tail call.
;;;
;;; In full call, the arguments are passed creating a partial frame on
;;; the stack top and storing stack arguments into that frame. On
;;; entry to the callee, this partial frame is pointed to by FP.

;;; This macro helps in the definition of full call VOPs by avoiding
;;; code replication in defining the cross-product VOPs.
;;;
;;; NAME is the name of the VOP to define.
;;;
;;; NAMED is true if the first argument is an fdefinition object whose
;;; definition is to be called.
;;;
;;; RETURN is either :FIXED, :UNKNOWN or :TAIL:
;;; -- If :FIXED, then the call is for a fixed number of values, returned in
;;;    the standard passing locations (passed as result operands).
;;; -- If :UNKNOWN, then the result values are pushed on the stack, and the
;;;    result values are specified by the Start and Count as in the
;;;    unknown-values continuation representation.
;;; -- If :TAIL, then do a tail-recursive call. No values are returned.
;;;    The Old-Fp and Return-PC are passed as the second and third arguments.
;;;
;;; In non-tail calls, the pointer to the stack arguments is passed as
;;; the last fixed argument. If Variable is false, then the passing
;;; locations are passed as a more arg. Variable is true if there are
;;; a variable number of arguments passed on the stack. Variable
;;; cannot be specified with :TAIL return. TR variable argument call
;;; is implemented separately.
;;;
;;; In tail call with fixed arguments, the passing locations are
;;; passed as a more arg, but there is no new-FP, since the arguments
;;; have been set up in the current frame.
(macrolet ((define-full-call (name named return variable)
	    (aver (not (and variable (eq return :tail))))
	    `(define-vop (,name
			  ,@(when (eq return :unknown)
			      '(unknown-values-receiver)))
	       (:args
	       ,@(unless (eq return :tail)
		   '((new-fp :scs (any-reg) :to (:argument 1))))

	       (fun :scs (descriptor-reg control-stack)
		    :target rax :to (:argument 0))

	       ,@(when (eq return :tail)
		   '((old-fp)
		     (return-pc)))

	       ,@(unless variable '((args :more t :scs (descriptor-reg)))))

	       ,@(when (eq return :fixed)
	       '((:results (values :more t))))

	       (:save-p ,(if (eq return :tail) :compute-only t))

	       ,@(unless (or (eq return :tail) variable)
	       '((:move-args :full-call)))

	       (:vop-var vop)
	       (:info
	       ,@(unless (or variable (eq return :tail)) '(arg-locs))
	       ,@(unless variable '(nargs))
	       ,@(when (eq return :fixed) '(nvals)))

	       (:ignore
	       ,@(unless (or variable (eq return :tail)) '(arg-locs))
	       ,@(unless variable '(args)))

	       ;; We pass either the fdefn object (for named call) or
	       ;; the actual function object (for unnamed call) in
	       ;; RAX. With named call, closure-tramp will replace it
	       ;; with the real function and invoke the real function
	       ;; for closures. Non-closures do not need this value,
	       ;; so don't care what shows up in it.
	       (:temporary
	       (:sc descriptor-reg
		    :offset rax-offset
		    :from (:argument 0)
		    :to :eval)
	       rax)

	       ;; We pass the number of arguments in RCX.
	       (:temporary (:sc unsigned-reg :offset rcx-offset :to :eval) rcx)

	       ;; With variable call, we have to load the
	       ;; register-args out of the (new) stack frame before
	       ;; doing the call. Therefore, we have to tell the
	       ;; lifetime stuff that we need to use them.
	       ,@(when variable
		   (mapcar (lambda (name offset)
			     `(:temporary (:sc descriptor-reg
					       :offset ,offset
					       :from (:argument 0)
					       :to :eval)
					  ,name))
			   *register-arg-names* *register-arg-offsets*))

	       ,@(when (eq return :tail)
		   '((:temporary (:sc unsigned-reg
				      :from (:argument 1)
				      :to (:argument 2))
				 old-fp-tmp)))

	       (:generator ,(+ (if named 5 0)
			       (if variable 19 1)
			       (if (eq return :tail) 0 10)
			       15
			       (if (eq return :unknown) 25 0))
	       (trace-table-entry trace-table-call-site)

	       ;; This has to be done before the frame pointer is
	       ;; changed! RAX stores the 'lexical environment' needed
	       ;; for closures.
	       (move rax fun)


	       ,@(if variable
		     ;; For variable call, compute the number of
		     ;; arguments and move some of the arguments to
		     ;; registers.
		     (collect ((noise))
			      ;; Compute the number of arguments.
			      (noise '(inst mov rcx new-fp))
			      (noise '(inst sub rcx rsp-tn))
			      ;; Move the necessary args to registers,
			      ;; this moves them all even if they are
			      ;; not all needed.
			      (loop
			       for name in *register-arg-names*
			       for index downfrom -1
			       do (noise `(loadw ,name new-fp ,index)))
			      (noise))
		   '((if (zerop nargs)
			 (inst xor rcx rcx)
		       (inst mov rcx (fixnumize nargs)))))
	       ,@(cond ((eq return :tail)
			'(;; Python has figured out what frame we should
			  ;; return to so might as well use that clue.
			  ;; This seems really important to the
			  ;; implementation of things like
			  ;; (without-interrupts ...)
			  ;;
			  ;; dtc; Could be doing a tail call from a
			  ;; known-local-call etc in which the old-fp
			  ;; or ret-pc are in regs or in non-standard
			  ;; places. If the passing location were
			  ;; wired to the stack in standard locations
			  ;; then these moves will be un-necessary;
			  ;; this is probably best for the x86.
			  (sc-case old-fp
				   ((control-stack)
				    (unless (= ocfp-save-offset
					       (tn-offset old-fp))
				      ;; FIXME: FORMAT T for stale
				      ;; diagnostic output (several of
				      ;; them around here), ick
				      (format t "** tail-call old-fp not S0~%")
				      (move old-fp-tmp old-fp)
				      (storew old-fp-tmp
					      rbp-tn
					      (- (1+ ocfp-save-offset)))))
				   ((any-reg descriptor-reg)
				    (format t "** tail-call old-fp in reg not S0~%")
				    (storew old-fp
					    rbp-tn
					    (- (1+ ocfp-save-offset)))))

			  ;; For tail call, we have to push the
			  ;; return-pc so that it looks like we CALLed
			  ;; drspite the fact that we are going to JMP.
			  (inst push return-pc)
			  ))
		       (t
			;; For non-tail call, we have to save our
			;; frame pointer and install the new frame
			;; pointer. We can't load stack tns after this
			;; point.
			`(;; Python doesn't seem to allocate a frame
			  ;; here which doesn't leave room for the
			  ;; ofp/ret stuff.
		
			  ;; The variable args are on the stack and
			  ;; become the frame, but there may be <3
			  ;; args and 3 stack slots are assumed
			  ;; allocate on the call. So need to ensure
			  ;; there are at least 3 slots. This hack
			  ;; just adds 3 more.
			  ,(if variable
			       '(inst sub rsp-tn (fixnumize 3)))

			  ;; Save the fp
			  (storew rbp-tn new-fp (- (1+ ocfp-save-offset)))

			  (move rbp-tn new-fp) ; NB - now on new stack frame.
			  )))

	       (note-this-location vop :call-site)

	       (inst ,(if (eq return :tail) 'jmp 'call)
		     (make-ea :qword :base rax
			      :disp ,(if named
					 '(- (* fdefn-raw-addr-slot
						n-word-bytes)
					     other-pointer-lowtag)
				       '(- (* closure-fun-slot n-word-bytes)
					   fun-pointer-lowtag))))
	       ,@(ecase return
		   (:fixed
		    '((default-unknown-values vop values nvals)))
		   (:unknown
		    '((note-this-location vop :unknown-return)
		      (receive-unknown-values values-start nvals start count)))
		   (:tail))
	       (trace-table-entry trace-table-normal)))))

  (define-full-call call nil :fixed nil)
  (define-full-call call-named t  :fixed nil)
  (define-full-call multiple-call nil :unknown nil)
  (define-full-call multiple-call-named t :unknown nil)
  (define-full-call tail-call nil :tail nil)
  (define-full-call tail-call-named t :tail nil)

  (define-full-call call-variable nil :fixed t)
  (define-full-call multiple-call-variable nil :unknown t))

;;; This is defined separately, since it needs special code that BLT's
;;; the arguments down. All the real work is done in the assembly
;;; routine. We just set things up so that it can find what it needs.
(define-vop (tail-call-variable)
  (:args (args :scs (any-reg control-stack) :target rsi)
	 (function :scs (descriptor-reg control-stack) :target rax)
	 (old-fp)
	 (ret-addr))
  (:temporary (:sc unsigned-reg :offset rsi-offset :from (:argument 0)) rsi)
  (:temporary (:sc unsigned-reg :offset rax-offset :from (:argument 1)) rax)
  (:temporary (:sc unsigned-reg) call-target)
;  (:ignore ret-addr old-fp)
  (:generator 75
    ;; Move these into the passing locations if they are not already there.
    (move rsi args)
    (move rax function)

    ;; The following assumes that the return-pc and old-fp are on the
    ;; stack in their standard save locations - Check this.
    (unless (and (sc-is old-fp control-stack)
		 (= (tn-offset old-fp) ocfp-save-offset))
	    (error "tail-call-variable: ocfp not on stack in standard save location?"))
    (unless (and (sc-is ret-addr sap-stack)
		 (= (tn-offset ret-addr) return-pc-save-offset))
	    (error "tail-call-variable: ret-addr not on stack in standard save location?"))


    (inst lea call-target
	  (make-ea :qword
		   :disp (make-fixup 'tail-call-variable :assembly-routine)))
    ;; And jump to the assembly routine.
    (inst jmp call-target)))

;;;; unknown values return

;;; Return a single-value using the Unknown-Values convention. Specifically,
;;; we jump to clear the stack and jump to return-pc+3.
;;;
;;; We require old-fp to be in a register, because we want to reset RSP before
;;; restoring RBP. If old-fp were still on the stack, it could get clobbered
;;; by a signal.
;;;
;;; pfw--get wired-tn conflicts sometimes if register sc specd for args
;;; having problems targeting args to regs -- using temps instead.
(define-vop (return-single)
  (:args (old-fp)
	 (return-pc)
	 (value))
  (:temporary (:sc unsigned-reg) ofp)
  (:temporary (:sc unsigned-reg) ret)
  (:ignore value)
  (:generator 6
    (trace-table-entry trace-table-fun-epilogue)
    (move ret return-pc)
    ;; Clear the control stack
    (move ofp old-fp)
    ;; Adjust the return address for the single value return.
    (inst add ret 3)
    ;; Restore the frame pointer.
    (move rsp-tn rbp-tn)
    (move rbp-tn ofp)
    ;; Out of here.
    (inst jmp ret)))

;;; Do unknown-values return of a fixed (other than 1) number of
;;; values. The VALUES are required to be set up in the standard
;;; passing locations. NVALS is the number of values returned.
;;;
;;; Basically, we just load RCX with the number of values returned and
;;; RBX with a pointer to the values, set RSP to point to the end of
;;; the values, and jump directly to return-pc.
(define-vop (return)
  (:args (old-fp)
	 (return-pc :to (:eval 1))
	 (values :more t))
  (:ignore values)
  (:info nvals)

  ;; In the case of other than one value, we need these registers to
  ;; tell the caller where they are and how many there are.
  (:temporary (:sc unsigned-reg :offset rbx-offset) rbx)
  (:temporary (:sc unsigned-reg :offset rcx-offset) rcx)

  ;; We need to stretch the lifetime of return-pc past the argument
  ;; registers so that we can default the argument registers without
  ;; trashing return-pc.
  (:temporary (:sc unsigned-reg :offset (first *register-arg-offsets*)
		   :from :eval) a0)
  (:temporary (:sc unsigned-reg :offset (second *register-arg-offsets*)
		   :from :eval) a1)
  (:temporary (:sc unsigned-reg :offset (third *register-arg-offsets*)
		   :from :eval) a2)

  (:generator 6
    (trace-table-entry trace-table-fun-epilogue)
    ;; Establish the values pointer and values count.
    (move rbx rbp-tn)
    (if (zerop nvals)
	(inst xor rcx rcx) ; smaller
      (inst mov rcx (fixnumize nvals)))
    ;; Restore the frame pointer.
    (move rbp-tn old-fp)
    ;; Clear as much of the stack as possible, but not past the return
    ;; address.
    (inst lea rsp-tn (make-ea :qword :base rbx
			      :disp (- (* (max nvals 2) n-word-bytes))))
    ;; Pre-default any argument register that need it.
    (when (< nvals register-arg-count)
      (let* ((arg-tns (nthcdr nvals (list a0 a1 a2)))
	     (first (first arg-tns)))
	(inst mov first nil-value)
	(dolist (tn (cdr arg-tns))
	  (inst mov tn first))))
    ;; And away we go. Except that return-pc is still on the
    ;; stack and we've changed the stack pointer. So we have to
    ;; tell it to index off of RBX instead of RBP.
    (cond ((zerop nvals)
	   ;; Return popping the return address and the OCFP.
	   (inst ret n-word-bytes))
	  ((= nvals 1)
	   ;; Return popping the return, leaving 1 slot. Can this
	   ;; happen, or is a single value return handled elsewhere?
	   (inst ret))
	  (t
	   (inst jmp (make-ea :qword :base rbx
			      :disp (- (* (1+ (tn-offset return-pc))
					  n-word-bytes))))))

    (trace-table-entry trace-table-normal)))

;;; Do unknown-values return of an arbitrary number of values (passed
;;; on the stack.) We check for the common case of a single return
;;; value, and do that inline using the normal single value return
;;; convention. Otherwise, we branch off to code that calls an
;;; assembly-routine.
;;;
;;; The assembly routine takes the following args:
;;;  RAX -- the return-pc to finally jump to.
;;;  RBX -- pointer to where to put the values.
;;;  RCX -- number of values to find there.
;;;  RSI -- pointer to where to find the values.
(define-vop (return-multiple)
  (:args (old-fp :to (:eval 1) :target old-fp-temp)
	 (return-pc :target rax)
	 (vals :scs (any-reg) :target rsi)
	 (nvals :scs (any-reg) :target rcx))

  (:temporary (:sc unsigned-reg :offset rax-offset :from (:argument 1)) rax)
  (:temporary (:sc unsigned-reg :offset rsi-offset :from (:argument 2)) rsi)
  (:temporary (:sc unsigned-reg :offset rcx-offset :from (:argument 3)) rcx)
  (:temporary (:sc unsigned-reg :offset rbx-offset :from (:eval 0)) rbx)
  (:temporary (:sc unsigned-reg) return-asm)
  (:temporary (:sc descriptor-reg :offset (first *register-arg-offsets*)
		   :from (:eval 0)) a0)
  (:temporary (:sc unsigned-reg :from (:eval 1)) old-fp-temp)
  (:node-var node)

  (:generator 13
    (trace-table-entry trace-table-fun-epilogue)
    ;; Load the return-pc.
    (move rax return-pc)
    (unless (policy node (> space speed))
      ;; Check for the single case.
      (let ((not-single (gen-label)))
	(inst cmp nvals (fixnumize 1))
	(inst jmp :ne not-single)
	
	;; Return with one value.
	(loadw a0 vals -1)
	;; Clear the stack. We load old-fp into a register before clearing
	;; the stack.
	(move old-fp-temp old-fp)
	(move rsp-tn rbp-tn)
	(move rbp-tn old-fp-temp)
	;; Fix the return-pc to point at the single-value entry point.
	(inst add rax 3) ; skip "mov %rbx,%rsp" insn in caller
	;; Out of here.
	(inst jmp rax)
	
	;; Nope, not the single case. Jump to the assembly routine.
	(emit-label not-single)))
    (move rsi vals)
    (move rcx nvals)
    (move rbx rbp-tn)
    (move rbp-tn old-fp)
    (inst lea return-asm
	  (make-ea :qword :disp (make-fixup 'return-multiple
					    :assembly-routine)))
    (inst jmp return-asm)
    (trace-table-entry trace-table-normal)))

;;;; XEP hackery

;;; We don't need to do anything special for regular functions.
(define-vop (setup-environment)
  (:info label)
  (:ignore label)
  (:generator 0
    ;; Don't bother doing anything.
    nil))

;;; Get the lexical environment from its passing location.
(define-vop (setup-closure-environment)
  (:results (closure :scs (descriptor-reg)))
  (:info label)
  (:ignore label)
  (:generator 6
    ;; Get result.
    (move closure rax-tn)))

;;; Copy a &MORE arg from the argument area to the end of the current
;;; frame. FIXED is the number of non-&MORE arguments.
;;;
;;; The tricky part is doing this without trashing any of the calling
;;; convention registers that are still needed. This vop is emitted
;;; directly after the xep-allocate frame. That means the registers
;;; are in use as follows:
;;;
;;;  RAX -- The lexenv.
;;;  RBX -- Available.
;;;  RCX -- The total number of arguments.
;;;  RDX -- The first arg.
;;;  RDI -- The second arg.
;;;  RSI -- The third arg.
;;;
;;; So basically, we have one register available for our use: RBX.
;;;
;;; What we can do is push the other regs onto the stack, and then
;;; restore their values by looking directly below where we put the
;;; more-args.
(define-vop (copy-more-arg)
  (:info fixed)
  (:generator 20
    ;; Avoid the copy if there are no more args.
    (cond ((zerop fixed)
	   (inst jecxz just-alloc-frame))
	  (t
	   (inst cmp rcx-tn (fixnumize fixed))
	   (inst jmp :be just-alloc-frame)))

    ;; Allocate the space on the stack.
    ;; stack = rbp - (max 3 frame-size) - (nargs - fixed)
    (inst lea rbx-tn
	  (make-ea :qword :base rbp-tn
		   :disp (- (fixnumize fixed)
			    (* n-word-bytes
			       (max 3 (sb-allocated-size 'stack))))))
    (inst sub rbx-tn rcx-tn)  ; Got the new stack in rbx
    (inst mov rsp-tn rbx-tn)

    ;; Now: nargs>=1 && nargs>fixed

    ;; Save the original count of args.
    (inst mov rbx-tn rcx-tn)

    (cond ((< fixed register-arg-count)
	   ;; We must stop when we run out of stack args, not when we
	   ;; run out of more args.
	   ;; Number to copy = nargs-3
	   (inst sub rcx-tn (fixnumize register-arg-count))
	   ;; Everything of interest in registers.
	   (inst jmp :be do-regs))
	  (t
	   ;; Number to copy = nargs-fixed
	   (inst sub rcx-tn (fixnumize fixed))))

    ;; Save rdi and rsi register args.
    (inst push rdi-tn)
    (inst push rsi-tn)
    ;; Okay, we have pushed the register args. We can trash them
    ;; now.

    ;; Initialize dst to be end of stack; skiping the values pushed
    ;; above.
    (inst lea rdi-tn (make-ea :qword :base rsp-tn :disp 16))

    ;; Initialize src to be end of args.
    (inst mov rsi-tn rbp-tn)
    (inst sub rsi-tn rbx-tn)

    (inst shr rcx-tn word-shift)	; make word count
    ;; And copy the args.
    (inst cld)				; auto-inc RSI and RDI.
    (inst rep)
    (inst movs :qword)

    ;; So now we need to restore RDI and RSI.
    (inst pop rsi-tn)
    (inst pop rdi-tn)

    DO-REGS

    ;; Restore RCX
    (inst mov rcx-tn rbx-tn)

    ;; Here: nargs>=1 && nargs>fixed
    (when (< fixed register-arg-count)
	  ;; Now we have to deposit any more args that showed up in
	  ;; registers.
	  (do ((i fixed))
	      ( nil )
	      ;; Store it relative to rbp
	      (inst mov (make-ea :qword :base rbp-tn
				 :disp (- (* n-word-bytes
					     (+ 1 (- i fixed)
						(max 3 (sb-allocated-size 'stack))))))
		    (nth i *register-arg-tns*))

	      (incf i)
	      (when (>= i register-arg-count)
		    (return))

	      ;; Don't deposit any more than there are.
	      (if (zerop i)
		  (inst test rcx-tn rcx-tn)
		(inst cmp rcx-tn (fixnumize i)))
	      (inst jmp :eq done)))

    (inst jmp done)

    JUST-ALLOC-FRAME
    (inst lea rsp-tn
	  (make-ea :qword :base rbp-tn
		   :disp (- (* n-word-bytes
			       (max 3 (sb-allocated-size 'stack))))))

    DONE))

;;; &MORE args are stored contiguously on the stack, starting
;;; immediately at the context pointer. The context pointer is not
;;; typed, so the lowtag is 0.
(define-vop (more-arg)
  (:translate %more-arg)
  (:policy :fast-safe)
  (:args (object :scs (descriptor-reg) :to :result)
	 (index :scs (any-reg) :target temp))
  (:arg-types * tagged-num)
  (:temporary (:sc unsigned-reg :from (:argument 1) :to :result) temp)
  (:results (value :scs (any-reg descriptor-reg)))
  (:result-types *)
  (:generator 5
    (move temp index)
    (inst neg temp)
    (inst mov value (make-ea :qword :base object :index temp))))

(define-vop (more-arg-c)
  (:translate %more-arg)
  (:policy :fast-safe)
  (:args (object :scs (descriptor-reg)))
  (:info index)
  (:arg-types * (:constant (signed-byte 30)))
  (:results (value :scs (any-reg descriptor-reg)))
  (:result-types *)
  (:generator 4
   (inst mov value
	 (make-ea :qword :base object :disp (- (* index n-word-bytes))))))


;;; Turn more arg (context, count) into a list.
(define-vop (listify-rest-args)
  (:translate %listify-rest-args)
  (:policy :safe)
  (:args (context :scs (descriptor-reg) :target src)
	 (count :scs (any-reg) :target rcx))
  (:arg-types * tagged-num)
  (:temporary (:sc unsigned-reg :offset rsi-offset :from (:argument 0)) src)
  (:temporary (:sc unsigned-reg :offset rcx-offset :from (:argument 1)) rcx)
  (:temporary (:sc unsigned-reg :offset rax-offset) rax)
  (:temporary (:sc unsigned-reg) dst)
  (:results (result :scs (descriptor-reg)))
  (:node-var node)
  (:generator 20
    (let ((enter (gen-label))
	  (loop (gen-label))
	  (done (gen-label)))
      (move src context)
      (move rcx count)
      ;; Check to see whether there are no args, and just return NIL if so.
      (inst mov result nil-value)
      (inst jecxz done)
      (inst lea dst (make-ea :qword :index rcx :scale 2))
      (pseudo-atomic
       (allocation dst dst node)
       (inst lea dst (make-ea :byte :base dst :disp list-pointer-lowtag))
       ;; Convert the count into a raw value, so that we can use the
       ;; LOOP instruction.
       (inst shr rcx (1- n-lowtag-bits))
       ;; Set decrement mode (successive args at lower addresses)
       (inst std)
       ;; Set up the result.
       (move result dst)
       ;; Jump into the middle of the loop, 'cause that's where we want
       ;; to start.
       (inst jmp enter)
       (emit-label loop)
       ;; Compute a pointer to the next cons.
       (inst add dst (* cons-size n-word-bytes))
       ;; Store a pointer to this cons in the CDR of the previous cons.
       (storew dst dst -1 list-pointer-lowtag)
       (emit-label enter)
       ;; Grab one value and stash it in the car of this cons.
       (inst lods rax)
       (storew rax dst 0 list-pointer-lowtag)
       ;; Go back for more.
       (inst loop loop)
       ;; NIL out the last cons.
       (storew nil-value dst 1 list-pointer-lowtag))
      (emit-label done))))

;;; Return the location and size of the &MORE arg glob created by
;;; COPY-MORE-ARG. SUPPLIED is the total number of arguments supplied
;;; (originally passed in RCX). FIXED is the number of non-rest
;;; arguments.
;;;
;;; We must duplicate some of the work done by COPY-MORE-ARG, since at
;;; that time the environment is in a pretty brain-damaged state,
;;; preventing this info from being returned as values. What we do is
;;; compute supplied - fixed, and return a pointer that many words
;;; below the current stack top.
(define-vop (more-arg-context)
  (:policy :fast-safe)
  (:translate sb!c::%more-arg-context)
  (:args (supplied :scs (any-reg) :target count))
  (:arg-types positive-fixnum (:constant fixnum))
  (:info fixed)
  (:results (context :scs (descriptor-reg))
	    (count :scs (any-reg)))
  (:result-types t tagged-num)
  (:note "more-arg-context")
  (:generator 5
    (move count supplied)
    ;; SP at this point points at the last arg pushed.
    ;; Point to the first more-arg, not above it.
    (inst lea context (make-ea :qword :base rsp-tn
			       :index count :scale 1
			       :disp (- (+ (fixnumize fixed) n-word-bytes))))
    (unless (zerop fixed)
      (inst sub count (fixnumize fixed)))))

;;; Signal wrong argument count error if NARGS isn't equal to COUNT.
(define-vop (verify-arg-count)
  (:policy :fast-safe)
  (:translate sb!c::%verify-arg-count)
  (:args (nargs :scs (any-reg)))
  (:arg-types positive-fixnum (:constant t))
  (:info count)
  (:vop-var vop)
  (:save-p :compute-only)
  (:generator 3
    (let ((err-lab
	   (generate-error-code vop invalid-arg-count-error nargs)))
      (if (zerop count)
	  (inst test nargs nargs)  ; smaller instruction
	(inst cmp nargs (fixnumize count)))
      (inst jmp :ne err-lab))))

;;; Various other error signallers.
(macrolet ((def (name error translate &rest args)
	     `(define-vop (,name)
		,@(when translate
		    `((:policy :fast-safe)
		      (:translate ,translate)))
		(:args ,@(mapcar (lambda (arg)
				   `(,arg :scs (any-reg descriptor-reg)))
				 args))
		(:vop-var vop)
		(:save-p :compute-only)
		(:generator 1000
		  (error-call vop ,error ,@args)))))
  (def arg-count-error invalid-arg-count-error
    sb!c::%arg-count-error nargs)
  (def type-check-error object-not-type-error sb!c::%type-check-error
    object type)
  (def layout-invalid-error layout-invalid-error sb!c::%layout-invalid-error
    object layout)
  (def odd-key-args-error odd-key-args-error
    sb!c::%odd-key-args-error)
  (def unknown-key-arg-error unknown-key-arg-error
    sb!c::%unknown-key-arg-error key)
  (def nil-fun-returned-error nil-fun-returned-error nil fun))
