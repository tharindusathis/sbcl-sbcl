;;;; This software is part of the SBCL system. See the README file for
;;;; more information.
;;;;
;;;; This software is derived from the CMU CL system, which was
;;;; written at Carnegie Mellon University and released into the
;;;; public domain. The software is in the public domain and is
;;;; provided with absolutely no warranty. See the COPYING and CREDITS
;;;; files for more information.

(in-package "SB!KERNEL")

(/show0 "entering early-defstructs.lisp")

(!set-up-structure-object-class)

#.`(progn
     ,@(mapcar (lambda (args)
		 `(defstruct ,@args))
	       (sb-cold:read-from-file "src/code/early-defstruct-args.lisp-expr")))

(/show0 "done with early-defstructs.lisp")
