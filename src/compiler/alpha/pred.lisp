;;;; the VM definition of predicate VOPs for the Alpha

;;;; This software is part of the SBCL system. See the README file for
;;;; more information.
;;;;
;;;; This software is derived from the CMU CL system, which was
;;;; written at Carnegie Mellon University and released into the
;;;; public domain. The software is in the public domain and is
;;;; provided with absolutely no warranty. See the COPYING and CREDITS
;;;; files for more information.

(in-package "SB!VM")

;;;; the Branch VOP

;;; The unconditional branch, emitted when we can't drop through to
;;; the desired destination. Dest is the continuation we transfer
;;; control to.
(define-vop (branch)
  (:info dest)
  (:generator 5
    (inst br zero-tn dest)))

;;;; conditional VOPs

(define-vop (if-eq)
  (:args (x :scs (any-reg descriptor-reg zero null))
	 (y :scs (any-reg descriptor-reg zero null)))
  (:conditional)
  (:temporary (:scs (non-descriptor-reg)) temp)
  (:info target not-p)
  (:policy :fast-safe)
  (:translate eq)
  (:generator 3
    (inst cmpeq x y temp)
    (if not-p
	(inst beq temp target)
	(inst bne temp target))))
