;;;; Do whatever is necessary to make the given code component
;;;; executable.

;;;; This software is part of the SBCL system. See the README file for
;;;; more information.
;;;;
;;;; While most of SBCL is derived from the CMU CL system, the test
;;;; files (like this one) were written from scratch after the fork
;;;; from CMU CL.
;;;; 
;;;; This software is in the public domain and is provided with
;;;; absolutely no warranty. See the COPYING and CREDITS files for
;;;; more information.

(in-package :sb!vm)

(defun sanctify-for-execution (component)
  (declare (ignore component))
  (sb!sys:%primitive istream-memory-barrier))
