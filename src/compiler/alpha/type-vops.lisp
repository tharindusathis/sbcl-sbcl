;;;; type testing and checking VOPs for the Alpha VM

;;;; This software is part of the SBCL system. See the README file for
;;;; more information.
;;;;
;;;; This software is derived from the CMU CL system, which was
;;;; written at Carnegie Mellon University and released into the
;;;; public domain. The software is in the public domain and is
;;;; provided with absolutely no warranty. See the COPYING and CREDITS
;;;; files for more information.

(in-package "SB!VM")

(defun %test-fixnum (value target not-p &key temp)
  (assemble ()
    (inst and value fixnum-tag-mask temp)
    (if not-p
        (inst bne temp target)
        (inst beq temp target))))

(defun %test-fixnum-and-headers (value target not-p headers &key temp)
  (let ((drop-through (gen-label)))
    (assemble ()
      (inst and value fixnum-tag-mask temp)
      (inst beq temp (if not-p drop-through target)))
    (%test-headers value target not-p nil headers
		   :drop-through drop-through :temp temp)))

(defun %test-immediate (value target not-p immediate &key temp)
  (assemble ()
    (inst and value 255 temp)
    (inst xor temp immediate temp)
    (if not-p
	(inst bne temp target)
	(inst beq temp target))))

(defun %test-lowtag (value target not-p lowtag &key temp)
  (assemble ()
    (inst and value lowtag-mask temp)
    (inst xor temp lowtag temp)
    (if not-p
	(inst bne temp target)
	(inst beq temp target))))

(defun %test-headers (value target not-p function-p headers
		      &key (drop-through (gen-label)) temp)
  (let ((lowtag (if function-p fun-pointer-lowtag other-pointer-lowtag)))
    (multiple-value-bind
	(when-true when-false)
	;; WHEN-TRUE and WHEN-FALSE are the labels to branch to when
	;; we know it's true and when we know it's false respectively.
	(if not-p
	    (values drop-through target)
	    (values target drop-through))
      (assemble ()
	(%test-lowtag value when-false t lowtag :temp temp)
	(load-type temp value (- lowtag))
	(let ((delta 0))
	  (do ((remaining headers (cdr remaining)))
	      ((null remaining))
	    (let ((header (car remaining))
		  (last (null (cdr remaining))))
	      (cond
	       ((atom header)
		(inst subq temp (- header delta) temp)
		(setf delta header)
		(if last
		    (if not-p
			(inst bne temp target)
			(inst beq temp target))
		    (inst beq temp when-true)))
	       (t
		(let ((start (car header))
		      (end (cdr header)))
		  (unless (= start bignum-widetag)
		    (inst subq temp (- start delta) temp)
		    (setf delta start)
		    (inst blt temp when-false))
		  (inst subq temp (- end delta) temp)
		  (setf delta end)
		  (if last
		      (if not-p
			  (inst bgt temp target)
			  (inst ble temp target))
		      (inst ble temp when-true))))))))
	(emit-label drop-through)))))

;;;; Type checking and testing:

(define-vop (check-type)
  (:args (value :target result :scs (any-reg descriptor-reg)))
  (:results (result :scs (any-reg descriptor-reg)))
  (:temporary (:scs (non-descriptor-reg) :to (:result 0)) temp)
  (:vop-var vop)
  (:save-p :compute-only))

(define-vop (type-predicate)
  (:args (value :scs (any-reg descriptor-reg)))
  (:temporary (:scs (non-descriptor-reg)) temp)
  (:conditional)
  (:info target not-p)
  (:policy :fast-safe))

(defun cost-to-test-types (type-codes)
  (+ (* 2 (length type-codes))
     (if (> (apply #'max type-codes) lowtag-limit) 7 2)))

(defmacro !define-type-vops (pred-name check-name ptype error-code
			     (&rest type-codes)
			     &key &allow-other-keys)
  (let ((cost (cost-to-test-types (mapcar #'eval type-codes))))
    `(progn
       ,@(when pred-name
	   `((define-vop (,pred-name type-predicate)
	       (:translate ,pred-name)
	       (:generator ,cost
		 (test-type value target not-p (,@type-codes) :temp temp)))))
       ,@(when check-name
	   `((define-vop (,check-name check-type)
	       (:generator ,cost
		 (let ((err-lab
			(generate-error-code vop ,error-code value)))
		   (test-type value err-lab t (,@type-codes) :temp temp)
		   (move value result))))))
       ,@(when ptype
	   `((primitive-type-vop ,check-name (:check) ,ptype))))))

;;;; Other integer ranges.

(defun signed-byte-32-test (value temp not-p target not-target)
  (multiple-value-bind (yep nope) (if not-p
				      (values not-target target)
				      (values target not-target))
    (assemble ()
     ;; value must be a fixnum
     (inst and value fixnum-tag-mask temp)
     (inst bne temp nope)
     ;; value must have all bits > 31 set or no bits > 31 set
     (inst sra value (+ 32 3 -1) temp)
     (inst beq temp yep)			; no bits set
     (inst not temp temp)
     (inst beq temp yep)			; all bits set
     (inst beq zero-tn nope))
    (values)))

(define-vop (signed-byte-32-p type-predicate)
  (:translate signed-byte-32-p)
  (:generator 45
    (signed-byte-32-test value temp not-p target not-target)
    NOT-TARGET))

(define-vop (check-signed-byte-32 check-type)
  (:generator 45
    (let ((loose (generate-error-code vop object-not-signed-byte-32-error value)))
      (signed-byte-32-test value temp t loose okay))
    OKAY
    (inst move value result)))

;;; A (signed-byte 64) can be represented with either fixnum or a bignum with
;;; exactly one digit.

(defun signed-byte-64-test (value temp temp1 not-p target not-target)
  (multiple-value-bind
      (yep nope)
      (if not-p
	  (values not-target target)
	  (values target not-target))
    (assemble ()
      (inst and value fixnum-tag-mask temp)
      (inst beq temp yep)
      (inst and value lowtag-mask temp)
      (inst xor temp other-pointer-lowtag temp)
      (inst bne temp nope)
      (loadw temp value 0 other-pointer-lowtag)
      (inst li (+ (ash 1 n-widetag-bits) bignum-widetag) temp1)
      (inst xor temp temp1 temp)
      (if not-p
	  (inst bne temp target)
	  (inst beq temp target))))
  (values))

(define-vop (signed-byte-64-p type-predicate)
  (:translate signed-byte-64-p)
  (:temporary (:scs (non-descriptor-reg)) temp1)
  (:generator 45
    (signed-byte-64-test value temp temp1 not-p target not-target)
    NOT-TARGET))

(define-vop (check-signed-byte-64 check-type)
  (:temporary (:scs (non-descriptor-reg)) temp1)
  (:generator 45
    (let ((loose (generate-error-code vop object-not-signed-byte-64-error
				      value)))
      (signed-byte-64-test value temp temp1 t loose okay))
    OKAY
    (inst move value result)))

(defun unsigned-byte-32-test (value temp not-p target not-target)
  (multiple-value-bind (yep nope) (if not-p
				      (values not-target target)
				      (values target not-target))
    (assemble ()
      ;; must be a fixnum with upper bits zeros
      (inst and value fixnum-tag-mask temp)
      (inst bne temp nope)
      (inst sra value (+ 32 n-fixnum-tag-bits) temp)
      (inst beq temp yep))
    (values)))

(define-vop (unsigned-byte-32-p type-predicate)
  (:translate unsigned-byte-32-p)
  (:generator 45
    (unsigned-byte-32-test value temp not-p target not-target)
    NOT-TARGET))

(define-vop (check-unsigned-byte-32 check-type)
  (:generator 56
    (let ((loose (generate-error-code vop object-not-unsigned-byte-32-error
				      value)))
      (unsigned-byte-32-test value temp t loose okay))
    OKAY
    (inst move value result)))

;;; An (unsigned-byte 64) can be represented with either a positive fixnum, a
;;; bignum with exactly one positive digit, or a bignum with exactly two digits
;;; and the second digit all zeros.

(defun unsigned-byte-64-test (value temp temp1 not-p target not-target)
  (multiple-value-bind (yep nope)
		       (if not-p
			   (values not-target target)
			   (values target not-target))
    (assemble ()
      ;; Is it a fixnum?
      (inst and value fixnum-tag-mask temp1)
      (inst move value temp)
      (inst beq temp1 fixnum)

      ;; If not, is it an other pointer?
      (inst and value lowtag-mask temp)
      (inst xor temp other-pointer-lowtag temp)
      (inst bne temp nope)
      ;; Get the header.
      (loadw temp value 0 other-pointer-lowtag)
      ;; Is it one?
      (inst li  (+ (ash 1 n-widetag-bits) bignum-widetag) temp1)
      (inst xor temp temp1 temp)
      (inst beq temp single-word)
      ;; If it's other than two, we can't be an (unsigned-byte 64)
      (inst li (logxor (+ (ash 1 n-widetag-bits) bignum-widetag)
		       (+ (ash 2 n-widetag-bits) bignum-widetag))
	    temp1)
      (inst xor temp temp1 temp)
      (inst bne temp nope)
      ;; Get the second digit.
      (loadw temp value (1+ bignum-digits-offset) other-pointer-lowtag)
      ;; All zeros, its an (unsigned-byte 64).
      (inst beq temp yep)
      (inst br zero-tn nope)
	
      SINGLE-WORD
      ;; Get the single digit.
      (loadw temp value bignum-digits-offset other-pointer-lowtag)

      ;; positive implies (unsigned-byte 64).
      FIXNUM
      (if not-p
	  (inst blt temp target)
	  (inst bge temp target))))
  (values))

(define-vop (unsigned-byte-64-p type-predicate)
  (:translate unsigned-byte-64-p)
  (:temporary (:scs (non-descriptor-reg)) temp1)
  (:generator 45
    (unsigned-byte-64-test value temp temp1 not-p target not-target)
    NOT-TARGET))

(define-vop (check-unsigned-byte-64 check-type)
  (:temporary (:scs (non-descriptor-reg)) temp1)
  (:generator 45
    (let ((loose (generate-error-code vop object-not-unsigned-byte-64-error
				      value)))
      (unsigned-byte-64-test value temp temp1 t loose okay))
    OKAY
    (move value result)))



;;;; List/symbol types:
;;; 
;;; symbolp (or symbol (eq nil))
;;; consp (and list (not (eq nil)))

(define-vop (symbolp type-predicate)
  (:translate symbolp)
  (:temporary (:scs (non-descriptor-reg)) temp)
  (:generator 12
    (inst cmpeq value null-tn temp)
    (inst bne temp (if not-p drop-thru target))
    (test-type value target not-p (symbol-header-widetag) :temp temp)
    DROP-THRU))

(define-vop (check-symbol check-type)
  (:temporary (:scs (non-descriptor-reg)) temp)
  (:generator 12
    (inst cmpeq value null-tn temp)
    (inst bne temp drop-thru)
    (let ((error (generate-error-code vop object-not-symbol-error value)))
      (test-type value error t (symbol-header-widetag) :temp temp))
    DROP-THRU
    (move value result)))
  
(define-vop (consp type-predicate)
  (:translate consp)
  (:temporary (:scs (non-descriptor-reg)) temp)
  (:generator 8
    (inst cmpeq value null-tn temp)
    (inst bne temp (if not-p target drop-thru))
    (test-type value target not-p (list-pointer-lowtag) :temp temp)
    DROP-THRU))

(define-vop (check-cons check-type)
  (:temporary (:scs (non-descriptor-reg)) temp)
  (:generator 8
    (let ((error (generate-error-code vop object-not-cons-error value)))
      (inst cmpeq value null-tn temp)
      (inst bne temp error)
      (test-type value error t (list-pointer-lowtag) :temp temp))
    (move value result)))

