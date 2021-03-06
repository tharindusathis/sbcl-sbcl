;;;; the top level interfaces to the compiler, plus some other
;;;; compiler-related stuff (e.g. CL:CALL-ARGUMENTS-LIMIT) which
;;;; doesn't obviously belong anywhere else

;;;; This software is part of the SBCL system. See the README file for
;;;; more information.
;;;;
;;;; This software is derived from the CMU CL system, which was
;;;; written at Carnegie Mellon University and released into the
;;;; public domain. The software is in the public domain and is
;;;; provided with absolutely no warranty. See the COPYING and CREDITS
;;;; files for more information.

(in-package "SB!C")

;;; FIXME: Doesn't this belong somewhere else, like early-c.lisp?
(declaim (special *constants* *free-vars* *component-being-compiled*
		  *code-vector* *next-location* *result-fixups*
		  *free-funs* *source-paths*
		  *seen-blocks* *seen-funs* *list-conflicts-table*
		  *continuation-number* *continuation-numbers*
		  *number-continuations* *tn-id* *tn-ids* *id-tns*
		  *label-ids* *label-id* *id-labels*
		  *undefined-warnings* *compiler-error-count*
		  *compiler-warning-count* *compiler-style-warning-count*
		  *compiler-note-count*
		  *compiler-error-bailout*
		  #!+sb-show *compiler-trace-output*
		  *last-source-context* *last-original-source*
		  *last-source-form* *last-format-string* *last-format-args*
		  *last-message-count* *lexenv* *fun-names-in-this-file*
                  *allow-instrumenting*))

;;; Whether call of a function which cannot be defined causes a full
;;; warning.
(defvar *flame-on-necessarily-undefined-function* nil)

(defvar *check-consistency* nil)
(defvar *all-components*)

;;; Set to NIL to disable loop analysis for register allocation. 
(defvar *loop-analyze* t)

;;; Bind this to a stream to capture various internal debugging output.
(defvar *compiler-trace-output* nil)

;;; The current block compilation state. These are initialized to the
;;; :BLOCK-COMPILE and :ENTRY-POINTS arguments that COMPILE-FILE was
;;; called with.
;;;
;;; *BLOCK-COMPILE-ARG* holds the original value of the :BLOCK-COMPILE
;;; argument, which overrides any internal declarations.
(defvar *block-compile*)
(defvar *block-compile-arg*)
(declaim (type (member nil t :specified) *block-compile* *block-compile-arg*))
(defvar *entry-points*)
(declaim (list *entry-points*))

;;; When block compiling, used by PROCESS-FORM to accumulate top level
;;; lambdas resulting from compiling subforms. (In reverse order.)
(defvar *toplevel-lambdas*)
(declaim (list *toplevel-lambdas*))

(defvar sb!xc:*compile-verbose* t
  #!+sb-doc
  "The default for the :VERBOSE argument to COMPILE-FILE.")
(defvar sb!xc:*compile-print* t
  #!+sb-doc
  "The default for the :PRINT argument to COMPILE-FILE.")
(defvar *compile-progress* nil
  #!+sb-doc
  "When this is true, the compiler prints to *ERROR-OUTPUT* progress
  information about the phases of compilation of each function. (This
  is useful mainly in large block compilations.)")

(defvar sb!xc:*compile-file-pathname* nil
  #!+sb-doc
  "The defaulted pathname of the file currently being compiled, or NIL if not
  compiling.")
(defvar sb!xc:*compile-file-truename* nil
  #!+sb-doc
  "The TRUENAME of the file currently being compiled, or NIL if not
  compiling.")

(declaim (type (or pathname null)
	       sb!xc:*compile-file-pathname*
	       sb!xc:*compile-file-truename*))

;;; the SOURCE-INFO structure for the current compilation. This is
;;; null globally to indicate that we aren't currently in any
;;; identifiable compilation.
(defvar *source-info* nil)

;;; This is true if we are within a WITH-COMPILATION-UNIT form (which
;;; normally causes nested uses to be no-ops).
(defvar *in-compilation-unit* nil)

;;; Count of the number of compilation units dynamically enclosed by
;;; the current active WITH-COMPILATION-UNIT that were unwound out of.
(defvar *aborted-compilation-unit-count*)

;;; Mumble conditional on *COMPILE-PROGRESS*.
(defun maybe-mumble (&rest foo)
  (when *compile-progress*
    (compiler-mumble "~&")
    (pprint-logical-block (*error-output* nil :per-line-prefix "; ")
       (apply #'compiler-mumble foo))))

(deftype object () '(or fasl-output core-object null))

(defvar *compile-object* nil)
(declaim (type object *compile-object*))

;;;; WITH-COMPILATION-UNIT and WITH-COMPILATION-VALUES

(defmacro sb!xc:with-compilation-unit (options &body body)
  #!+sb-doc
  "WITH-COMPILATION-UNIT ({Key Value}*) Form*
  This form affects compilations that take place within its dynamic extent. It
  is intended to be wrapped around the compilation of all files in the same
  system. These keywords are defined:
    :OVERRIDE Boolean-Form
        One of the effects of this form is to delay undefined warnings
        until the end of the form, instead of giving them at the end of each
        compilation. If OVERRIDE is NIL (the default), then the outermost
        WITH-COMPILATION-UNIT form grabs the undefined warnings. Specifying
        OVERRIDE true causes that form to grab any enclosed warnings, even if
        it is enclosed by another WITH-COMPILATION-UNIT."
  `(%with-compilation-unit (lambda () ,@body) ,@options))

(defun %with-compilation-unit (fn &key override)
  (declare (type function fn))
  (let ((succeeded-p nil))
    (if (and *in-compilation-unit* (not override))
	;; Inside another WITH-COMPILATION-UNIT, a WITH-COMPILATION-UNIT is
	;; ordinarily (unless OVERRIDE) basically a no-op.
	(unwind-protect
	     (multiple-value-prog1 (funcall fn) (setf succeeded-p t))
	  (unless succeeded-p
	    (incf *aborted-compilation-unit-count*)))
	(let ((*aborted-compilation-unit-count* 0)
	      (*compiler-error-count* 0)
	      (*compiler-warning-count* 0)
	      (*compiler-style-warning-count* 0)
	      (*compiler-note-count* 0)
	      (*undefined-warnings* nil)
	      (*in-compilation-unit* t))
	  (sb!thread:with-recursive-lock (*big-compiler-lock*)
	    (handler-bind ((parse-unknown-type
			    (lambda (c)
			      (note-undefined-reference
			       (parse-unknown-type-specifier c)
			       :type))))
	      (unwind-protect
		   (multiple-value-prog1 (funcall fn) (setf succeeded-p t))
		(unless succeeded-p
		  (incf *aborted-compilation-unit-count*))
		(summarize-compilation-unit (not succeeded-p)))))))))

;;; Is FUN-NAME something that no conforming program can rely on
;;; defining as a function?
(defun fun-name-reserved-by-ansi-p (fun-name)
  (eq (symbol-package (fun-name-block-name fun-name))
      *cl-package*))

;;; This is to be called at the end of a compilation unit. It signals
;;; any residual warnings about unknown stuff, then prints the total
;;; error counts. ABORT-P should be true when the compilation unit was
;;; aborted by throwing out. ABORT-COUNT is the number of dynamically
;;; enclosed nested compilation units that were aborted.
(defun summarize-compilation-unit (abort-p)
  (unless abort-p
    (handler-bind ((style-warning #'compiler-style-warning-handler)
		   (warning #'compiler-warning-handler))

      (let ((undefs (sort *undefined-warnings* #'string<
			  :key (lambda (x)
				 (let ((x (undefined-warning-name x)))
				   (if (symbolp x)
				       (symbol-name x)
				       (prin1-to-string x)))))))
	(dolist (undef undefs)
	  (let ((name (undefined-warning-name undef))
		(kind (undefined-warning-kind undef))
		(warnings (undefined-warning-warnings undef))
		(undefined-warning-count (undefined-warning-count undef)))
	    (dolist (*compiler-error-context* warnings)
              (if #-sb-xc-host (and (eq kind :function)
				    (fun-name-reserved-by-ansi-p name)
                                    *flame-on-necessarily-undefined-function*)
                  #+sb-xc-host nil
		  (case name
		    ((declare)
		     (compiler-warn
		      "~@<There is no function named ~S. References to ~S in ~
                       some contexts (like starts of blocks) have special ~
                       meaning, but here it would have to be a function, ~
                       and that shouldn't be right.~:@>"
		      name name))
		    (t
		     (compiler-warn
		      "~@<The ~(~A~) ~S is undefined, and its name is ~
                       reserved by ANSI CL so that even if it were ~
                       defined later, the code doing so would not be ~
                       portable.~:@>"
		      kind name)))
		  (if (eq kind :variable)
		      (compiler-warn "undefined ~(~A~): ~S" kind name)
		      (compiler-style-warn "undefined ~(~A~): ~S" kind name))))
	    (let ((warn-count (length warnings)))
	      (when (and warnings (> undefined-warning-count warn-count))
		(let ((more (- undefined-warning-count warn-count)))
		  (if (eq kind :variable)
		      (compiler-warn
		       "~W more use~:P of undefined ~(~A~) ~S"
		       more kind name)
		      (compiler-style-warn
		       "~W more use~:P of undefined ~(~A~) ~S"
		       more kind name)))))))

	(dolist (kind '(:variable :function :type))
	  (let ((summary (mapcar #'undefined-warning-name
				 (remove kind undefs :test #'neq
					 :key #'undefined-warning-kind))))
	    (when summary
	      (if (eq kind :variable)
		  (compiler-warn
                   "~:[This ~(~A~) is~;These ~(~A~)s are~] undefined:~
                    ~%  ~{~<~%  ~1:;~S~>~^ ~}"
		   (cdr summary) kind summary)
		  (compiler-style-warn
                   "~:[This ~(~A~) is~;These ~(~A~)s are~] undefined:~
                   ~%  ~{~<~%  ~1:;~S~>~^ ~}"
		   (cdr summary) kind summary))))))))

  (unless (and (not abort-p)
	       (zerop *aborted-compilation-unit-count*)
	       (zerop *compiler-error-count*)
	       (zerop *compiler-warning-count*)
	       (zerop *compiler-style-warning-count*)
	       (zerop *compiler-note-count*))
    (format *error-output* "~&")
    (pprint-logical-block (*error-output* nil :per-line-prefix "; ")
      (compiler-mumble "compilation unit ~:[finished~;aborted~]~
                       ~[~:;~:*~&  caught ~W fatal ERROR condition~:P~]~
                       ~[~:;~:*~&  caught ~W ERROR condition~:P~]~
                       ~[~:;~:*~&  caught ~W WARNING condition~:P~]~
                       ~[~:;~:*~&  caught ~W STYLE-WARNING condition~:P~]~
                       ~[~:;~:*~&  printed ~W note~:P~]"
		       abort-p
		       *aborted-compilation-unit-count*
		       *compiler-error-count*
		       *compiler-warning-count*
		       *compiler-style-warning-count*
		       *compiler-note-count*)))
  (format *error-output* "~&"))

;;; Evaluate BODY, then return (VALUES BODY-VALUE WARNINGS-P
;;; FAILURE-P), where BODY-VALUE is the first value of the body, and
;;; WARNINGS-P and FAILURE-P are as in CL:COMPILE or CL:COMPILE-FILE.
;;; This also wraps up WITH-IR1-NAMESPACE functionality.
(defmacro with-compilation-values (&body body)
  `(with-ir1-namespace
    (let ((*warnings-p* nil)
	  (*failure-p* nil))
      (values (progn ,@body)
	      *warnings-p*
	      *failure-p*))))

;;;; component compilation

(defparameter *max-optimize-iterations* 3 ; ARB
  #!+sb-doc
  "The upper limit on the number of times that we will consecutively do IR1
  optimization that doesn't introduce any new code. A finite limit is
  necessary, since type inference may take arbitrarily long to converge.")

(defevent ir1-optimize-until-done "IR1-OPTIMIZE-UNTIL-DONE called")
(defevent ir1-optimize-maxed-out "hit *MAX-OPTIMIZE-ITERATIONS* limit")

;;; Repeatedly optimize COMPONENT until no further optimizations can
;;; be found or we hit our iteration limit. When we hit the limit, we
;;; clear the component and block REOPTIMIZE flags to discourage the
;;; next optimization attempt from pounding on the same code.
(defun ir1-optimize-until-done (component)
  (declare (type component component))
  (maybe-mumble "opt")
  (event ir1-optimize-until-done)
  (let ((count 0)
	(cleared-reanalyze nil)
        (fastp nil))
    (loop
      (when (component-reanalyze component)
	(setq count 0)
	(setq cleared-reanalyze t)
	(setf (component-reanalyze component) nil))
      (setf (component-reoptimize component) nil)
      (ir1-optimize component fastp)
      (cond ((component-reoptimize component)
             (incf count)
             (when (and (>= count *max-optimize-iterations*)
                        (not (component-reanalyze component))
                        (eq (component-reoptimize component) :maybe))
               (maybe-mumble "*")
               (cond ((retry-delayed-ir1-transforms :optimize)
		      (maybe-mumble "+")
		      (setq count 0))
                     (t
		      (event ir1-optimize-maxed-out)
		      (setf (component-reoptimize component) nil)
		      (do-blocks (block component)
			(setf (block-reoptimize block) nil))
		      (return)))))
            ((retry-delayed-ir1-transforms :optimize)
	     (setf count 0)
	     (maybe-mumble "+"))
	    (t
             (maybe-mumble " ")
	     (return)))
      (setq fastp (>= count *max-optimize-iterations*))
      (maybe-mumble (if fastp "-" ".")))
    (when cleared-reanalyze
      (setf (component-reanalyze component) t)))
  (values))

(defparameter *constraint-propagate* t)

;;; KLUDGE: This was bumped from 5 to 10 in a DTC patch ported by MNA
;;; from CMU CL into sbcl-0.6.11.44, the same one which allowed IR1
;;; transforms to be delayed. Either DTC or MNA or both didn't explain
;;; why, and I don't know what the rationale was. -- WHN 2001-04-28
;;;
;;; FIXME: It would be good to document why it's important to have a
;;; large value here, and what the drawbacks of an excessively large
;;; value are; and it might also be good to make it depend on
;;; optimization policy.
(defparameter *reoptimize-after-type-check-max* 10)

(defevent reoptimize-maxed-out
  "*REOPTIMIZE-AFTER-TYPE-CHECK-MAX* exceeded.")

;;; Iterate doing FIND-DFO until no new dead code is discovered.
(defun dfo-as-needed (component)
  (declare (type component component))
  (when (component-reanalyze component)
    (maybe-mumble "DFO")
    (loop
      (find-dfo component)
      (unless (component-reanalyze component)
	(maybe-mumble " ")
	(return))
      (maybe-mumble ".")))
  (values))

;;; Do all the IR1 phases for a non-top-level component.
(defun ir1-phases (component)
  (declare (type component component))
  (aver-live-component component)
  (let ((*constraint-number* 0)
	(loop-count 1)
        (*delayed-ir1-transforms* nil))
    (declare (special *constraint-number* *delayed-ir1-transforms*))
    (loop
      (ir1-optimize-until-done component)
      (when (or (component-new-functionals component)
		(component-reanalyze-functionals component))
	(maybe-mumble "locall ")
	(locall-analyze-component component))
      (dfo-as-needed component)
      (when *constraint-propagate*
	(maybe-mumble "constraint ")
	(constraint-propagate component))
      (when (retry-delayed-ir1-transforms :constraint)
        (maybe-mumble "Rtran "))
      (flet ((want-reoptimization-p ()
	       (or (component-reoptimize component)
		   (component-reanalyze component)
		   (component-new-functionals component)
		   (component-reanalyze-functionals component))))
	(unless (and (want-reoptimization-p)
		     ;; We delay the generation of type checks until
		     ;; the type constraints have had time to
		     ;; propagate, else the compiler can confuse itself.
		     (< loop-count (- *reoptimize-after-type-check-max* 4)))
	  (maybe-mumble "type ")
	  (generate-type-checks component)
	  (unless (want-reoptimization-p)
	    (return))))
      (when (>= loop-count *reoptimize-after-type-check-max*)
	(maybe-mumble "[reoptimize limit]")
	(event reoptimize-maxed-out)
	(return))
      (incf loop-count)))

  (ir1-finalize component)
  (values))

(defun %compile-component (component)
  (let ((*code-segment* nil)
	(*elsewhere* nil))
    (maybe-mumble "GTN ")
    (gtn-analyze component)
    (maybe-mumble "LTN ")
    (ltn-analyze component)
    (dfo-as-needed component)
    (maybe-mumble "control ")
    (control-analyze component #'make-ir2-block)

    (when (or (ir2-component-values-receivers (component-info component))
              (component-dx-lvars component))
      (maybe-mumble "stack ")
      (stack-analyze component)
      ;; Assign BLOCK-NUMBER for any cleanup blocks introduced by
      ;; stack analysis. There shouldn't be any unreachable code after
      ;; control, so this won't delete anything.
      (dfo-as-needed component))

    (unwind-protect
	(progn
	  (maybe-mumble "IR2tran ")
	  (init-assembler)
	  (entry-analyze component)
	  (ir2-convert component)

	  (when (policy *lexenv* (>= speed compilation-speed))
	    (maybe-mumble "copy ")
	    (copy-propagate component))

	  (select-representations component)

	  (when *check-consistency*
	    (maybe-mumble "check2 ")
	    (check-ir2-consistency component))

	  (delete-unreferenced-tns component)

	  (maybe-mumble "life ")
	  (lifetime-analyze component)

	  (when *compile-progress*
	    (compiler-mumble "") ; Sync before doing more output.
	    (pre-pack-tn-stats component *error-output*))

	  (when *check-consistency*
	    (maybe-mumble "check-life ")
	    (check-life-consistency component))

	  (maybe-mumble "pack ")
	  (pack component)

	  (when *check-consistency*
	    (maybe-mumble "check-pack ")
	    (check-pack-consistency component))

	  (when *compiler-trace-output*
	    (describe-component component *compiler-trace-output*)
	    (describe-ir2-component component *compiler-trace-output*))

	  (maybe-mumble "code ")
	  (multiple-value-bind (code-length trace-table fixup-notes)
	      (generate-code component)

            #-sb-xc-host
	    (when *compiler-trace-output*
	      (format *compiler-trace-output*
		      "~|~%disassembly of code for ~S~2%" component)
	      (sb!disassem:disassemble-assem-segment *code-segment*
						     *compiler-trace-output*))

	    (etypecase *compile-object*
	      (fasl-output
	       (maybe-mumble "fasl")
	       (fasl-dump-component component
				    *code-segment*
				    code-length
				    trace-table
				    fixup-notes
				    *compile-object*))
	      (core-object
	       (maybe-mumble "core")
	       (make-core-component component
				    *code-segment*
				    code-length
				    trace-table
				    fixup-notes
				    *compile-object*))
	      (null))))))

  ;; We're done, so don't bother keeping anything around.
  (setf (component-info component) :dead)

  (values))

;;; Delete components with no external entry points before we try to
;;; generate code. Unreachable closures can cause IR2 conversion to
;;; puke on itself, since it is the reference to the closure which
;;; normally causes the components to be combined.
(defun delete-if-no-entries (component)
  (dolist (fun (component-lambdas component) (delete-component component))
    (when (functional-has-external-references-p fun)
      (return))
    (case (functional-kind fun)
      (:toplevel (return))
      (:external
       (unless (every (lambda (ref)
			(eq (node-component ref) component))
		      (leaf-refs fun))
	 (return))))))

(defun compile-component (component)

  ;; miscellaneous sanity checks
  ;;
  ;; FIXME: These are basically pretty wimpy compared to the checks done
  ;; by the old CHECK-IR1-CONSISTENCY code. It would be really nice to
  ;; make those internal consistency checks work again and use them.
  (aver-live-component component)
  (do-blocks (block component)
    (aver (eql (block-component block) component)))
  (dolist (lambda (component-lambdas component))
    ;; sanity check to prevent weirdness from propagating insidiously as
    ;; far from its root cause as it did in bug 138: Make sure that
    ;; thing-to-COMPONENT links are consistent.
    (aver (eql (lambda-component lambda) component))
    (aver (eql (node-component (lambda-bind lambda)) component)))

  (let* ((*component-being-compiled* component))
    (when sb!xc:*compile-print*
      (compiler-mumble "~&; compiling ~A: " (component-name component)))

    (ir1-phases component)

    (when *loop-analyze*
      (dfo-as-needed component)
      (find-dominators component)
      (loop-analyze component))

    #|
    (when (and *loop-analyze* *compiler-trace-output*)
      (labels ((print-blocks (block)
		 (format *compiler-trace-output* "    ~A~%" block)
		 (when (block-loop-next block)
		   (print-blocks (block-loop-next block))))
	       (print-loop (loop)
		 (format *compiler-trace-output* "loop=~A~%" loop)
		 (print-blocks (loop-blocks loop))
		 (dolist (l (loop-inferiors loop))
		   (print-loop l))))
	(print-loop (component-outer-loop component))))
    |#
    
    ;; FIXME: What is MAYBE-MUMBLE for? Do we need it any more?
    (maybe-mumble "env ")
    (physenv-analyze component)
    (dfo-as-needed component)

    (delete-if-no-entries component)

    (unless (eq (block-next (component-head component))
		(component-tail component))
      (%compile-component component)))

  (clear-constant-info)

  (when sb!xc:*compile-print*
    (compiler-mumble "~&"))

  (values))

;;;; clearing global data structures
;;;;
;;;; FIXME: Is it possible to get rid of this stuff, getting rid of
;;;; global data structures entirely when possible and consing up the
;;;; others from scratch instead of clearing and reusing them?

;;; Clear the INFO in constants in the *FREE-VARS*, etc. In
;;; addition to allowing stuff to be reclaimed, this is required for
;;; correct assignment of constant offsets, since we need to assign a
;;; new offset for each component. We don't clear the FUNCTIONAL-INFO
;;; slots, since they are used to keep track of functions across
;;; component boundaries.
(defun clear-constant-info ()
  (maphash (lambda (k v)
	     (declare (ignore k))
	     (setf (leaf-info v) nil))
	   *constants*)
  (maphash (lambda (k v)
	     (declare (ignore k))
	     (when (constant-p v)
	       (setf (leaf-info v) nil)))
	   *free-vars*)
  (values))

;;; Blow away the REFS for all global variables, and let COMPONENT
;;; be recycled.
(defun clear-ir1-info (component)
  (declare (type component component))
  (labels ((blast (x)
	     (maphash (lambda (k v)
			(declare (ignore k))
			(when (leaf-p v)
			  (setf (leaf-refs v)
				(delete-if #'here-p (leaf-refs v)))
			  (when (basic-var-p v)
			    (setf (basic-var-sets v)
				  (delete-if #'here-p (basic-var-sets v))))))
		      x))
	   (here-p (x)
	     (eq (node-component x) component)))
    (blast *free-vars*)
    (blast *free-funs*)
    (blast *constants*))
  (values))

;;; Clear global variables used by the compiler.
;;;
;;; FIXME: It seems kinda nasty and unmaintainable to have to do this,
;;; and it adds overhead even when people aren't using the compiler.
;;; Perhaps we could make these global vars unbound except when
;;; actually in use, so that this function could go away.
(defun clear-stuff (&optional (debug-too t))

  ;; Clear global tables.
  (when (boundp '*free-funs*)
    (clrhash *free-funs*)
    (clrhash *free-vars*)
    (clrhash *constants*))

  ;; Clear debug counters and tables.
  (clrhash *seen-blocks*)
  (clrhash *seen-funs*)
  (clrhash *list-conflicts-table*)

  (when debug-too
    (clrhash *continuation-numbers*)
    (clrhash *number-continuations*)
    (setq *continuation-number* 0)
    (clrhash *tn-ids*)
    (clrhash *id-tns*)
    (setq *tn-id* 0)
    (clrhash *label-ids*)
    (clrhash *id-labels*)
    (setq *label-id* 0))

  ;; (Note: The CMU CL code used to set CL::*GENSYM-COUNTER* to zero here.
  ;; Superficially, this seemed harmful -- the user could reasonably be
  ;; surprised if *GENSYM-COUNTER* turned back to zero when something was
  ;; compiled. A closer inspection showed that this actually turned out to be
  ;; harmless in practice, because CLEAR-STUFF was only called from within
  ;; forms which bound CL::*GENSYM-COUNTER* to zero. However, this means that
  ;; even though zeroing CL::*GENSYM-COUNTER* here turned out to be harmless in
  ;; practice, it was also useless in practice. So we don't do it any more.)

  (values))

;;;; trace output

;;; Print out some useful info about COMPONENT to STREAM.
(defun describe-component (component *standard-output*)
  (declare (type component component))
  (format t "~|~%;;;; component: ~S~2%" (component-name component))
  (print-all-blocks component)
  (values))

(defun describe-ir2-component (component *standard-output*)
  (format t "~%~|~%;;;; IR2 component: ~S~2%" (component-name component))
  (format t "entries:~%")
  (dolist (entry (ir2-component-entries (component-info component)))
    (format t "~4TL~D: ~S~:[~; [closure]~]~%"
	    (label-id (entry-info-offset entry))
	    (entry-info-name entry)
	    (entry-info-closure-tn entry)))
  (terpri)
  (pre-pack-tn-stats component *standard-output*)
  (terpri)
  (print-ir2-blocks component)
  (terpri)
  (values))

;;;; file reading
;;;;
;;;; When reading from a file, we have to keep track of some source
;;;; information. We also exploit our ability to back up for printing
;;;; the error context and for recovering from errors.
;;;;
;;;; The interface we provide to this stuff is the stream-oid
;;;; SOURCE-INFO structure. The bookkeeping is done as a side effect
;;;; of getting the next source form.

;;; A FILE-INFO structure holds all the source information for a
;;; given file.
(def!struct (file-info (:copier nil))
  ;; If a file, the truename of the corresponding source file. If from
  ;; a Lisp form, :LISP. If from a stream, :STREAM.
  (name (missing-arg) :type (or pathname (member :lisp :stream)))
  ;; the defaulted, but not necessarily absolute file name (i.e. prior
  ;; to TRUENAME call.) Null if not a file. This is used to set
  ;; *COMPILE-FILE-PATHNAME*, and if absolute, is dumped in the
  ;; debug-info.
  (untruename nil :type (or pathname null))
  ;; the file's write date (if relevant)
  (write-date nil :type (or unsigned-byte null))
  ;; the source path root number of the first form in this file (i.e.
  ;; the total number of forms converted previously in this
  ;; compilation)
  (source-root 0 :type unsigned-byte)
  ;; parallel vectors containing the forms read out of the file and
  ;; the file positions that reading of each form started at (i.e. the
  ;; end of the previous form)
  (forms (make-array 10 :fill-pointer 0 :adjustable t) :type (vector t))
  (positions (make-array 10 :fill-pointer 0 :adjustable t) :type (vector t)))

;;; The SOURCE-INFO structure provides a handle on all the source
;;; information for an entire compilation.
(def!struct (source-info
	     #-no-ansi-print-object
	     (:print-object (lambda (s stream)
			      (print-unreadable-object (s stream :type t))))
	     (:copier nil))
  ;; the UT that compilation started at
  (start-time (get-universal-time) :type unsigned-byte)
  ;; the FILE-INFO structure for this compilation
  (file-info nil :type (or file-info null))
  ;; the stream that we are using to read the FILE-INFO, or NIL if
  ;; no stream has been opened yet
  (stream nil :type (or stream null)))

;;; Given a pathname, return a SOURCE-INFO structure.
(defun make-file-source-info (file)
  (let ((file-info (make-file-info :name (truename file)
				   :untruename file
				   :write-date (file-write-date file))))

    (make-source-info :file-info file-info)))

;;; Return a SOURCE-INFO to describe the incremental compilation of FORM. 
(defun make-lisp-source-info (form)
  (make-source-info :start-time (get-universal-time)
		    :file-info (make-file-info :name :lisp
					       :forms (vector form)
					       :positions '#(0))))

;;; Return a SOURCE-INFO which will read from STREAM.
(defun make-stream-source-info (stream)
  (let ((file-info (make-file-info :name :stream)))
    (make-source-info :file-info file-info
		      :stream stream)))

;;; Return a form read from STREAM; or for EOF use the trick,
;;; popularized by Kent Pitman, of returning STREAM itself. If an
;;; error happens, then convert it to standard abort-the-compilation
;;; error condition (possibly recording some extra location
;;; information).
(defun read-for-compile-file (stream position)
  (handler-case (read stream nil stream)
    (reader-error (condition)
     (error 'input-error-in-compile-file
	    :condition condition
	    ;; We don't need to supply :POSITION here because
	    ;; READER-ERRORs already know their position in the file.
	    ))
    ;; ANSI, in its wisdom, says that READ should return END-OF-FILE
    ;; (and that this is not a READER-ERROR) when it encounters end of
    ;; file in the middle of something it's trying to read.
    (end-of-file (condition)
     (error 'input-error-in-compile-file
	    :condition condition
	    ;; We need to supply :POSITION here because the END-OF-FILE
	    ;; condition doesn't carry the position that the user
	    ;; probably cares about, where the failed READ began.
	    :position position))))

;;; If STREAM is present, return it, otherwise open a stream to the
;;; current file. There must be a current file.
;;;
;;; FIXME: This is probably an unnecessarily roundabout way to do
;;; things now that we process a single file in COMPILE-FILE (unlike
;;; the old CMU CL code, which accepted multiple files). Also, the old
;;; comment said
;;;   When we open a new file, we also reset *PACKAGE* and policy.
;;;   This gives the effect of rebinding around each file.
;;; which doesn't seem to be true now. Check to make sure that if
;;; such rebinding is necessary, it's still done somewhere.
(defun get-source-stream (info)
  (declare (type source-info info))
  (or (source-info-stream info)
      (let* ((file-info (source-info-file-info info))
	     (name (file-info-name file-info)))
	(setf sb!xc:*compile-file-truename* name
	      sb!xc:*compile-file-pathname* (file-info-untruename file-info)
	      (source-info-stream info) (open name :direction :input)))))

;;; Close the stream in INFO if it is open.
(defun close-source-info (info)
  (declare (type source-info info))
  (let ((stream (source-info-stream info)))
    (when stream (close stream)))
  (setf (source-info-stream info) nil)
  (values))

;;; Read and compile the source file.
(defun sub-sub-compile-file (info)
  (let* ((file-info (source-info-file-info info))
	 (stream (get-source-stream info)))
    (loop
     (let* ((pos (file-position stream))
	    (form (read-for-compile-file stream pos)))
       (if (eq form stream) ; i.e., if EOF
	   (return)
	   (let* ((forms (file-info-forms file-info))
		  (current-idx (+ (fill-pointer forms)
				  (file-info-source-root file-info))))
	     (vector-push-extend form forms)
	     (vector-push-extend pos (file-info-positions file-info))
	     (find-source-paths form current-idx)
	     (process-toplevel-form form
				    `(original-source-start 0 ,current-idx)
				    nil)))))))

;;; Return the INDEX'th source form read from INFO and the position
;;; where it was read.
(defun find-source-root (index info)
  (declare (type index index) (type source-info info))
  (let ((file-info (source-info-file-info info)))
    (values (aref (file-info-forms file-info) index)
	    (aref (file-info-positions file-info) index))))

;;;; processing of top level forms

;;; This is called by top level form processing when we are ready to
;;; actually compile something. If *BLOCK-COMPILE* is T, then we still
;;; convert the form, but delay compilation, pushing the result on
;;; *TOPLEVEL-LAMBDAS* instead.
(defun convert-and-maybe-compile (form path)
  (declare (list path))
  (let* ((*lexenv* (make-lexenv :policy *policy*
				:handled-conditions *handled-conditions*
				:disabled-package-locks *disabled-package-locks*))
	 (tll (ir1-toplevel form path nil)))
    (cond ((eq *block-compile* t) (push tll *toplevel-lambdas*))
	  (t (compile-toplevel (list tll) nil)))))

;;; Macroexpand FORM in the current environment with an error handler.
;;; We only expand one level, so that we retain all the intervening
;;; forms in the source path.
(defun preprocessor-macroexpand-1 (form)
  (handler-case (sb!xc:macroexpand-1 form *lexenv*)
    (error (condition)
      (compiler-error "(during macroexpansion of ~A)~%~A"
		      (let ((*print-level* 1)
			    (*print-length* 2))
			(format nil "~S" form))
		      condition))))

;;; Process a PROGN-like portion of a top level form. FORMS is a list of
;;; the forms, and PATH is the source path of the FORM they came out of.
;;; COMPILE-TIME-TOO is as in ANSI "3.2.3.1 Processing of Top Level Forms".
(defun process-toplevel-progn (forms path compile-time-too)
  (declare (list forms) (list path))
  (dolist (form forms)
    (process-toplevel-form form path compile-time-too)))

;;; Process a top level use of LOCALLY, or anything else (e.g.
;;; MACROLET) at top level which has declarations and ordinary forms.
;;; We parse declarations and then recursively process the body.
(defun process-toplevel-locally (body path compile-time-too &key vars funs)
  (declare (list path))
  (multiple-value-bind (forms decls)
      (parse-body body :doc-string-allowed nil :toplevel t)
    (let* ((*lexenv* (process-decls decls vars funs))
           ;; FIXME: VALUES declaration
           ;;
	   ;; Binding *POLICY* is pretty much of a hack, since it
	   ;; causes LOCALLY to "capture" enclosed proclamations. It
	   ;; is necessary because CONVERT-AND-MAYBE-COMPILE uses the
	   ;; value of *POLICY* as the policy. The need for this hack
	   ;; is due to the quirk that there is no way to represent in
	   ;; a POLICY that an optimize quality came from the default.
	   ;;
	   ;; FIXME: Ideally, something should be done so that DECLAIM
	   ;; inside LOCALLY works OK. Failing that, at least we could
	   ;; issue a warning instead of silently screwing up.
	   (*policy* (lexenv-policy *lexenv*))
	   ;; This is probably also a hack
	   (*handled-conditions* (lexenv-handled-conditions *lexenv*))
	   ;; ditto
	   (*disabled-package-locks* (lexenv-disabled-package-locks *lexenv*)))
      (process-toplevel-progn forms path compile-time-too))))

;;; Parse an EVAL-WHEN situations list, returning three flags,
;;; (VALUES COMPILE-TOPLEVEL LOAD-TOPLEVEL EXECUTE), indicating
;;; the types of situations present in the list.
(defun parse-eval-when-situations (situations)
  (when (or (not (listp situations))
	    (set-difference situations
			    '(:compile-toplevel
			      compile
			      :load-toplevel
			      load
			      :execute
			      eval)))
    (compiler-error "bad EVAL-WHEN situation list: ~S" situations))
  (let ((deprecated-names (intersection situations '(compile load eval))))
    (when deprecated-names
      (style-warn "using deprecated EVAL-WHEN situation names~{ ~S~}"
 		  deprecated-names)))
  (values (intersection '(:compile-toplevel compile)
			situations)
	  (intersection '(:load-toplevel load) situations)
	  (intersection '(:execute eval) situations)))


;;; utilities for extracting COMPONENTs of FUNCTIONALs
(defun functional-components (f)
  (declare (type functional f))
  (etypecase f
    (clambda (list (lambda-component f)))
    (optional-dispatch (let ((result nil))
			 (flet ((maybe-frob (maybe-clambda)
                                  (when (and maybe-clambda
                                             (promise-ready-p maybe-clambda))
                                    (pushnew (lambda-component
                                              (force maybe-clambda))
					     result))))
			   (map nil #'maybe-frob (optional-dispatch-entry-points f))
			   (maybe-frob (optional-dispatch-more-entry f))
			   (maybe-frob (optional-dispatch-main-entry f)))
                         result))))

(defun make-functional-from-toplevel-lambda (definition
					     &key
					     name
					     (path
					      ;; I'd thought NIL should
					      ;; work, but it doesn't.
					      ;; -- WHN 2001-09-20
					      (missing-arg)))
  (let* ((*current-path* path)
         (component (make-empty-component))
         (*current-component* component))
    (setf (component-name component)
	  (debug-namify "~S initial component" name))
    (setf (component-kind component) :initial)
    (let* ((locall-fun (let ((*allow-instrumenting* t))
                         (ir1-convert-lambdalike
                          definition
                          :debug-name (debug-namify "top level local call "
                                                    name))))
           (fun (ir1-convert-lambda (make-xep-lambda-expression locall-fun)
				    :source-name (or name '.anonymous.)
				    :debug-name (unless name
						  "top level form"))))
      (when name
        (assert-global-function-definition-type name locall-fun))
      (setf (functional-entry-fun fun) locall-fun
            (functional-kind fun) :external
            (functional-has-external-references-p fun) t)
      fun)))

;;; Compile LAMBDA-EXPRESSION into *COMPILE-OBJECT*, returning a
;;; description of the result.
;;;   * If *COMPILE-OBJECT* is a CORE-OBJECT, then write the function
;;;     into core and return the compiled FUNCTION value.
;;;   * If *COMPILE-OBJECT* is a fasl file, then write the function
;;;     into the fasl file and return a dump handle.
;;;
;;; If NAME is provided, then we try to use it as the name of the
;;; function for debugging/diagnostic information.
(defun %compile (lambda-expression
		 *compile-object*
		 &key
		 name
		 (path
		  ;; This magical idiom seems to be the appropriate
		  ;; path for compiling standalone LAMBDAs, judging
		  ;; from the CMU CL code and experiment, so it's a
		  ;; nice default for things where we don't have a
		  ;; real source path (as in e.g. inside CL:COMPILE).
		  '(original-source-start 0 0)))
  (when name
    (legal-fun-name-or-type-error name))
  (let* (
         (*lexenv* (make-lexenv :policy *policy*
				:handled-conditions *handled-conditions*
				:disabled-package-locks *disabled-package-locks*))
         (fun (make-functional-from-toplevel-lambda lambda-expression
						    :name name
						    :path path)))

    ;; FIXME: The compile-it code from here on is sort of a
    ;; twisted version of the code in COMPILE-TOPLEVEL. It'd be
    ;; better to find a way to share the code there; or
    ;; alternatively, to use this code to replace the code there.
    ;; (The second alternative might be pretty easy if we used
    ;; the :LOCALL-ONLY option to IR1-FOR-LAMBDA. Then maybe the
    ;; whole FUNCTIONAL-KIND=:TOPLEVEL case could go away..)

    (locall-analyze-clambdas-until-done (list fun))

    (multiple-value-bind (components-from-dfo top-components hairy-top)
        (find-initial-dfo (list fun))
      (declare (ignore hairy-top))

      (let ((*all-components* (append components-from-dfo top-components)))
        (dolist (component-from-dfo components-from-dfo)
          (compile-component component-from-dfo)
          (replace-toplevel-xeps component-from-dfo)))

      (let ((entry-table (etypecase *compile-object*
			   (fasl-output (fasl-output-entry-table
					 *compile-object*))
			   (core-object (core-object-entry-table
					 *compile-object*)))))
	(multiple-value-bind (result found-p)
	    (gethash (leaf-info fun) entry-table)
	  (aver found-p)
	  (prog1 
              result
	    ;; KLUDGE: This code duplicates some other code in this
	    ;; file. In the great reorganzation, the flow of program
	    ;; logic changed from the original CMUCL model, and that
	    ;; path (as of sbcl-0.7.5 in SUB-COMPILE-FILE) was no
	    ;; longer followed for CORE-OBJECTS, leading to BUG
	    ;; 156. This place is transparently not the right one for
	    ;; this code, but I don't have a clear enough overview of
	    ;; the compiler to know how to rearrange it all so that
	    ;; this operation fits in nicely, and it was blocking
	    ;; reimplementation of (DECLAIM (INLINE FOO)) (MACROLET
	    ;; ((..)) (DEFUN FOO ...))
	    ;;
	    ;; FIXME: This KLUDGE doesn't solve all the problem in an
	    ;; ideal way, as (1) definitions typed in at the REPL
	    ;; without an INLINE declaration will give a NULL
	    ;; FUNCTION-LAMBDA-EXPRESSION (allowable, but not ideal)
	    ;; and (2) INLINE declarations will yield a
	    ;; FUNCTION-LAMBDA-EXPRESSION headed by
	    ;; SB-C:LAMBDA-WITH-LEXENV, even for null LEXENV.  -- CSR,
	    ;; 2002-07-02
	    ;;
	    ;; (2) is probably fairly easy to fix -- it is, after all,
	    ;; a matter of list manipulation (or possibly of teaching
	    ;; CL:FUNCTION about SB-C:LAMBDA-WITH-LEXENV).  (1) is
	    ;; significantly harder, as the association between
	    ;; function object and source is a tricky one.
	    ;;
	    ;; FUNCTION-LAMBDA-EXPRESSION "works" (i.e. returns a
	    ;; non-NULL list) when the function in question has been
	    ;; compiled by (COMPILE <x> '(LAMBDA ...)); it does not
	    ;; work when it has been compiled as part of the top-level
	    ;; EVAL strategy of compiling everything inside (LAMBDA ()
	    ;; ...).  -- CSR, 2002-11-02
	    (when (core-object-p *compile-object*)
	      (fix-core-source-info *source-info* *compile-object* result))

	    (mapc #'clear-ir1-info components-from-dfo)
	    (clear-stuff)))))))

(defun process-toplevel-cold-fset (name lambda-expression path)
  (unless (producing-fasl-file)
    (error "can't COLD-FSET except in a fasl file"))
  (legal-fun-name-or-type-error name)
  (fasl-dump-cold-fset name
                       (%compile lambda-expression
                                 *compile-object*
                                 :name name
				 :path path)
                       *compile-object*)
  (values))

;;; Process a top level FORM with the specified source PATH.
;;;  * If this is a magic top level form, then do stuff.
;;;  * If this is a macro, then expand it.
;;;  * Otherwise, just compile it.
;;;
;;; COMPILE-TIME-TOO is as defined in ANSI
;;; "3.2.3.1 Processing of Top Level Forms".
(defun process-toplevel-form (form path compile-time-too)

  (declare (list path))

  (catch 'process-toplevel-form-error-abort
    (let* ((path (or (gethash form *source-paths*) (cons form path)))
	   (*compiler-error-bailout*
	    (lambda (&optional condition)
	      (convert-and-maybe-compile
	       (make-compiler-error-form condition form)
	       path)
	      (throw 'process-toplevel-form-error-abort nil))))

      (flet ((default-processor (form)
               ;; When we're cross-compiling, consider: what should we
               ;; do when we hit e.g.
               ;;   (EVAL-WHEN (:COMPILE-TOPLEVEL)
               ;;     (DEFUN FOO (X) (+ 7 X)))?
               ;; DEFUN has a macro definition in the cross-compiler,
               ;; and a different macro definition in the target
               ;; compiler. The only sensible thing is to use the
               ;; target compiler's macro definition, since the
               ;; cross-compiler's macro is in general into target
               ;; functions which can't meaningfully be executed at
               ;; cross-compilation time. So make sure we do the EVAL
               ;; here, before we macroexpand.
               ;;
               ;; Then things get even dicier with something like
               ;;   (DEFCONSTANT-EQX SB!XC:LAMBDA-LIST-KEYWORDS ..)
               ;; where we have to make sure that we don't uncross
               ;; the SB!XC: prefix before we do EVAL, because otherwise
               ;; we'd be trying to redefine the cross-compilation host's
               ;; constants.
               ;;
               ;; (Isn't it fun to cross-compile Common Lisp?:-)
               #+sb-xc-host
               (progn
                 (when compile-time-too
                   (eval form)) ; letting xc host EVAL do its own macroexpansion
                 (let* (;; (We uncross the operator name because things
                        ;; like SB!XC:DEFCONSTANT and SB!XC:DEFTYPE
                        ;; should be equivalent to their CL: counterparts
                        ;; when being compiled as target code. We leave
                        ;; the rest of the form uncrossed because macros
                        ;; might yet expand into EVAL-WHEN stuff, and
                        ;; things inside EVAL-WHEN can't be uncrossed
                        ;; until after we've EVALed them in the
                        ;; cross-compilation host.)
                        (slightly-uncrossed (cons (uncross (first form))
                                                  (rest form)))
                        (expanded (preprocessor-macroexpand-1
                                   slightly-uncrossed)))
                   (if (eq expanded slightly-uncrossed)
                       ;; (Now that we're no longer processing toplevel
                       ;; forms, and hence no longer need to worry about
                       ;; EVAL-WHEN, we can uncross everything.)
                       (convert-and-maybe-compile expanded path)
                       ;; (We have to demote COMPILE-TIME-TOO to NIL
                       ;; here, no matter what it was before, since
                       ;; otherwise we'd tend to EVAL subforms more than
                       ;; once, because of WHEN COMPILE-TIME-TOO form
                       ;; above.)
                       (process-toplevel-form expanded path nil))))
               ;; When we're not cross-compiling, we only need to
               ;; macroexpand once, so we can follow the 1-thru-6
               ;; sequence of steps in ANSI's "3.2.3.1 Processing of
               ;; Top Level Forms".
               #-sb-xc-host
               (let ((expanded (preprocessor-macroexpand-1 form)))
		 (cond ((eq expanded form)
			(when compile-time-too
			  (eval-in-lexenv form *lexenv*))
			(convert-and-maybe-compile form path))
		       (t
			(process-toplevel-form expanded
					       path
					       compile-time-too))))))
        (if (atom form)
            #+sb-xc-host
            ;; (There are no xc EVAL-WHEN issues in the ATOM case until
            ;; (1) SBCL gets smart enough to handle global
            ;; DEFINE-SYMBOL-MACRO or SYMBOL-MACROLET and (2) SBCL
	    ;; implementors start using symbol macros in a way which
	    ;; interacts with SB-XC/CL distinction.)
            (convert-and-maybe-compile form path)
            #-sb-xc-host
            (default-processor form)
            (flet ((need-at-least-one-arg (form)
                     (unless (cdr form)
                       (compiler-error "~S form is too short: ~S"
                                       (car form)
                                       form))))
              (case (car form)
                ;; In the cross-compiler, top level COLD-FSET arranges
                ;; for static linking at cold init time.
                #+sb-xc-host
                ((cold-fset)
                 (aver (not compile-time-too))
                 (destructuring-bind (cold-fset fun-name lambda-expression) form
                   (declare (ignore cold-fset))
                   (process-toplevel-cold-fset fun-name
                                               lambda-expression
                                               path)))
                ((eval-when macrolet symbol-macrolet);things w/ 1 arg before body
                 (need-at-least-one-arg form)
                 (destructuring-bind (special-operator magic &rest body) form
                   (ecase special-operator
                     ((eval-when)
                      ;; CT, LT, and E here are as in Figure 3-7 of ANSI
                      ;; "3.2.3.1 Processing of Top Level Forms".
                      (multiple-value-bind (ct lt e)
                          (parse-eval-when-situations magic)
                        (let ((new-compile-time-too (or ct
                                                        (and compile-time-too
                                                             e))))
                          (cond (lt (process-toplevel-progn
                                     body path new-compile-time-too))
                                (new-compile-time-too (eval-in-lexenv
                                                       `(progn ,@body)
                                                       *lexenv*))))))
                     ((macrolet)
                      (funcall-in-macrolet-lexenv
                       magic
                       (lambda (&key funs prepend)
                         (declare (ignore funs))
			 (aver (null prepend))
                         (process-toplevel-locally body
                                                   path
                                                   compile-time-too))
                       :compile))
                     ((symbol-macrolet)
                      (funcall-in-symbol-macrolet-lexenv
                       magic
                       (lambda (&key vars prepend)
			 (aver (null prepend))
                         (process-toplevel-locally body
                                                   path
                                                   compile-time-too
                                                   :vars vars))
                       :compile)))))
                ((locally)
                 (process-toplevel-locally (rest form) path compile-time-too))
                ((progn)
                 (process-toplevel-progn (rest form) path compile-time-too))
                (t (default-processor form))))))))

  (values))

;;;; load time value support
;;;;
;;;; (See EMIT-MAKE-LOAD-FORM.)

;;; Return T if we are currently producing a fasl file and hence
;;; constants need to be dumped carefully.
(defun producing-fasl-file ()
  (fasl-output-p *compile-object*))

;;; Compile FORM and arrange for it to be called at load-time. Return
;;; the dumper handle and our best guess at the type of the object.
(defun compile-load-time-value (form)
  (let ((lambda (compile-load-time-stuff form t)))
    (values
     (fasl-dump-load-time-value-lambda lambda *compile-object*)
     (let ((type (leaf-type lambda)))
       (if (fun-type-p type)
	   (single-value-type (fun-type-returns type))
	   *wild-type*)))))

;;; Compile the FORMS and arrange for them to be called (for effect,
;;; not value) at load time.
(defun compile-make-load-form-init-forms (forms)
  (let ((lambda (compile-load-time-stuff `(progn ,@forms) nil)))
    (fasl-dump-toplevel-lambda-call lambda *compile-object*)))

;;; Do the actual work of COMPILE-LOAD-TIME-VALUE or
;;; COMPILE-MAKE-LOAD-FORM-INIT-FORMS.
(defun compile-load-time-stuff (form for-value)
  (with-ir1-namespace
   (let* ((*lexenv* (make-null-lexenv))
	  (lambda (ir1-toplevel form *current-path* for-value)))
     (compile-toplevel (list lambda) t)
     lambda)))

;;; This is called by COMPILE-TOPLEVEL when it was passed T for
;;; LOAD-TIME-VALUE-P (which happens in COMPILE-LOAD-TIME-STUFF). We
;;; don't try to combine this component with anything else and frob
;;; the name. If not in a :TOPLEVEL component, then don't bother
;;; compiling, because it was merged with a run-time component.
(defun compile-load-time-value-lambda (lambdas)
  (aver (null (cdr lambdas)))
  (let* ((lambda (car lambdas))
	 (component (lambda-component lambda)))
    (when (eql (component-kind component) :toplevel)
      (setf (component-name component) (leaf-debug-name lambda))
      (compile-component component)
      (clear-ir1-info component))))

;;;; COMPILE-FILE

(defun object-call-toplevel-lambda (tll)
  (declare (type functional tll))
  (let ((object *compile-object*))
    (etypecase object
      (fasl-output (fasl-dump-toplevel-lambda-call tll object))
      (core-object (core-call-toplevel-lambda      tll object))
      (null))))

;;; Smash LAMBDAS into a single component, compile it, and arrange for
;;; the resulting function to be called.
(defun sub-compile-toplevel-lambdas (lambdas)
  (declare (list lambdas))
  (when lambdas
    (multiple-value-bind (component tll) (merge-toplevel-lambdas lambdas)
      (compile-component component)
      (clear-ir1-info component)
      (object-call-toplevel-lambda tll)))
  (values))

;;; Compile top level code and call the top level lambdas. We pick off
;;; top level lambdas in non-top-level components here, calling
;;; SUB-c-t-l-l on each subsequence of normal top level lambdas.
(defun compile-toplevel-lambdas (lambdas)
  (declare (list lambdas))
  (let ((len (length lambdas)))
    (flet ((loser (start)
	     (or (position-if (lambda (x)
				(not (eq (component-kind
					  (node-component (lambda-bind x)))
					 :toplevel)))
			      lambdas
			      ;; this used to read ":start start", but
			      ;; start can be greater than len, which
			      ;; is an error according to ANSI - CSR,
			      ;; 2002-04-25
			      :start (min start len))
		 len)))
      (do* ((start 0 (1+ loser))
	    (loser (loser start) (loser start)))
	   ((>= start len))
	(sub-compile-toplevel-lambdas (subseq lambdas start loser))
	(unless (= loser len)
	  (object-call-toplevel-lambda (elt lambdas loser))))))
  (values))

;;; Compile LAMBDAS (a list of CLAMBDAs for top level forms) into the
;;; object file. 
;;;
;;; LOAD-TIME-VALUE-P seems to control whether it's MAKE-LOAD-FORM and
;;; COMPILE-LOAD-TIME-VALUE stuff. -- WHN 20000201
(defun compile-toplevel (lambdas load-time-value-p)
  (declare (list lambdas))

  (maybe-mumble "locall ")
  (locall-analyze-clambdas-until-done lambdas)

  (maybe-mumble "IDFO ")
  (multiple-value-bind (components top-components hairy-top)
      (find-initial-dfo lambdas)
    (let ((*all-components* (append components top-components)))
      (when *check-consistency*
	(maybe-mumble "[check]~%")
	(check-ir1-consistency *all-components*))

      (dolist (component (append hairy-top top-components))
	(pre-physenv-analyze-toplevel component))

      (dolist (component components)
	(compile-component component)
	(replace-toplevel-xeps component))
	
      (when *check-consistency*
	(maybe-mumble "[check]~%")
	(check-ir1-consistency *all-components*))
	
      (if load-time-value-p
	  (compile-load-time-value-lambda lambdas)
	  (compile-toplevel-lambdas lambdas))

      (mapc #'clear-ir1-info components)
      (clear-stuff)))
  (values))

;;; Actually compile any stuff that has been queued up for block
;;; compilation.
(defun finish-block-compilation ()
  (when *block-compile*
    (when *toplevel-lambdas*
      (compile-toplevel (nreverse *toplevel-lambdas*) nil)
      (setq *toplevel-lambdas* ()))
    (setq *block-compile* nil)
    (setq *entry-points* nil)))

(defun handle-condition-p (condition)
  (let ((lexenv
	 (etypecase *compiler-error-context*
	   (node
	    (node-lexenv *compiler-error-context*))
	   (compiler-error-context
	    (let ((lexenv (compiler-error-context-lexenv
			   *compiler-error-context*)))
	      (aver lexenv)
	      lexenv))
	   (null *lexenv*))))
    (let ((muffles (lexenv-handled-conditions lexenv)))
      (if (null muffles) ; common case
	  nil
	  (dolist (muffle muffles nil)
	    (destructuring-bind (typespec . restart-name) muffle
	      (when (and (typep condition typespec)
			 (find-restart restart-name condition))
		(return t))))))))

(defun handle-condition-handler (condition)
  (let ((lexenv
	 (etypecase *compiler-error-context*
	   (node
	    (node-lexenv *compiler-error-context*))
	   (compiler-error-context
	    (let ((lexenv (compiler-error-context-lexenv
			   *compiler-error-context*)))
	      (aver lexenv)
	      lexenv))
	   (null *lexenv*))))
    (let ((muffles (lexenv-handled-conditions lexenv)))
      (aver muffles)
      (dolist (muffle muffles (bug "fell through"))
	(destructuring-bind (typespec . restart-name) muffle
	  (when (typep condition typespec)
	    (awhen (find-restart restart-name condition)
	      (invoke-restart it))))))))

;;; Read all forms from INFO and compile them, with output to OBJECT.
;;; Return (VALUES NIL WARNINGS-P FAILURE-P).
(defun sub-compile-file (info)
  (declare (type source-info info))
  (let ((*package* (sane-package))
        (*readtable* *readtable*)
        (sb!xc:*compile-file-pathname* nil) ; really bound in
        (sb!xc:*compile-file-truename* nil) ; SUB-SUB-COMPILE-FILE

        (*policy* *policy*)
	(*handled-conditions* *handled-conditions*)
	(*disabled-package-locks* *disabled-package-locks*)
        (*lexenv* (make-null-lexenv))
        (*block-compile* *block-compile-arg*)
        (*source-info* info)
        (*toplevel-lambdas* ())
        (*fun-names-in-this-file* ())
        (*allow-instrumenting* nil)
        (*compiler-error-bailout*
         (lambda ()
           (compiler-mumble "~2&; fatal error, aborting compilation~%")
           (return-from sub-compile-file (values nil t t))))
        (*current-path* nil)
        (*last-source-context* nil)
        (*last-original-source* nil)
        (*last-source-form* nil)
        (*last-format-string* nil)
        (*last-format-args* nil)
        (*last-message-count* 0)
        ;; FIXME: Do we need this rebinding here? It's a literal
        ;; translation of the old CMU CL rebinding to
        ;; (OR *BACKEND-INFO-ENVIRONMENT* *INFO-ENVIRONMENT*),
        ;; and it's not obvious whether the rebinding to itself is
        ;; needed that SBCL doesn't need *BACKEND-INFO-ENVIRONMENT*.
        (*info-environment* *info-environment*)
        (*gensym-counter* 0))
    (handler-case
	(handler-bind (((satisfies handle-condition-p) #'handle-condition-handler))
	  (with-compilation-values
	      (sb!xc:with-compilation-unit ()
		(clear-stuff)
		
		(sub-sub-compile-file info)
		
		(finish-block-compilation)
		(let ((object *compile-object*))
		  (etypecase object
		    (fasl-output (fasl-dump-source-info info object))
		    (core-object (fix-core-source-info info object))
		    (null)))
		nil)))
      ;; Some errors are sufficiently bewildering that we just fail
      ;; immediately, without trying to recover and compile more of
      ;; the input file.
      (fatal-compiler-error (condition)
       (signal condition)
       (format *error-output*
	       "~@<compilation aborted because of fatal error: ~2I~_~A~:>"
	       condition)
       (values nil t t)))))

;;; Return a pathname for the named file. The file must exist.
(defun verify-source-file (pathname-designator)
  (let* ((pathname (pathname pathname-designator))
	 (default-host (make-pathname :host (pathname-host pathname))))
    (flet ((try-with-type (path type error-p)
	     (let ((new (merge-pathnames
			 path (make-pathname :type type
					     :defaults default-host))))
	       (if (probe-file new)
		   new
		   (and error-p (truename new))))))
      (cond ((typep pathname 'logical-pathname)
	     (try-with-type pathname "LISP" t))
	    ((probe-file pathname) pathname)
	    ((try-with-type pathname "lisp"  nil))
	    ((try-with-type pathname "lisp"  t))))))

(defun elapsed-time-to-string (tsec)
  (multiple-value-bind (tmin sec) (truncate tsec 60)
    (multiple-value-bind (thr min) (truncate tmin 60)
      (format nil "~D:~2,'0D:~2,'0D" thr min sec))))

;;; Print some junk at the beginning and end of compilation.
(defun start-error-output (source-info)
  (declare (type source-info source-info))
  (let ((file-info (source-info-file-info source-info)))
    (compiler-mumble "~&; compiling file ~S (written ~A):~%"
		     (namestring (file-info-name file-info))
		     (sb!int:format-universal-time nil
						   (file-info-write-date
						    file-info)
						   :style :government
						   :print-weekday nil
						   :print-timezone nil)))
  (values))
(defun finish-error-output (source-info won)
  (declare (type source-info source-info))
  (compiler-mumble "~&; compilation ~:[aborted after~;finished in~] ~A~&"
		   won
		   (elapsed-time-to-string
		    (- (get-universal-time)
		       (source-info-start-time source-info))))
  (values))

;;; Open some files and call SUB-COMPILE-FILE. If something unwinds
;;; out of the compile, then abort the writing of the output file, so
;;; that we don't overwrite it with known garbage.
(defun sb!xc:compile-file
    (input-file
     &key

     ;; ANSI options
     (output-file (cfp-output-file-default input-file))
     ;; FIXME: ANSI doesn't seem to say anything about
     ;; *COMPILE-VERBOSE* and *COMPILE-PRINT* being rebound by this
     ;; function..
     ((:verbose sb!xc:*compile-verbose*) sb!xc:*compile-verbose*)
     ((:print sb!xc:*compile-print*) sb!xc:*compile-print*)
     (external-format :default)

     ;; extensions
     (trace-file nil) 
     ((:block-compile *block-compile-arg*) nil))

  #!+sb-doc
  "Compile INPUT-FILE, producing a corresponding fasl file and returning
   its filename. Besides the ANSI &KEY arguments :OUTPUT-FILE, :VERBOSE,
   :PRINT, and :EXTERNAL-FORMAT,the following extensions are supported:
     :TRACE-FILE
        If given, internal data structures are dumped to the specified
        file, or if a value of T is given, to a file of *.trace type
        derived from the input file name.
   Also, as a workaround for vaguely-non-ANSI behavior, the :BLOCK-COMPILE
   argument is quasi-supported, to determine whether multiple
   functions are compiled together as a unit, resolving function
   references at compile time. NIL means that global function names
   are never resolved at compilation time. Currently NIL is the
   default behavior, because although section 3.2.2.3, \"Semantic
   Constraints\", of the ANSI spec allows this behavior under all
   circumstances, the compiler's runtime scales badly when it
   tries to do this for large files. If/when this performance
   problem is fixed, the block compilation default behavior will
   probably be made dependent on the SPEED and COMPILATION-SPEED
   optimization values, and the :BLOCK-COMPILE argument will probably
   become deprecated."

  (unless (eq external-format :default)
    (error "Non-:DEFAULT EXTERNAL-FORMAT values are not supported."))
  (let* ((fasl-output nil)
	 (output-file-name nil)
	 (compile-won nil)
	 (warnings-p nil)
	 (failure-p t) ; T in case error keeps this from being set later
	 (input-pathname (verify-source-file input-file))
	 (source-info (make-file-source-info input-pathname))
	 (*compiler-trace-output* nil)) ; might be modified below

    (unwind-protect
	(progn
	  (when output-file
	    (setq output-file-name
		  (sb!xc:compile-file-pathname input-file
					       :output-file output-file))
	    (setq fasl-output
		  (open-fasl-output output-file-name
				    (namestring input-pathname))))
	  (when trace-file
	    (let* ((default-trace-file-pathname
		     (make-pathname :type "trace" :defaults input-pathname))
		   (trace-file-pathname
		    (if (eql trace-file t)
			default-trace-file-pathname
			(merge-pathnames trace-file
					 default-trace-file-pathname))))
	      (setf *compiler-trace-output*
		    (open trace-file-pathname
			  :if-exists :supersede
			  :direction :output))))

	  (when sb!xc:*compile-verbose*
	    (start-error-output source-info))
	  (let ((*compile-object* fasl-output)
		dummy)
	    (multiple-value-setq (dummy warnings-p failure-p)
	      (sub-compile-file source-info)))
	  (setq compile-won t))

      (close-source-info source-info)

      (when fasl-output
	(close-fasl-output fasl-output (not compile-won))
	(setq output-file-name
	      (pathname (fasl-output-stream fasl-output)))
	(when (and compile-won sb!xc:*compile-verbose*)
	  (compiler-mumble "~2&; ~A written~%" (namestring output-file-name))))

      (when sb!xc:*compile-verbose*
	(finish-error-output source-info compile-won))

      (when *compiler-trace-output*
	(close *compiler-trace-output*)))

    (values (if output-file
		;; Hack around filesystem race condition...
		(or (probe-file output-file-name) output-file-name)
		nil)
	    warnings-p
	    failure-p)))

;;; a helper function for COMPILE-FILE-PATHNAME: the default for
;;; the OUTPUT-FILE argument
;;;
;;; ANSI: The defaults for the OUTPUT-FILE are taken from the pathname
;;; that results from merging the INPUT-FILE with the value of
;;; *DEFAULT-PATHNAME-DEFAULTS*, except that the type component should
;;; default to the appropriate implementation-defined default type for
;;; compiled files.
(defun cfp-output-file-default (input-file)
  (let* ((defaults (merge-pathnames input-file *default-pathname-defaults*))
	 (retyped (make-pathname :type *fasl-file-type* :defaults defaults)))
    retyped))
	
;;; KLUDGE: Part of the ANSI spec for this seems contradictory:
;;;   If INPUT-FILE is a logical pathname and OUTPUT-FILE is unsupplied,
;;;   the result is a logical pathname. If INPUT-FILE is a logical
;;;   pathname, it is translated into a physical pathname as if by
;;;   calling TRANSLATE-LOGICAL-PATHNAME.
;;; So I haven't really tried to make this precisely ANSI-compatible
;;; at the level of e.g. whether it returns logical pathname or a
;;; physical pathname. Patches to make it more correct are welcome.
;;; -- WHN 2000-12-09
(defun sb!xc:compile-file-pathname (input-file
				    &key
				    (output-file (cfp-output-file-default
						  input-file))
				    &allow-other-keys)
  #!+sb-doc
  "Return a pathname describing what file COMPILE-FILE would write to given
   these arguments."
  (merge-pathnames output-file (merge-pathnames input-file)))

;;;; MAKE-LOAD-FORM stuff

;;; The entry point for MAKE-LOAD-FORM support. When IR1 conversion
;;; finds a constant structure, it invokes this to arrange for proper
;;; dumping. If it turns out that the constant has already been
;;; dumped, then we don't need to do anything.
;;;
;;; If the constant hasn't been dumped, then we check to see whether
;;; we are in the process of creating it. We detect this by
;;; maintaining the special *CONSTANTS-BEING-CREATED* as a list of all
;;; the constants we are in the process of creating. Actually, each
;;; entry is a list of the constant and any init forms that need to be
;;; processed on behalf of that constant.
;;;
;;; It's not necessarily an error for this to happen. If we are
;;; processing the init form for some object that showed up *after*
;;; the original reference to this constant, then we just need to
;;; defer the processing of that init form. To detect this, we
;;; maintain *CONSTANTS-CREATED-SINCE-LAST-INIT* as a list of the
;;; constants created since the last time we started processing an
;;; init form. If the constant passed to emit-make-load-form shows up
;;; in this list, then there is a circular chain through creation
;;; forms, which is an error.
;;;
;;; If there is some intervening init form, then we blow out of
;;; processing it by throwing to the tag PENDING-INIT. The value we
;;; throw is the entry from *CONSTANTS-BEING-CREATED*. This is so the
;;; offending init form can be tacked onto the init forms for the
;;; circular object.
;;;
;;; If the constant doesn't show up in *CONSTANTS-BEING-CREATED*, then
;;; we have to create it. We call MAKE-LOAD-FORM and check to see
;;; whether the creation form is the magic value
;;; :SB-JUST-DUMP-IT-NORMALLY. If it is, then we don't do anything. The
;;; dumper will eventually get its hands on the object and use the
;;; normal structure dumping noise on it.
;;;
;;; Otherwise, we bind *CONSTANTS-BEING-CREATED* and
;;; *CONSTANTS-CREATED-SINCE- LAST-INIT* and compile the creation form
;;; much the way LOAD-TIME-VALUE does. When this finishes, we tell the
;;; dumper to use that result instead whenever it sees this constant.
;;;
;;; Now we try to compile the init form. We bind
;;; *CONSTANTS-CREATED-SINCE-LAST-INIT* to NIL and compile the init
;;; form (and any init forms that were added because of circularity
;;; detection). If this works, great. If not, we add the init forms to
;;; the init forms for the object that caused the problems and let it
;;; deal with it.
(defvar *constants-being-created* nil)
(defvar *constants-created-since-last-init* nil)
;;; FIXME: Shouldn't these^ variables be unbound outside LET forms?
(defun emit-make-load-form (constant)
  (aver (fasl-output-p *compile-object*))
  (unless (or (fasl-constant-already-dumped-p constant *compile-object*)
	      ;; KLUDGE: This special hack is because I was too lazy
	      ;; to rework DEF!STRUCT so that the MAKE-LOAD-FORM
	      ;; function of LAYOUT returns nontrivial forms when
	      ;; building the cross-compiler but :IGNORE-IT when
	      ;; cross-compiling or running under the target Lisp. --
	      ;; WHN 19990914
	      #+sb-xc-host (typep constant 'layout))
    (let ((circular-ref (assoc constant *constants-being-created* :test #'eq)))
      (when circular-ref
	(when (find constant *constants-created-since-last-init* :test #'eq)
	  (throw constant t))
	(throw 'pending-init circular-ref)))
    (multiple-value-bind (creation-form init-form)
	(handler-case
            (sb!xc:make-load-form constant (make-null-lexenv))
	  (error (condition)
	    (compiler-error condition)))
      (case creation-form
	(:sb-just-dump-it-normally
	 (fasl-validate-structure constant *compile-object*)
	 t)
	(:ignore-it
	 nil)
	(t
	 (when (fasl-constant-already-dumped-p constant *compile-object*)
	   (return-from emit-make-load-form nil))
	 (let* ((name (let ((*print-level* 1) (*print-length* 2))
			(with-output-to-string (stream)
			  (write constant :stream stream))))
		(info (if init-form
			  (list constant name init-form)
			  (list constant))))
	   (let ((*constants-being-created*
		  (cons info *constants-being-created*))
		 (*constants-created-since-last-init*
		  (cons constant *constants-created-since-last-init*)))
	     (when
		 (catch constant
		   (fasl-note-handle-for-constant
		    constant
		    (compile-load-time-value
		     creation-form)
		    *compile-object*)
		   nil)
	       (compiler-error "circular references in creation form for ~S"
			       constant)))
	   (when (cdr info)
	     (let* ((*constants-created-since-last-init* nil)
		    (circular-ref
		     (catch 'pending-init
		       (loop for (name form) on (cdr info) by #'cddr
			 collect name into names
			 collect form into forms
			 finally (compile-make-load-form-init-forms forms))
		       nil)))
	       (when circular-ref
		 (setf (cdr circular-ref)
		       (append (cdr circular-ref) (cdr info))))))))))))


;;;; Host compile time definitions
#+sb-xc-host
(defun compile-in-lexenv (name lambda lexenv)
  (declare (ignore lexenv))
  (compile name lambda))

#+sb-xc-host
(defun eval-in-lexenv (form lexenv)
  (declare (ignore lexenv))
  (eval form))
