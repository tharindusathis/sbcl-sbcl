;;;; the MIPS VM definition of SAP operations

;;;; This software is part of the SBCL system. See the README file for
;;;; more information.
;;;;
;;;; This software is derived from the CMU CL system, which was
;;;; written at Carnegie Mellon University and released into the
;;;; public domain. The software is in the public domain and is
;;;; provided with absolutely no warranty. See the COPYING and CREDITS
;;;; files for more information.

(in-package "SB!VM")

;;;; Moves and coercions:

;;; Move a tagged SAP to an untagged representation.
(define-vop (move-to-sap)
  (:args (x :scs (descriptor-reg)))
  (:results (y :scs (sap-reg)))
  (:note "system area pointer indirection")
  (:generator 1
    (loadw y x sap-pointer-slot other-pointer-lowtag)))

(define-move-vop move-to-sap :move
  (descriptor-reg) (sap-reg))

;;; Move an untagged SAP to a tagged representation.
(define-vop (move-from-sap)
  (:args (x :scs (sap-reg) :target sap))
  (:temporary (:scs (sap-reg) :from (:argument 0)) sap)
  (:temporary (:scs (non-descriptor-reg)) ndescr)
  (:temporary (:sc non-descriptor-reg :offset nl4-offset) pa-flag)
  (:results (y :scs (descriptor-reg)))
  (:note "system area pointer allocation")
  (:generator 20
    (move sap x)
    (with-fixed-allocation (y pa-flag ndescr sap-widetag sap-size)
      (storew sap y sap-pointer-slot other-pointer-lowtag))))

(define-move-vop move-from-sap :move
  (sap-reg) (descriptor-reg))

;;; Move untagged sap values.
(define-vop (sap-move)
  (:args (x :target y
	    :scs (sap-reg)
	    :load-if (not (location= x y))))
  (:results (y :scs (sap-reg)
	       :load-if (not (location= x y))))
  (:effects)
  (:affected)
  (:generator 0
    (move y x)))

(define-move-vop sap-move :move
  (sap-reg) (sap-reg))

;;; Move untagged sap arguments/return-values.
(define-vop (move-sap-arg)
  (:args (x :target y
	    :scs (sap-reg))
	 (fp :scs (any-reg)
	     :load-if (not (sc-is y sap-reg))))
  (:results (y))
  (:generator 0
    (sc-case y
      (sap-reg
       (move y x))
      (sap-stack
       (storew x fp (tn-offset y))))))

(define-move-vop move-sap-arg :move-arg
  (descriptor-reg sap-reg) (sap-reg))

;;; Use standard MOVE-ARG + coercion to move an untagged sap to a
;;; descriptor passing location.
(define-move-vop move-arg :move-arg
  (sap-reg) (descriptor-reg))

;;;; SAP-INT and INT-SAP
(define-vop (sap-int)
  (:args (sap :scs (sap-reg) :target int))
  (:arg-types system-area-pointer)
  (:results (int :scs (unsigned-reg)))
  (:result-types unsigned-num)
  (:translate sap-int)
  (:policy :fast-safe)
  (:generator 1
    (move int sap)))

(define-vop (int-sap)
  (:args (int :scs (unsigned-reg) :target sap))
  (:arg-types unsigned-num)
  (:results (sap :scs (sap-reg)))
  (:result-types system-area-pointer)
  (:translate int-sap)
  (:policy :fast-safe)
  (:generator 1
    (move sap int)))

;;;; POINTER+ and POINTER-
(define-vop (pointer+)
  (:translate sap+)
  (:args (ptr :scs (sap-reg))
	 (offset :scs (signed-reg immediate)))
  (:arg-types system-area-pointer signed-num)
  (:results (res :scs (sap-reg)))
  (:result-types system-area-pointer)
  (:policy :fast-safe)
  (:generator 1
    (sc-case offset
      (signed-reg
       (inst addu res ptr offset))
      (immediate
       (inst addu res ptr (tn-value offset))))))

(define-vop (pointer-)
  (:translate sap-)
  (:args (ptr1 :scs (sap-reg))
	 (ptr2 :scs (sap-reg)))
  (:arg-types system-area-pointer system-area-pointer)
  (:policy :fast-safe)
  (:results (res :scs (signed-reg)))
  (:result-types signed-num)
  (:generator 1
    (inst subu res ptr1 ptr2)))

;;;; mumble-SYSTEM-REF and mumble-SYSTEM-SET
(macrolet ((def-system-ref-and-set
	  (ref-name set-name sc type size &optional signed)
  (let ((ref-name-c (symbolicate ref-name "-C"))
	(set-name-c (symbolicate set-name "-C")))
    `(progn
       (define-vop (,ref-name)
	 (:translate ,ref-name)
	 (:policy :fast-safe)
	 (:args (object :scs (sap-reg) :target sap)
		(offset :scs (signed-reg)))
	 (:arg-types system-area-pointer signed-num)
	 (:results (result :scs (,sc)))
	 (:result-types ,type)
	 (:temporary (:scs (sap-reg) :from (:argument 0)) sap)
	 (:generator 5
	   (inst addu sap object offset)
	   ,@(ecase size
	       (:byte
		(if signed
		    '((inst lb result sap 0))
		    '((inst lbu result sap 0))))
		 (:short
		  (if signed
		      '((inst lh result sap 0))
		      '((inst lhu result sap 0))))
		 (:long
		  '((inst lw result sap 0)))
		 (:single
		  '((inst lwc1 result sap 0)))
		 (:double
		  (ecase *backend-byte-order*
		    (:big-endian
		     '((inst lwc1 result sap n-word-bytes)
		       (inst lwc1-odd result sap 0)))
		    (:little-endian
		     '((inst lwc1 result sap 0)
		       (inst lwc1-odd result sap n-word-bytes))))))
	   (inst nop)))
       (define-vop (,ref-name-c)
	 (:translate ,ref-name)
	 (:policy :fast-safe)
	 (:args (object :scs (sap-reg)))
	 (:arg-types system-area-pointer
		     (:constant ,(if (eq size :double)
				     ;; We need to be able to add 4.
				     `(integer ,(- (ash 1 16))
					       ,(- (ash 1 16) 5))
				     '(signed-byte 16))))
	 (:info offset)
	 (:results (result :scs (,sc)))
	 (:result-types ,type)
	 (:generator 4
	   ,@(ecase size
	       (:byte
		(if signed
		    '((inst lb result object offset))
		    '((inst lbu result object offset))))
	       (:short
		(if signed
		    '((inst lh result object offset))
		    '((inst lhu result object offset))))
	       (:long
		'((inst lw result object offset)))
	       (:single
		'((inst lwc1 result object offset)))
	       (:double
		(ecase *backend-byte-order*
		  (:big-endian
		   '((inst lwc1 result object (+ offset n-word-bytes))
		     (inst lwc1-odd result object offset)))
		  (:little-endian
		   '((inst lwc1 result object offset)
		     (inst lwc1-odd result object (+ offset n-word-bytes)))))))
	   (inst nop)))
       (define-vop (,set-name)
	 (:translate ,set-name)
	 (:policy :fast-safe)
	 (:args (object :scs (sap-reg) :target sap)
		(offset :scs (signed-reg))
		(value :scs (,sc) :target result))
	 (:arg-types system-area-pointer signed-num ,type)
	 (:results (result :scs (,sc)))
	 (:result-types ,type)
	 (:temporary (:scs (sap-reg) :from (:argument 0)) sap)
	 (:generator 5
	   (inst addu sap object offset)
	   ,@(ecase size
	       (:byte
		'((inst sb value sap 0)
		  (move result value)))
	       (:short
		'((inst sh value sap 0)
		  (move result value)))
	       (:long
		'((inst sw value sap 0)
		  (move result value)))
	       (:single
		'((inst swc1 value sap 0)
		  (unless (location= result value)
		    (inst fmove :single result value))))
	       (:double
		(ecase *backend-byte-order*
		  (:big-endian
		   '((inst swc1 value sap n-word-bytes)
		     (inst swc1-odd value sap 0)
		     (unless (location= result value)
		       (inst fmove :double result value))))
		  (:little-endian
		   '((inst swc1 value sap 0)
		     (inst swc1-odd value sap n-word-bytes)
		     (unless (location= result value)
		       (inst fmove :double result value)))))))))
       (define-vop (,set-name-c)
	 (:translate ,set-name)
	 (:policy :fast-safe)
	 (:args (object :scs (sap-reg))
		(value :scs (,sc) :target result))
	 (:arg-types system-area-pointer
		     (:constant ,(if (eq size :double)
				     ;; We need to be able to add 4.
				     `(integer ,(- (ash 1 16))
					       ,(- (ash 1 16) 5))
				     '(signed-byte 16)))
		     ,type)
	 (:info offset)
	 (:results (result :scs (,sc)))
	 (:result-types ,type)
	 (:generator 5
	   ,@(ecase size
	       (:byte
		'((inst sb value object offset)
		  (move result value)))
	       (:short
		'((inst sh value object offset)
		  (move result value)))
	       (:long
		'((inst sw value object offset)
		  (move result value)))
	       (:single
		'((inst swc1 value object offset)
		  (unless (location= result value)
		    (inst fmove :single result value))))
	       (:double
		(ecase *backend-byte-order*
		  (:big-endian
		   '((inst swc1 value object (+ offset n-word-bytes))
		     (inst swc1-odd value object (+ offset n-word-bytes))
		     (unless (location= result value)
		       (inst fmove :double result value))))
		  (:little-endian
		   '((inst swc1 value object offset)
		     (inst swc1-odd value object (+ offset n-word-bytes))
		     (unless (location= result value)
		       (inst fmove :double result value)))))))))))))
  (def-system-ref-and-set sap-ref-8 %set-sap-ref-8
    unsigned-reg positive-fixnum :byte nil)
  (def-system-ref-and-set signed-sap-ref-8 %set-signed-sap-ref-8
    signed-reg tagged-num :byte t)
  (def-system-ref-and-set sap-ref-16 %set-sap-ref-16
    unsigned-reg positive-fixnum :short nil)
  (def-system-ref-and-set signed-sap-ref-16 %set-signed-sap-ref-16
    signed-reg tagged-num :short t)
  (def-system-ref-and-set sap-ref-32 %set-sap-ref-32
    unsigned-reg unsigned-num :long nil)
  (def-system-ref-and-set signed-sap-ref-32 %set-signed-sap-ref-32
    signed-reg signed-num :long t)
  (def-system-ref-and-set sap-ref-sap %set-sap-ref-sap
    sap-reg system-area-pointer :long)
  (def-system-ref-and-set sap-ref-single %set-sap-ref-single
    single-reg single-float :single)
  (def-system-ref-and-set sap-ref-double %set-sap-ref-double
    double-reg double-float :double))

;;; Noise to convert normal lisp data objects into SAPs.
(define-vop (vector-sap)
  (:translate vector-sap)
  (:policy :fast-safe)
  (:args (vector :scs (descriptor-reg)))
  (:results (sap :scs (sap-reg)))
  (:result-types system-area-pointer)
  (:generator 2
    (inst addu sap vector
	  (- (* vector-data-offset n-word-bytes) other-pointer-lowtag))))

;;; Transforms for 64-bit SAP accessors.
#!+little-endian
(progn
  (deftransform sap-ref-64 ((sap offset) (* *))
    '(logior (sap-ref-32 sap offset)
	     (ash (sap-ref-32 sap (+ offset 4)) 32)))
  (deftransform signed-sap-ref-64 ((sap offset) (* *))
    '(logior (sap-ref-32 sap offset)
	     (ash (signed-sap-ref-32 sap (+ offset 4)) 32)))
  (deftransform %set-sap-ref-64 ((sap offset value) (* * *))
    '(progn
       (%set-sap-ref-32 sap offset (logand value #xffffffff))
       (%set-sap-ref-32 sap (+ offset 4) (ash value -32))))
  (deftransform %set-signed-sap-ref-64 ((sap offset value) (* * *))
    '(progn
       (%set-sap-ref-32 sap offset (logand value #xffffffff))
       (%set-signed-sap-ref-32 sap (+ offset 4) (ash value -32)))))
#!-little-endian
(progn
  (deftransform sap-ref-64 ((sap offset) (* *))
    '(logior (ash (sap-ref-32 sap offset) 32)
	     (sap-ref-32 sap (+ offset 4))))
  (deftransform signed-sap-ref-64 ((sap offset) (* *))
    '(logior (ash (signed-sap-ref-32 sap offset) 32)
	     (sap-ref-32 sap (+ 4 offset))))
  (deftransform %set-sap-ref-64 ((sap offset value) (* * *))
    '(progn
       (%set-sap-ref-32 sap offset (ash value -32))
       (%set-sap-ref-32 sap (+ offset 4) (logand value #xffffffff))))
  (deftransform %set-signed-sap-ref-64 ((sap offset value) (* * *))
    '(progn
       (%set-signed-sap-ref-32 sap offset (ash value -32))
       (%set-sap-ref-32 sap (+ 4 offset) (logand value #xffffffff)))))

