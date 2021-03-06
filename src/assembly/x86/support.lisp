;;;; This software is part of the SBCL system. See the README file for
;;;; more information.
;;;;
;;;; This software is derived from the CMU CL system, which was
;;;; written at Carnegie Mellon University and released into the
;;;; public domain. The software is in the public domain and is
;;;; provided with absolutely no warranty. See the COPYING and CREDITS
;;;; files for more information.

(in-package "SB!VM")

(!def-vm-support-routine generate-call-sequence (name style vop)
  (ecase style
    ((:raw :none)
     (values
      `((inst call (make-fixup ',name :assembly-routine)))
      nil))
    (:full-call
     (values
      `((note-this-location ,vop :call-site)
	(inst call (make-fixup ',name :assembly-routine))
	(note-this-location ,vop :single-value-return)
	(move esp-tn ebx-tn))
      '((:save-p :compute-only))))))

(!def-vm-support-routine generate-return-sequence (style)
  (ecase style
    (:raw
     `(inst ret))
    (:full-call
     `(
       (inst pop eax-tn)

       (inst add eax-tn 2)
       (inst jmp eax-tn)))
    (:none)))
