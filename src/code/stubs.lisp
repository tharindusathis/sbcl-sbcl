;;;; miscellaneous primitive stubs (ordinary FDEFINITIONs for full
;;;; call defined in terms of fundamental definitions of inline
;;;; expansions)

;;;; This software is part of the SBCL system. See the README file for
;;;; more information.
;;;;
;;;; This software is derived from the CMU CL system, which was
;;;; written at Carnegie Mellon University and released into the
;;;; public domain. The software is in the public domain and is
;;;; provided with absolutely no warranty. See the COPYING and CREDITS
;;;; files for more information.

(in-package "SB!IMPL")

(macrolet ((def (name &optional (args '(x)))
	     `(defun ,name ,args (,name ,@args))))
  (def %code-code-size)
  (def %code-debug-info)
  (def %code-entry-points)
  (def %funcallable-instance-fun)
  (def %funcallable-instance-layout)
  (def %funcallable-instance-lexenv)
  (def %set-funcallable-instance-fun (fin new-val)))

(defun %caller-frame-and-pc ()
  (%caller-frame-and-pc))
