;;;; This file contains compiler code and compiler-related stuff which
;;;; can be built early on. Some of the stuff may be here because it's
;;;; needed early on, some other stuff (e.g. constants) just because
;;;; it might as well be done early so we don't have to think about
;;;; whether it's done early enough.

;;;; This software is part of the SBCL system. See the README file for
;;;; more information.
;;;;
;;;; This software is derived from the CMU CL system, which was
;;;; written at Carnegie Mellon University and released into the
;;;; public domain. The software is in the public domain and is
;;;; provided with absolutely no warranty. See the COPYING and CREDITS
;;;; files for more information.

(in-package "SB!C")

;;; ANSI limits on compilation
(def!constant sb!xc:call-arguments-limit most-positive-fixnum
  #!+sb-doc
  "The exclusive upper bound on the number of arguments which may be passed
  to a function, including &REST args.")
(def!constant sb!xc:lambda-parameters-limit most-positive-fixnum
  #!+sb-doc
  "The exclusive upper bound on the number of parameters which may be specifed
  in a given lambda list. This is actually the limit on required and &OPTIONAL
  parameters. With &KEY and &AUX you can get more.")
(def!constant sb!xc:multiple-values-limit most-positive-fixnum
  #!+sb-doc
  "The exclusive upper bound on the number of multiple VALUES that you can
  return.")

(defconstant-eqx sb!xc:lambda-list-keywords
  '(&allow-other-keys
    &aux
    &body
    &environment
    &key
    &more
    &optional
    &rest
    &whole)
  #'equal
  #!+sb-doc
  "symbols which are magical in a lambda list")

;;;; cross-compiler-only versions of CL special variables, so that we
;;;; don't have weird interactions with the host compiler

(defvar sb!xc:*compile-file-pathname*)
(defvar sb!xc:*compile-file-truename*)
(defvar sb!xc:*compile-print*)
(defvar sb!xc:*compile-verbose*)

;;;; miscellaneous types used both in the cross-compiler and on the target

;;;; FIXME: The INDEX and LAYOUT-DEPTHOID definitions probably belong
;;;; somewhere else, not "early-c", since they're after all not part
;;;; of the compiler.

;;; the type of LAYOUT-DEPTHOID slot values
(def!type sb!kernel::layout-depthoid () '(or index (integer -1 -1)))

;;; possible values for the INLINE-ness of a function.
(deftype inlinep ()
  '(member :inline :maybe-inline :notinline nil))
(defparameter *inlinep-translations*
  '((inline . :inline)
    (notinline . :notinline)
    (maybe-inline . :maybe-inline)))

;;; the lexical environment we are currently converting in
(defvar *lexenv*)
(declaim (type lexenv *lexenv*))

;;; *FREE-VARS* translates from the names of variables referenced
;;; globally to the LEAF structures for them. *FREE-FUNS* is like
;;; *FREE-VARS*, only it deals with function names.
(defvar *free-vars*)
(defvar *free-funs*)
(declaim (type hash-table *free-vars* *free-funs*))

;;; We use the same CONSTANT structure to represent all equal anonymous
;;; constants. This hashtable translates from constants to the LEAFs that
;;; represent them.
(defvar *constants*)
(declaim (type hash-table *constants*))

;;; *ALLOW-INSTRUMENTING* controls whether we should allow the
;;; insertion of instrumenting code (like a (CATCH ...)) around code
;;; to allow the debugger RETURN and STEP commands to function (we
;;; disallow it for internal stuff).
(defvar *allow-instrumenting*)

;;; miscellaneous forward declarations
(defvar *code-segment*)
#!+sb-dyncount (defvar *collect-dynamic-statistics*)
(defvar *component-being-compiled*)
(defvar *compiler-error-context*)
(defvar *compiler-error-count*)
(defvar *compiler-warning-count*)
(defvar *compiler-style-warning-count*)
(defvar *compiler-note-count*)
(defvar *compiler-trace-output*)
(defvar *constraint-number*)
(defvar *count-vop-usages*)
(defvar *current-path*)
(defvar *current-component*)
(defvar *delayed-ir1-transforms*)
(defvar *handled-conditions*)
(defvar *disabled-package-locks*)
(defvar *policy*)
(defvar *dynamic-counts-tn*)
(defvar *elsewhere*)
(defvar *event-info*)
(defvar *event-note-threshold*)
(defvar *failure-p*)
(defvar *fixup-notes*)
(defvar *in-pack*)
(defvar *info-environment*)
(defvar *lexenv*)
(defvar *source-info*)
(defvar *trace-table*)
(defvar *undefined-warnings*)
(defvar *warnings-p*)

;;; This lock is seized in the compiler, and related areas: the
;;; compiler is not presently thread-safe
(defvar *big-compiler-lock*
  (sb!thread:make-mutex :name "big compiler lock"))

;;; unique ID for the next object created (to let us track object
;;; identity even across GC, useful for understanding weird compiler
;;; bugs where something is supposed to be unique but is instead
;;; exists as duplicate objects)
#!+sb-show
(progn
  (defvar *object-id-counter* 0)
  (defun new-object-id ()
    (prog1
	*object-id-counter*
      (incf *object-id-counter*))))

;;;; miscellaneous utilities

;;; Delete any undefined warnings for NAME and KIND. This is for the
;;; benefit of the compiler, but it's sometimes called from stuff like
;;; type-defining code which isn't logically part of the compiler.
(declaim (ftype (function ((or symbol cons) keyword) (values))
		note-name-defined))
(defun note-name-defined (name kind)
  ;; We do this BOUNDP check because this function can be called when
  ;; not in a compilation unit (as when loading top level forms).
  (when (boundp '*undefined-warnings*)
    (setq *undefined-warnings*
	  (delete-if (lambda (x)
		       (and (equal (undefined-warning-name x) name)
			    (eq (undefined-warning-kind x) kind)))
		     *undefined-warnings*)))
  (values))

;;; to be called when a variable is lexically bound
(declaim (ftype (function (symbol) (values)) note-lexical-binding))
(defun note-lexical-binding (symbol)
    ;; This check is intended to protect us from getting silently
    ;; burned when we define
    ;;   foo.lisp:
    ;;     (DEFVAR *FOO* -3)
    ;;     (DEFUN FOO (X) (+ X *FOO*))
    ;;   bar.lisp:
    ;;     (DEFUN BAR (X)
    ;;       (LET ((*FOO* X))
    ;;         (FOO 14)))
    ;; and then we happen to compile bar.lisp before foo.lisp.
  (when (looks-like-name-of-special-var-p symbol)
    ;; FIXME: should be COMPILER-STYLE-WARNING?
    (style-warn "using the lexical binding of the symbol ~S, not the~@
dynamic binding, even though the symbol name follows the usual naming~@
convention (names like *FOO*) for special variables" symbol))
  (values))

;;; Hacky (duplicating machinery found elsewhere because this function
;;; turns out to be on a critical path in the compiler) shorthand for
;;; creating debug names from source names or other stems, e.g.
;;;
;;;   (DEBUG-NAMIFY "FLET " SOURCE-NAME) -> "FLET FOO:BAR"
;;;   (DEBUG-NAMIFY "top level form " FORM) -> "top level form (QUUX :FOO)"
;;;
;;; If ALT is given it must be a string -- it is then used in place of
;;; either HEAD or TAIL if either of them is EQ to SB-C::.ANONYMOUS. 
;;;
(declaim (inline debug-namify))
(defun debug-namify (head tail &optional alt)
  (declare (type (or null string) alt))
  (flet ((symbol-debug-name (symbol)
	   ;; KLUDGE: (OAOOM warning) very much akin to OUTPUT-SYMBOL.
	   (if (and alt (eq '.anonymous. symbol))
	       alt
	       (let ((package (symbol-package symbol))
		     (name (symbol-name symbol)))
		 (cond
		   ((eq package *keyword-package*)
		    (concatenate 'string ":" name))
		   ((eq package *cl-package*)
		    name)
		   ((null package)
		    (concatenate 'string "#:" name))
		   (t
		    (multiple-value-bind (symbol status) 
			(find-symbol name package)
		      (declare (ignore symbol))
		      (concatenate 'string 
				   (package-name package)
				   (if (eq status :external) ":" "::")
				   name))))))))
    (cond ((and (stringp head) (stringp tail))
	   (concatenate 'string head tail))
	  ((and (stringp head) (symbolp tail))
	   (concatenate 'string head (symbol-debug-name tail)))
	  ((and (symbolp head) (stringp tail))
	   (concatenate 'string (symbol-debug-name head) tail))
	  (t
	   (macrolet ((out (obj s)
			`(typecase ,obj
			  (string (write-string ,obj ,s))
			  (symbol (write-string (symbol-debug-name ,obj) ,s))
			  (t (prin1 ,obj ,s)))))
	     (with-standard-io-syntax
	       (let ((*print-readably* nil)
		     (*print-pretty* nil)
		     (*package* *cl-package*)
		     (*print-length* 3)
		     (*print-level* 2))
		 (with-output-to-string (s)
		   (out head s)
		   (out tail s)))))))))
