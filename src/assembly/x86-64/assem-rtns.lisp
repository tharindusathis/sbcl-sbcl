;;;; the machine specific support routines needed by the file assembler

;;;; This software is part of the SBCL system. See the README file for
;;;; more information.
;;;;
;;;; This software is derived from the CMU CL system, which was
;;;; written at Carnegie Mellon University and released into the
;;;; public domain. The software is in the public domain and is
;;;; provided with absolutely no warranty. See the COPYING and CREDITS
;;;; files for more information.

(in-package "SB!VM")

;;;; RETURN-MULTIPLE

;;; For RETURN-MULTIPLE, we have to move the results from the end of
;;; the frame for the function that is returning to the end of the
;;; frame for the function being returned to.

#+sb-assembling ;; We don't want a vop for this one.
(define-assembly-routine
    (return-multiple (:return-style :none))
    (;; These four are really arguments.
     (:temp eax unsigned-reg rax-offset)
     (:temp ebx unsigned-reg rbx-offset)
     (:temp ecx unsigned-reg rcx-offset)
     (:temp esi unsigned-reg rsi-offset)

     ;; These we need as temporaries.
     (:temp edx unsigned-reg rdx-offset)
     (:temp edi unsigned-reg rdi-offset))

  ;; Pick off the cases where everything fits in register args.
  (inst jecxz zero-values)
  (inst cmp ecx (fixnumize 1))
  (inst jmp :e one-value)
  (inst cmp ecx (fixnumize 2))
  (inst jmp :e two-values)
  (inst cmp ecx (fixnumize 3))
  (inst jmp :e three-values)

  ;; Save the count, because the loop is going to destroy it.
  (inst mov edx ecx)

  ;; Blit the values down the stack. Note: there might be overlap, so
  ;; we have to be careful not to clobber values before we've read
  ;; them. Because the stack builds down, we are coping to a larger
  ;; address. Therefore, we need to iterate from larger addresses to
  ;; smaller addresses. pfw-this says copy ecx words from esi to edi
  ;; counting down.
  (inst shr ecx 3)			; fixnum to raw word count
  (inst std)				; count down
  (inst sub esi 8)			; ?
  (inst lea edi (make-ea :qword :base ebx :disp (- n-word-bytes)))
  (inst rep)
  (inst movs :qword)

  ;; Restore the count.
  (inst mov ecx edx)

  ;; Set the stack top to the last result.
  (inst lea rsp-tn (make-ea :qword :base edi :disp n-word-bytes))

  ;; Load the register args.
  (loadw edx ebx -1)
  (loadw edi ebx -2)
  (loadw esi ebx -3)

  ;; And back we go.
  (inst jmp eax)

  ;; Handle the register arg cases.
  ZERO-VALUES
  (move rsp-tn ebx)
  (inst mov edx nil-value)
  (inst mov edi edx)
  (inst mov esi edx)
  (inst jmp eax)

  ONE-VALUE ; Note: we can get this, because the return-multiple vop
	    ; doesn't check for this case when size > speed.
  (loadw edx esi -1)
  (inst mov rsp-tn ebx)
  (inst add eax 3)
  (inst jmp eax)

  TWO-VALUES
  (loadw edx esi -1)
  (loadw edi esi -2)
  (inst mov esi nil-value)
  (inst lea rsp-tn (make-ea :qword :base ebx :disp (* -2 n-word-bytes)))
  (inst jmp eax)

  THREE-VALUES
  (loadw edx esi -1)
  (loadw edi esi -2)
  (loadw esi esi -3)
  (inst lea rsp-tn (make-ea :qword :base ebx :disp (* -3 n-word-bytes)))
  (inst jmp eax))

;;;; TAIL-CALL-VARIABLE

;;; For tail-call-variable, we have to copy the arguments from the end
;;; of our stack frame (were args are produced) to the start of our
;;; stack frame (were args are expected).
;;;
;;; We take the function to call in EAX and a pointer to the arguments in
;;; ESI. EBP says the same over the jump, and the old frame pointer is
;;; still saved in the first stack slot. The return-pc is saved in
;;; the second stack slot, so we have to push it to make it look like
;;; we actually called. We also have to compute ECX from the difference
;;; between ESI and the stack top.
#+sb-assembling ;; No vop for this one either.
(define-assembly-routine
    (tail-call-variable
     (:return-style :none))

    ((:temp eax unsigned-reg rax-offset)
     (:temp ebx unsigned-reg rbx-offset)
     (:temp ecx unsigned-reg rcx-offset)
     (:temp edx unsigned-reg rdx-offset)
     (:temp edi unsigned-reg rdi-offset)
     (:temp esi unsigned-reg rsi-offset))

  ;; Calculate NARGS (as a fixnum)
  (move ecx esi)
  (inst sub ecx rsp-tn)

  ;; Check for all the args fitting the the registers.
  (inst cmp ecx (fixnumize 3))
  (inst jmp :le REGISTER-ARGS)

  ;; Save the OLD-FP and RETURN-PC because the blit it going to trash
  ;; those stack locations. Save the ECX, because the loop is going
  ;; to trash it.
  (pushw rbp-tn -1)
  (loadw ebx rbp-tn -2)
  (inst push ecx)

  ;; Do the blit. Because we are coping from smaller addresses to
  ;; larger addresses, we have to start at the largest pair and work
  ;; our way down.
  (inst shr ecx 3)			; fixnum to raw words
  (inst std)				; count down
  (inst lea edi (make-ea :qword :base rbp-tn :disp (- n-word-bytes)))
  (inst sub esi (fixnumize 1))
  (inst rep)
  (inst movs :qword)

  ;; Load the register arguments carefully.
  (loadw edx rbp-tn -1)

  ;; Restore OLD-FP and ECX.
  (inst pop ecx)
  (popw rbp-tn -1)			; overwrites a0

  ;; Blow off the stack above the arguments.
  (inst lea rsp-tn (make-ea :qword :base edi :disp n-word-bytes))

  ;; remaining register args
  (loadw edi rbp-tn -2)
  (loadw esi rbp-tn -3)

  ;; Push the (saved) return-pc so it looks like we just called.
  (inst push ebx)

  ;; And jump into the function.
    (inst jmp
	  (make-ea :byte :base eax
		   :disp (- (* closure-fun-slot n-word-bytes)
			    fun-pointer-lowtag)))

  ;; All the arguments fit in registers, so load them.
  REGISTER-ARGS
  (loadw edx esi -1)
  (loadw edi esi -2)
  (loadw esi esi -3)

  ;; Clear most of the stack.
  (inst lea rsp-tn
	(make-ea :qword :base rbp-tn :disp (* -3 n-word-bytes)))

  ;; Push the return-pc so it looks like we just called.
  (pushw rbp-tn -2)    ; XXX dan ? 
  
  ;; And away we go.
  (inst jmp (make-ea :byte :base eax
		     :disp (- (* closure-fun-slot n-word-bytes)
			      fun-pointer-lowtag))))

(define-assembly-routine (throw
			  (:return-style :none))
			 ((:arg target (descriptor-reg any-reg) rdx-offset)
			  (:arg start any-reg rbx-offset)
			  (:arg count any-reg rcx-offset)
			  (:temp catch any-reg rax-offset))

  (declare (ignore start count))

  (load-tl-symbol-value catch *current-catch-block*)

  LOOP

  (let ((error (generate-error-code nil unseen-throw-tag-error target)))
    (inst or catch catch)		; check for NULL pointer
    (inst jmp :z error))

  (inst cmp target (make-ea-for-object-slot catch catch-block-tag-slot 0))
  (inst jmp :e exit)

  (loadw catch catch catch-block-previous-catch-slot)
  (inst jmp loop)

  EXIT

  ;; Here EAX points to catch block containing symbol pointed to by EDX.
  (inst jmp (make-fixup 'unwind :assembly-routine)))

;;;; non-local exit noise

(define-assembly-routine (unwind
			  (:return-style :none)
			  (:translate %continue-unwind)
			  (:policy :fast-safe))
			 ((:arg block (any-reg descriptor-reg) rax-offset)
			  (:arg start (any-reg descriptor-reg) rbx-offset)
			  (:arg count (any-reg descriptor-reg) rcx-offset)
			  (:temp uwp unsigned-reg rsi-offset))
  (declare (ignore start count))

  (let ((error (generate-error-code nil invalid-unwind-error)))
    (inst or block block)		; check for NULL pointer
    (inst jmp :z error))

  (load-tl-symbol-value uwp *current-unwind-protect-block*)

  ;; Does *CURRENT-UNWIND-PROTECT-BLOCK* match the value stored in
  ;; argument's CURRENT-UWP-SLOT?
  (inst cmp uwp
	(make-ea-for-object-slot block unwind-block-current-uwp-slot 0))
  ;; If a match, return to context in arg block.
  (inst jmp :e do-exit)

  ;; Not a match - return to *CURRENT-UNWIND-PROTECT-BLOCK* context.
  ;; Important! Must save (and return) the arg 'block' for later use!!
  (move rdx-tn block)
  (move block uwp)
  ;; Set next unwind protect context.
  (loadw uwp uwp unwind-block-current-uwp-slot)
  ;; we're about to reload ebp anyway, so let's borrow it here as a
  ;; temporary.  Hope this works
  (store-tl-symbol-value uwp *current-unwind-protect-block* rbp-tn)

  DO-EXIT

  (loadw rbp-tn block unwind-block-current-cont-slot)

  ;; Uwp-entry expects some things in known locations so that they can
  ;; be saved on the stack: the block in edx-tn, start in ebx-tn, and
  ;; count in ecx-tn.

  (inst jmp (make-ea :byte :base block
		     :disp (* unwind-block-entry-pc-slot n-word-bytes))))
