;;;; the debugger

;;;; This software is part of the SBCL system. See the README file for
;;;; more information.
;;;;
;;;; This software is derived from the CMU CL system, which was
;;;; written at Carnegie Mellon University and released into the
;;;; public domain. The software is in the public domain and is
;;;; provided with absolutely no warranty. See the COPYING and CREDITS
;;;; files for more information.

(in-package "SB!DEBUG")

;;;; variables and constants

;;; things to consider when tweaking these values:
;;;   * We're afraid to just default them to NIL and NIL, in case the
;;;     user inadvertently causes a hairy data structure to be printed
;;;     when he inadvertently enters the debugger.
;;;   * We don't want to truncate output too much. These days anyone
;;;     can easily run their Lisp in a windowing system or under Emacs,
;;;     so it's not the end of the world even if the worst case is a
;;;     few thousand lines of output.
;;;   * As condition :REPORT methods are converted to use the pretty
;;;     printer, they acquire *PRINT-LEVEL* constraints, so e.g. under
;;;     sbcl-0.7.1.28's old value of *DEBUG-PRINT-LEVEL*=3, an
;;;     ARG-COUNT-ERROR printed as 
;;;       error while parsing arguments to DESTRUCTURING-BIND:
;;;         invalid number of elements in
;;;           #
;;;         to satisfy lambda list
;;;           #:
;;;         exactly 2 expected, but 5 found
(defvar *debug-print-variable-alist* nil
  #!+sb-doc
  "an association list describing new bindings for special variables
to be used within the debugger. Eg.

 ((*PRINT-LENGTH* . 10) (*PRINT-LEVEL* . 6) (*PRINT-PRETTY* . NIL))

The variables in the CAR positions are bound to the values in the CDR
during the execution of some debug commands. When evaluating arbitrary
expressions in the debugger, the normal values of the printer control
variables are in effect.

Initially empty, *DEBUG-PRINT-VARIABLE-ALIST* is typically used to
provide bindings for printer control variables.")

(defvar *debug-readtable*
  ;; KLUDGE: This can't be initialized in a cold toplevel form,
  ;; because the *STANDARD-READTABLE* isn't initialized until after
  ;; cold toplevel forms have run. So instead we initialize it
  ;; immediately after *STANDARD-READTABLE*. -- WHN 20000205
  nil
  #!+sb-doc
  "*READTABLE* for the debugger")

(defvar *in-the-debugger* nil
  #!+sb-doc
  "This is T while in the debugger.")

;;; nestedness inside debugger command loops
(defvar *debug-command-level* 0)

;;; If this is bound before the debugger is invoked, it is used as the
;;; stack top by the debugger.
(defvar *stack-top-hint* nil)

(defvar *stack-top* nil)
(defvar *real-stack-top* nil)

(defvar *current-frame* nil)

;;; Beginner-oriented help messages are important because you end up
;;; in the debugger whenever something bad happens, or if you try to
;;; get out of the system with Ctrl-C or (EXIT) or EXIT or whatever.
;;; But after memorizing them the wasted screen space gets annoying..
(defvar *debug-beginner-help-p* t
  "Should the debugger display beginner-oriented help messages?")

(defun debug-prompt (stream)
  (sb!thread::get-foreground)
  (format stream
	  "~%~W~:[~;[~W~]] "
	  (sb!di:frame-number *current-frame*)
	  (> *debug-command-level* 1)
	  *debug-command-level*))
  
(defparameter *debug-help-string*
"The debug prompt is square brackets, with number(s) indicating the current
  control stack level and, if you've entered the debugger recursively, how
  deeply recursed you are.
Any command -- including the name of a restart -- may be uniquely abbreviated.
The debugger rebinds various special variables for controlling i/o, sometimes
  to defaults (much like WITH-STANDARD-IO-SYNTAX does) and sometimes to 
  its own special values, based on SB-EXT:*DEBUG-PRINT-VARIBALE-ALIST*.
Debug commands do not affect *, //, and similar variables, but evaluation in
  the debug loop does affect these variables.
SB-DEBUG:*FLUSH-DEBUG-ERRORS* controls whether errors at the debug prompt
  drop you deeper into the debugger.

Getting in and out of the debugger:
  RESTART  invokes restart numbered as shown (prompt if not given).
  ERROR    prints the error condition and restart cases.
  The number of any restart, or its name, or a unique abbreviation for its
    name, is a valid command, and is the same as using RESTART to invoke
    that restart.

Changing frames:
  U      up frame     D    down frame
  B  bottom frame     F n  frame n (n=0 for top frame)

Inspecting frames:
  BACKTRACE [n]  shows n frames going down the stack.
  LIST-LOCALS, L lists locals in current function.
  PRINT, P       displays current function call.
  SOURCE [n]     displays frame's source form with n levels of enclosing forms.

Stepping:
  STEP                              
    [EXPERIMENTAL] Selects the CONTINUE restart if one exists and starts 
    single-stepping. Single stepping affects only code compiled with
    under high DEBUG optimization quality. See User Manul for details.

Function and macro commands:
 (SB-DEBUG:ARG n)
    Return the n'th argument in the current frame.
 (SB-DEBUG:VAR string-or-symbol [id])
    Returns the value of the specified variable in the current frame.

Other commands:
  RETURN expr
    [EXPERIMENTAL] Return the values resulting from evaluation of expr
    from the current frame, if this frame was compiled with a sufficiently
    high DEBUG optimization quality.
  SLURP
    Discard all pending input on *STANDARD-INPUT*. (This can be
    useful when the debugger was invoked to handle an error in
    deeply nested input syntax, and now the reader is confused.)")


;;; If LOC is an unknown location, then try to find the block start
;;; location. Used by source printing to some information instead of
;;; none for the user.
(defun maybe-block-start-location (loc)
  (if (sb!di:code-location-unknown-p loc)
      (let* ((block (sb!di:code-location-debug-block loc))
	     (start (sb!di:do-debug-block-locations (loc block)
		      (return loc))))
	(cond ((and (not (sb!di:debug-block-elsewhere-p block))
		    start)
	       ;; FIXME: Why output on T instead of *DEBUG-FOO* or something?
	       (format t "~%unknown location: using block start~%")
	       start)
	      (t
	       loc)))
      loc))

;;;; BACKTRACE

(defun backtrace (&optional (count most-positive-fixnum)
			    (*standard-output* *debug-io*))
  #!+sb-doc
  "Show a listing of the call stack going down from the current frame. In the
   debugger, the current frame is indicated by the prompt. COUNT is how many
   frames to show."
  (fresh-line *standard-output*)
  (do ((frame (if *in-the-debugger* *current-frame* (sb!di:top-frame))
	      (sb!di:frame-down frame))
       (count count (1- count)))
      ((or (null frame) (zerop count)))
    (print-frame-call frame :number t))
  (fresh-line *standard-output*)
  (values))

(defun backtrace-as-list (&optional (count most-positive-fixnum))
  #!+sb-doc "Return a list representing the current BACKTRACE."
  (do ((reversed-result nil)
       (frame (if *in-the-debugger* *current-frame* (sb!di:top-frame))
	      (sb!di:frame-down frame))
       (count count (1- count)))
      ((or (null frame) (zerop count))
       (nreverse reversed-result))
    (push (frame-call-as-list frame) reversed-result)))

(defun frame-call-as-list (frame)
  (cons (sb!di:debug-fun-name (sb!di:frame-debug-fun frame))
	(frame-args-as-list frame)))

;;;; frame printing

(eval-when (:compile-toplevel :execute)

;;; This is a convenient way to express what to do for each type of
;;; lambda-list element.
(sb!xc:defmacro lambda-list-element-dispatch (element
					      &key
					      required
					      optional
					      rest
					      keyword
					      deleted)
  `(etypecase ,element
     (sb!di:debug-var
      ,@required)
     (cons
      (ecase (car ,element)
	(:optional ,@optional)
	(:rest ,@rest)
	(:keyword ,@keyword)))
     (symbol
      (aver (eq ,element :deleted))
      ,@deleted)))

(sb!xc:defmacro lambda-var-dispatch (variable location deleted valid other)
  (let ((var (gensym)))
    `(let ((,var ,variable))
       (cond ((eq ,var :deleted) ,deleted)
	     ((eq (sb!di:debug-var-validity ,var ,location) :valid)
	      ,valid)
	     (t ,other)))))

) ; EVAL-WHEN

;;; This is used in constructing arg lists for debugger printing when
;;; the arg list is unavailable, some arg is unavailable or unused, etc.
(defstruct (unprintable-object
	    (:constructor make-unprintable-object (string))
	    (:print-object (lambda (x s)
			     (print-unreadable-object (x s)
			       (write-string (unprintable-object-string x)
					     s))))
	    (:copier nil))
  string)

;;; Extract the function argument values for a debug frame.
(defun frame-args-as-list (frame)
  (let ((debug-fun (sb!di:frame-debug-fun frame))
	(loc (sb!di:frame-code-location frame))
	(reversed-result nil))
    (handler-case
	(progn
	  (dolist (ele (sb!di:debug-fun-lambda-list debug-fun))
	    (lambda-list-element-dispatch ele
	     :required ((push (frame-call-arg ele loc frame) reversed-result))
	     :optional ((push (frame-call-arg (second ele) loc frame)
			      reversed-result))
	     :keyword ((push (second ele) reversed-result)
		       (push (frame-call-arg (third ele) loc frame)
			     reversed-result))
	     :deleted ((push (frame-call-arg ele loc frame) reversed-result))
	     :rest ((lambda-var-dispatch (second ele) loc
		     nil
		     (progn
		       (setf reversed-result
			     (append (reverse (sb!di:debug-var-value
					       (second ele) frame))
				     reversed-result))
		       (return))
		     (push (make-unprintable-object
			    "unavailable &REST argument")
		     reversed-result)))))
	  ;; As long as we do an ordinary return (as opposed to SIGNALing
	  ;; a CONDITION) from the DOLIST above:
	  (nreverse reversed-result))
      (sb!di:lambda-list-unavailable
       ()
       (make-unprintable-object "unavailable lambda list")))))

;;; Print FRAME with verbosity level 1. If we hit a &REST arg, then
;;; print as many of the values as possible, punting the loop over
;;; lambda-list variables since any other arguments will be in the
;;; &REST arg's list of values.
(defun print-frame-call-1 (frame)
  (let ((debug-fun (sb!di:frame-debug-fun frame)))

    (pprint-logical-block (*standard-output* nil :prefix "(" :suffix ")")
      (let ((args (ensure-printable-object (frame-args-as-list frame))))
	;; Since we go to some trouble to make nice informative function
	;; names like (PRINT-OBJECT :AROUND (CLOWN T)), let's make sure
	;; that they aren't truncated by *PRINT-LENGTH* and *PRINT-LEVEL*.
	(let ((*print-length* nil)
	      (*print-level* nil))
	  (prin1 (ensure-printable-object (sb!di:debug-fun-name debug-fun))))
	;; For the function arguments, we can just print normally.
        (if (listp args)
            (format t "~{ ~_~S~}" args)
            (format t " ~S" args))))

    (when (sb!di:debug-fun-kind debug-fun)
      (write-char #\[)
      (prin1 (sb!di:debug-fun-kind debug-fun))
      (write-char #\]))))

(defun ensure-printable-object (object)
  (handler-case
      (with-open-stream (out (make-broadcast-stream))
	(prin1 object out)
	object)
    (error (cond)
      (declare (ignore cond))
      (make-unprintable-object "error printing object"))))

(defun frame-call-arg (var location frame)
  (lambda-var-dispatch var location
    (make-unprintable-object "unused argument")
    (sb!di:debug-var-value var frame)
    (make-unprintable-object "unavailable argument")))

;;; Prints a representation of the function call causing FRAME to
;;; exist. VERBOSITY indicates the level of information to output;
;;; zero indicates just printing the DEBUG-FUN's name, and one
;;; indicates displaying call-like, one-liner format with argument
;;; values.
(defun print-frame-call (frame &key (verbosity 1) (number nil))
  (cond
   ((zerop verbosity)
    (when number
      (format t "~&~S: " (sb!di:frame-number frame)))
    (format t "~S" frame))
   (t
    (when number
      (format t "~&~S: " (sb!di:frame-number frame)))
    (print-frame-call-1 frame)))
  (when (>= verbosity 2)
    (let ((loc (sb!di:frame-code-location frame)))
      (handler-case
	  (progn
	    (sb!di:code-location-debug-block loc)
	    (format t "~%source: ")
	    (print-code-location-source-form loc 0))
	(sb!di:debug-condition (ignore) ignore)
	(error (c) (format t "error finding source: ~A" c))))))

;;;; INVOKE-DEBUGGER

(defvar *debugger-hook* nil
  #!+sb-doc
  "This is either NIL or a function of two arguments, a condition and the value
   of *DEBUGGER-HOOK*. This function can either handle the condition or return
   which causes the standard debugger to execute. The system passes the value
   of this variable to the function because it binds *DEBUGGER-HOOK* to NIL
   around the invocation.")

(defvar *invoke-debugger-hook* nil
  #!+sb-doc
  "This is either NIL or a designator for a function of two arguments,
   to be run when the debugger is about to be entered.  The function is
   run with *INVOKE-DEBUGGER-HOOK* bound to NIL to minimize recursive
   errors, and receives as arguments the condition that triggered 
   debugger entry and the previous value of *INVOKE-DEBUGGER-HOOK*   

   This mechanism is an SBCL extension similar to the standard *DEBUGGER-HOOK*.
   In contrast to *DEBUGGER-HOOK*, it is observed by INVOKE-DEBUGGER even when
   called by BREAK.")

;;; These are bound on each invocation of INVOKE-DEBUGGER.
(defvar *debug-restarts*)
(defvar *debug-condition*)
(defvar *nested-debug-condition*)

;;; Oh, what a tangled web we weave when we preserve backwards
;;; compatibility with 1968-style use of global variables to control
;;; per-stream i/o properties; there's really no way to get this
;;; quite right, but we do what we can.
(defun funcall-with-debug-io-syntax (fun &rest rest)
  (declare (type function fun))
  ;; Try to force the other special variables into a useful state.
  (let (;; Protect from WITH-STANDARD-IO-SYNTAX some variables where
	;; any default we might use is less useful than just reusing
	;; the global values.
	(original-package *package*)
	(original-print-pretty *print-pretty*))
    (with-standard-io-syntax
      (with-sane-io-syntax
          (let (;; We want the printer and reader to be in a useful
                ;; state, regardless of where the debugger was invoked
                ;; in the program. WITH-STANDARD-IO-SYNTAX and
                ;; WITH-SANE-IO-SYNTAX do much of what we want, but
                ;;   * It doesn't affect our internal special variables 
                ;;     like *CURRENT-LEVEL-IN-PRINT*.
                ;;   * It isn't customizable.
                ;;   * It sets *PACKAGE* to COMMON-LISP-USER, which is not
                ;;     helpful behavior for a debugger.
                ;;   * There's no particularly good debugger default for
                ;;     *PRINT-PRETTY*, since T is usually what you want
                ;;     -- except absolutely not what you want when you're
                ;;     debugging failures in PRINT-OBJECT logic.
                ;; We try to address all these issues with explicit
                ;; rebindings here.
                (sb!kernel:*current-level-in-print* 0)
                (*package* original-package)
                (*print-pretty* original-print-pretty)
                ;; Clear the circularity machinery to try to to reduce the
                ;; pain from sharing the circularity table across all
                ;; streams; if these are not rebound here, then setting
                ;; *PRINT-CIRCLE* within the debugger when debugging in a
                ;; state where something circular was being printed (e.g.,
                ;; because the debugger was entered on an error in a
                ;; PRINT-OBJECT method) makes a hopeless mess. Binding them
                ;; here does seem somewhat ugly because it makes it more
                ;; difficult to debug the printing-of-circularities code
                ;; itself; however, as far as I (WHN, 2004-05-29) can see,
                ;; that's almost entirely academic as long as there's one
                ;; shared *C-H-T* for all streams (i.e., it's already
                ;; unreasonably difficult to debug print-circle machinery
                ;; given the buggy crosstalk between the debugger streams
                ;; and the stream you're trying to watch), and any fix for
                ;; that buggy arrangement will likely let this hack go away
                ;; naturally.
                (sb!impl::*circularity-hash-table* . nil)
                (sb!impl::*circularity-counter* . nil)
                (*readtable* *debug-readtable*))
            (progv
                ;; (Why NREVERSE? PROGV makes the later entries have
                ;; precedence over the earlier entries.
                ;; *DEBUG-PRINT-VARIABLE-ALIST* is called an alist, so it's
                ;; expected that its earlier entries have precedence. And
                ;; the earlier-has-precedence behavior is mostly more
                ;; convenient, so that programmers can use PUSH or LIST* to
                ;; customize *DEBUG-PRINT-VARIABLE-ALIST*.)
                (nreverse (mapcar #'car *debug-print-variable-alist*))
                (nreverse (mapcar #'cdr *debug-print-variable-alist*))
              (apply fun rest)))))))

;;; the ordinary ANSI case of INVOKE-DEBUGGER, when not suppressed by
;;; command-line --disable-debugger option
(defun invoke-debugger (condition)
  #!+sb-doc
  "Enter the debugger."

  (let ((old-hook *debugger-hook*))
    (when old-hook
      (let ((*debugger-hook* nil))
	(funcall old-hook condition old-hook))))
  (let ((old-hook *invoke-debugger-hook*))
    (when old-hook
      (let ((*invoke-debugger-hook* nil))
	(funcall old-hook condition old-hook))))

  ;; Note: CMU CL had (SB-UNIX:UNIX-SIGSETMASK 0) here, to reset the
  ;; signal state in the case that we wind up in the debugger as a
  ;; result of something done by a signal handler.  It's not
  ;; altogether obvious that this is necessary, and indeed SBCL has
  ;; not been doing it since 0.7.8.5.  But nobody seems altogether
  ;; convinced yet
  ;; -- dan 2003.11.11, based on earlier comment of WHN 2002-09-28

  ;; We definitely want *PACKAGE* to be of valid type.
  ;;
  ;; Elsewhere in the system, we use the SANE-PACKAGE function for
  ;; this, but here causing an exception just as we're trying to handle
  ;; an exception would be confusing, so instead we use a special hack.
  (unless (and (packagep *package*)
	       (package-name *package*))
    (setf *package* (find-package :cl-user))
    (format *error-output*
	    "The value of ~S was not an undeleted PACKAGE. It has been
reset to ~S."
	    '*package* *package*))

  ;; Before we start our own output, finish any pending output.
  ;; Otherwise, if the user tried to track the progress of his program
  ;; using PRINT statements, he'd tend to lose the last line of output
  ;; or so, which'd be confusing.
  (flush-standard-output-streams)

  (funcall-with-debug-io-syntax #'%invoke-debugger condition))

(defun %invoke-debugger (condition)
  
  (let ((*debug-condition* condition)
	(*debug-restarts* (compute-restarts condition))
	(*nested-debug-condition* nil))
    (handler-case
	;; (The initial output here goes to *ERROR-OUTPUT*, because the
	;; initial output is not interactive, just an error message, and
	;; when people redirect *ERROR-OUTPUT*, they could reasonably
	;; expect to see error messages logged there, regardless of what
	;; the debugger does afterwards.)
	(format *error-output*
		"~2&~@<debugger invoked on a ~S in thread ~A: ~
                    ~2I~_~A~:>~%"
		(type-of *debug-condition*)
		(sb!thread:current-thread-id)
		*debug-condition*)
      (error (condition)
	(setf *nested-debug-condition* condition)
	(let ((ndc-type (type-of *nested-debug-condition*)))
	  (format *error-output*
		  "~&~@<(A ~S was caught when trying to print ~S when ~
                      entering the debugger. Printing was aborted and the ~
                      ~S was stored in ~S.)~@:>~%"
		  ndc-type
		  '*debug-condition*
		  ndc-type
		  '*nested-debug-condition*))
	(when (typep condition 'cell-error)
	  ;; what we really want to know when it's e.g. an UNBOUND-VARIABLE:
	  (format *error-output*
		  "~&(CELL-ERROR-NAME ~S) = ~S~%"
		  '*debug-condition*
		  (cell-error-name *debug-condition*)))))

    (let ((background-p (sb!thread::debugger-wait-until-foreground-thread
			 *debug-io*)))

      ;; After the initial error/condition/whatever announcement to
      ;; *ERROR-OUTPUT*, we become interactive, and should talk on
      ;; *DEBUG-IO* from now on. (KLUDGE: This is a normative
      ;; statement, not a description of reality.:-| There's a lot of
      ;; older debugger code which was written to do i/o on whatever
      ;; stream was in fashion at the time, and not all of it has
      ;; been converted to behave this way. -- WHN 2000-11-16)

      (unwind-protect
	   (let (;; FIXME: Rebinding *STANDARD-OUTPUT* here seems wrong,
		 ;; violating the principle of least surprise, and making
		 ;; it impossible for the user to do reasonable things
		 ;; like using PRINT at the debugger prompt to send output
		 ;; to the program's ordinary (possibly
		 ;; redirected-to-a-file) *STANDARD-OUTPUT*. (CMU CL
		 ;; used to rebind *STANDARD-INPUT* here too, but that's
		 ;; been fixed already.)
		 (*standard-output* *debug-io*)
		 ;; This seems reasonable: e.g. if the user has redirected
		 ;; *ERROR-OUTPUT* to some log file, it's probably wrong
		 ;; to send errors which occur in interactive debugging to
		 ;; that file, and right to send them to *DEBUG-IO*.
		 (*error-output* *debug-io*))
	     (unless (typep condition 'step-condition)
	       (when *debug-beginner-help-p*
		 (format *debug-io*
			 "~%~@<You can type HELP for debugger help, or ~
                               (SB-EXT:QUIT) to exit from SBCL.~:@>~2%"))
	       (show-restarts *debug-restarts* *debug-io*))
	     (internal-debug))
	(when background-p
	  (sb!thread::release-foreground))))))

;;; this function is for use in *INVOKE-DEBUGGER-HOOK* when ordinary
;;; ANSI behavior has been suppressed by the "--disable-debugger"
;;; command-line option
(defun debugger-disabled-hook (condition me)
  (declare (ignore me))
  ;; There is no one there to interact with, so report the
  ;; condition and terminate the program.
  (flet ((failure-quit (&key recklessly-p)
           (/show0 "in FAILURE-QUIT (in --disable-debugger debugger hook)")
	   (quit :unix-status 1 :recklessly-p recklessly-p)))
    ;; This HANDLER-CASE is here mostly to stop output immediately
    ;; (and fall through to QUIT) when there's an I/O error. Thus,
    ;; when we're run under a shell script or something, we can die
    ;; cleanly when the script dies (and our pipes are cut), instead
    ;; of falling into ldb or something messy like that. Similarly, we
    ;; can terminate cleanly even if BACKTRACE dies because of bugs in
    ;; user PRINT-OBJECT methods.
    (handler-case
	(progn
	  (format *error-output*
		  "~&~@<unhandled ~S in thread ~S: ~2I~_~A~:>~2%"
		  (type-of condition)
		  (sb!thread:current-thread-id)
		  condition)
	  ;; Flush *ERROR-OUTPUT* even before the BACKTRACE, so that
	  ;; even if we hit an error within BACKTRACE (e.g. a bug in
	  ;; the debugger's own frame-walking code, or a bug in a user
	  ;; PRINT-OBJECT method) we'll at least have the CONDITION
	  ;; printed out before we die.
	  (finish-output *error-output*)
	  ;; (Where to truncate the BACKTRACE is of course arbitrary, but
	  ;; it seems as though we should at least truncate it somewhere.)
	  (sb!debug:backtrace 128 *error-output*)
	  (format
	   *error-output*
	   "~%unhandled condition in --disable-debugger mode, quitting~%")
	  (finish-output *error-output*)
	  (failure-quit))
      (condition ()
	;; We IGNORE-ERRORS here because even %PRIMITIVE PRINT can
	;; fail when our output streams are blown away, as e.g. when
	;; we're running under a Unix shell script and it dies somehow
	;; (e.g. because of a SIGINT). In that case, we might as well
	;; just give it up for a bad job, and stop trying to notify
	;; the user of anything.
        ;;
        ;; Actually, the only way I've run across to exercise the
	;; problem is to have more than one layer of shell script.
	;; I have a shell script which does
	;;   time nice -10 sh make.sh "$1" 2>&1 | tee make.tmp
	;; and the problem occurs when I interrupt this with Ctrl-C
	;; under Linux 2.2.14-5.0 and GNU bash, version 1.14.7(1).
        ;; I haven't figured out whether it's bash, time, tee, Linux, or
	;; what that is responsible, but that it's possible at all
	;; means that we should IGNORE-ERRORS here. -- WHN 2001-04-24
        (ignore-errors
         (%primitive print
		     "Argh! error within --disable-debugger error handling"))
	(failure-quit :recklessly-p t)))))

;;; halt-on-failures and prompt-on-failures modes, suitable for
;;; noninteractive and interactive use respectively
(defun disable-debugger ()
  (when (eql *invoke-debugger-hook* nil)
    (setf *debug-io* *error-output*
	  *invoke-debugger-hook* 'debugger-disabled-hook)))

(defun enable-debugger ()
  (when (eql *invoke-debugger-hook* 'debugger-disabled-hook)
    (setf *invoke-debugger-hook* nil)))

(setf *debug-io* *query-io*)

(defun show-restarts (restarts s)
  (cond ((null restarts)
	 (format s
		 "~&(no restarts: If you didn't do this on purpose, ~
                  please report it as a bug.)~%"))
	(t
	 (format s "~&restarts (invokable by number or by ~
                    possibly-abbreviated name):~%")
	 (let ((count 0)
	       (names-used '(nil))
	       (max-name-len 0))
	   (dolist (restart restarts)
	     (let ((name (restart-name restart)))
	       (when name
		 (let ((len (length (princ-to-string name))))
		   (when (> len max-name-len)
		     (setf max-name-len len))))))
	   (unless (zerop max-name-len)
	     (incf max-name-len 3))
	   (dolist (restart restarts)
	     (let ((name (restart-name restart)))
	       (cond ((member name names-used)
		      (format s "~& ~2D: ~V@T~A~%" count max-name-len restart))
		     (t
		      (format s "~& ~2D: [~VA] ~A~%"
			      count (- max-name-len 3) name restart)
		      (push name names-used))))
	     (incf count))))))

(defvar *debug-loop-fun* #'debug-loop-fun
  "a function taking no parameters that starts the low-level debug loop")

;;; This calls DEBUG-LOOP, performing some simple initializations
;;; before doing so. INVOKE-DEBUGGER calls this to actually get into
;;; the debugger. SB!KERNEL::ERROR-ERROR calls this in emergencies
;;; to get into a debug prompt as quickly as possible with as little
;;; risk as possible for stepping on whatever is causing recursive
;;; errors.
(defun internal-debug ()
  (let ((*in-the-debugger* t)
	(*read-suppress* nil))
    (unless (typep *debug-condition* 'step-condition)
      (clear-input *debug-io*))
    (funcall *debug-loop-fun*)))

;;;; DEBUG-LOOP

;;; Note: This defaulted to T in CMU CL. The changed default in SBCL
;;; was motivated by desire to play nicely with ILISP.
(defvar *flush-debug-errors* nil
  #!+sb-doc
  "When set, avoid calling INVOKE-DEBUGGER recursively when errors occur while
   executing in the debugger.")

(defun debug-loop-fun ()
  (let* ((*debug-command-level* (1+ *debug-command-level*))
	 (*real-stack-top* (sb!di:top-frame))
	 (*stack-top* (or *stack-top-hint* *real-stack-top*))
	 (*stack-top-hint* nil)
	 (*current-frame* *stack-top*))
    (handler-bind ((sb!di:debug-condition
		    (lambda (condition)
		      (princ condition *debug-io*)
		      (/show0 "handling d-c by THROWing DEBUG-LOOP-CATCHER")
		      (throw 'debug-loop-catcher nil))))
      (fresh-line)
      (print-frame-call *current-frame* :verbosity 2)
      (loop
	(catch 'debug-loop-catcher
	  (handler-bind ((error (lambda (condition)
				  (when *flush-debug-errors*
				    (clear-input *debug-io*)
				    (princ condition)
				    ;; FIXME: Doing input on *DEBUG-IO*
				    ;; and output on T seems broken.
				    (format t
					    "~&error flushed (because ~
                                             ~S is set)"
					    '*flush-debug-errors*)
				    (/show0 "throwing DEBUG-LOOP-CATCHER")
				    (throw 'debug-loop-catcher nil)))))
	    ;; We have to bind LEVEL for the restart function created by
	    ;; WITH-SIMPLE-RESTART.
	    (let ((level *debug-command-level*)
		  (restart-commands (make-restart-commands)))
	      (with-simple-restart (abort
				   "~@<Reduce debugger level (to debug level ~W).~@:>"
				    level)
		(debug-prompt *debug-io*)
		(force-output *debug-io*)
		(let* ((exp (read *debug-io*))
		       (cmd-fun (debug-command-p exp restart-commands)))
		  (cond ((not cmd-fun)
			 (debug-eval-print exp))
			((consp cmd-fun)
			 (format t "~&Your command, ~S, is ambiguous:~%"
				 exp)
			 (dolist (ele cmd-fun)
			   (format t "   ~A~%" ele)))
			(t
			 (funcall cmd-fun))))))))))))

;;; FIXME: We could probably use INTERACTIVE-EVAL for much of this logic.
(defun debug-eval-print (expr)
  (/noshow "entering DEBUG-EVAL-PRINT" expr)
  (/noshow (fboundp 'compile))
  (setq +++ ++ ++ + + - - expr)
  (let* ((values (multiple-value-list (eval -)))
	 (*standard-output* *debug-io*))
    (/noshow "done with EVAL in DEBUG-EVAL-PRINT")
    (fresh-line)
    (if values (prin1 (car values)))
    (dolist (x (cdr values))
      (fresh-line)
      (prin1 x))
    (setq /// // // / / values)
    (setq *** ** ** * * (car values))
    ;; Make sure that nobody passes back an unbound marker.
    (unless (boundp '*)
      (setq * nil)
      (fresh-line)
      ;; FIXME: The way INTERACTIVE-EVAL does this seems better.
      (princ "Setting * to NIL (was unbound marker)."))))

;;;; debug loop functions

;;; These commands are functions, not really commands, so that users
;;; can get their hands on the values returned.

(eval-when (:execute :compile-toplevel)

(sb!xc:defmacro define-var-operation (ref-or-set &optional value-var)
  `(let* ((temp (etypecase name
		  (symbol (sb!di:debug-fun-symbol-vars
			   (sb!di:frame-debug-fun *current-frame*)
			   name))
		  (simple-string (sb!di:ambiguous-debug-vars
				  (sb!di:frame-debug-fun *current-frame*)
				  name))))
	  (location (sb!di:frame-code-location *current-frame*))
	  ;; Let's only deal with valid variables.
	  (vars (remove-if-not (lambda (v)
				 (eq (sb!di:debug-var-validity v location)
				     :valid))
			       temp)))
     (declare (list vars))
     (cond ((null vars)
	    (error "No known valid variables match ~S." name))
	   ((= (length vars) 1)
	    ,(ecase ref-or-set
	       (:ref
		'(sb!di:debug-var-value (car vars) *current-frame*))
	       (:set
		`(setf (sb!di:debug-var-value (car vars) *current-frame*)
		       ,value-var))))
	   (t
	    ;; Since we have more than one, first see whether we have
	    ;; any variables that exactly match the specification.
	    (let* ((name (etypecase name
			   (symbol (symbol-name name))
			   (simple-string name)))
		   ;; FIXME: REMOVE-IF-NOT is deprecated, use STRING/=
		   ;; instead.
		   (exact (remove-if-not (lambda (v)
					   (string= (sb!di:debug-var-symbol-name v)
						    name))
					 vars))
		   (vars (or exact vars)))
	      (declare (simple-string name)
		       (list exact vars))
	      (cond
	       ;; Check now for only having one variable.
	       ((= (length vars) 1)
		,(ecase ref-or-set
		   (:ref
		    '(sb!di:debug-var-value (car vars) *current-frame*))
		   (:set
		    `(setf (sb!di:debug-var-value (car vars) *current-frame*)
			   ,value-var))))
	       ;; If there weren't any exact matches, flame about
	       ;; ambiguity unless all the variables have the same
	       ;; name.
	       ((and (not exact)
		     (find-if-not
		      (lambda (v)
			(string= (sb!di:debug-var-symbol-name v)
				 (sb!di:debug-var-symbol-name (car vars))))
		      (cdr vars)))
		(error "specification ambiguous:~%~{   ~A~%~}"
		       (mapcar #'sb!di:debug-var-symbol-name
			       (delete-duplicates
				vars :test #'string=
				:key #'sb!di:debug-var-symbol-name))))
	       ;; All names are the same, so see whether the user
	       ;; ID'ed one of them.
	       (id-supplied
		(let ((v (find id vars :key #'sb!di:debug-var-id)))
		  (unless v
		    (error
		     "invalid variable ID, ~W: should have been one of ~S"
		     id
		     (mapcar #'sb!di:debug-var-id vars)))
		  ,(ecase ref-or-set
		     (:ref
		      '(sb!di:debug-var-value v *current-frame*))
		     (:set
		      `(setf (sb!di:debug-var-value v *current-frame*)
			     ,value-var)))))
	       (t
		(error "Specify variable ID to disambiguate ~S. Use one of ~S."
		       name
		       (mapcar #'sb!di:debug-var-id vars)))))))))

) ; EVAL-WHEN

;;; FIXME: This doesn't work. It would be real nice we could make it
;;; work! Alas, it doesn't seem to work in CMU CL X86 either..
(defun var (name &optional (id 0 id-supplied))
  #!+sb-doc
  "Return a variable's value if possible. NAME is a simple-string or symbol.
   If it is a simple-string, it is an initial substring of the variable's name.
   If name is a symbol, it has the same name and package as the variable whose
   value this function returns. If the symbol is uninterned, then the variable
   has the same name as the symbol, but it has no package.

   If name is the initial substring of variables with different names, then
   this return no values after displaying the ambiguous names. If name
   determines multiple variables with the same name, then you must use the
   optional id argument to specify which one you want. If you left id
   unspecified, then this returns no values after displaying the distinguishing
   id values.

   The result of this function is limited to the availability of variable
   information. This is SETF'able."
  (define-var-operation :ref))
(defun (setf var) (value name &optional (id 0 id-supplied))
  (define-var-operation :set value))

;;; This returns the COUNT'th arg as the user sees it from args, the
;;; result of SB!DI:DEBUG-FUN-LAMBDA-LIST. If this returns a
;;; potential DEBUG-VAR from the lambda-list, then the second value is
;;; T. If this returns a keyword symbol or a value from a rest arg,
;;; then the second value is NIL.
;;;
;;; FIXME: There's probably some way to merge the code here with
;;; FRAME-ARGS-AS-LIST. (A fair amount of logic is already shared
;;; through LAMBDA-LIST-ELEMENT-DISPATCH, but I suspect more could be.)
(declaim (ftype (function (index list)) nth-arg))
(defun nth-arg (count args)
  (let ((n count))
    (dolist (ele args (error "The argument specification ~S is out of range."
			     n))
      (lambda-list-element-dispatch ele
	:required ((if (zerop n) (return (values ele t))))
	:optional ((if (zerop n) (return (values (second ele) t))))
	:keyword ((cond ((zerop n)
			 (return (values (second ele) nil)))
			((zerop (decf n))
			 (return (values (third ele) t)))))
	:deleted ((if (zerop n) (return (values ele t))))
	:rest ((let ((var (second ele)))
		 (lambda-var-dispatch var (sb!di:frame-code-location
					   *current-frame*)
		   (error "unused &REST argument before n'th argument")
		   (dolist (value
			    (sb!di:debug-var-value var *current-frame*)
			    (error
			     "The argument specification ~S is out of range."
			     n))
		     (if (zerop n)
			 (return-from nth-arg (values value nil))
			 (decf n)))
		   (error "invalid &REST argument before n'th argument")))))
      (decf n))))

(defun arg (n)
  #!+sb-doc
  "Return the N'th argument's value if possible. Argument zero is the first
   argument in a frame's default printed representation. Count keyword/value
   pairs as separate arguments."
  (multiple-value-bind (var lambda-var-p)
      (nth-arg n (handler-case (sb!di:debug-fun-lambda-list
				(sb!di:frame-debug-fun *current-frame*))
		   (sb!di:lambda-list-unavailable ()
		     (error "No argument values are available."))))
    (if lambda-var-p
	(lambda-var-dispatch var (sb!di:frame-code-location *current-frame*)
	  (error "Unused arguments have no values.")
	  (sb!di:debug-var-value var *current-frame*)
	  (error "invalid argument value"))
	var)))

;;;; machinery for definition of debug loop commands

(defvar *debug-commands* nil)

;;; Interface to *DEBUG-COMMANDS*. No required arguments in args are
;;; permitted.
(defmacro !def-debug-command (name args &rest body)
  (let ((fun-name (symbolicate name "-DEBUG-COMMAND")))
    `(progn
       (setf *debug-commands*
	     (remove ,name *debug-commands* :key #'car :test #'string=))
       (defun ,fun-name ,args
	 (unless *in-the-debugger*
	   (error "invoking debugger command while outside the debugger"))
	 ,@body)
       (push (cons ,name #',fun-name) *debug-commands*)
       ',fun-name)))

(defun !def-debug-command-alias (new-name existing-name)
  (let ((pair (assoc existing-name *debug-commands* :test #'string=)))
    (unless pair (error "unknown debug command name: ~S" existing-name))
    (push (cons new-name (cdr pair)) *debug-commands*))
  new-name)

;;; This takes a symbol and uses its name to find a debugger command,
;;; using initial substring matching. It returns the command function
;;; if form identifies only one command, but if form is ambiguous,
;;; this returns a list of the command names. If there are no matches,
;;; this returns nil. Whenever the loop that looks for a set of
;;; possibilities encounters an exact name match, we return that
;;; command function immediately.
(defun debug-command-p (form &optional other-commands)
  (if (or (symbolp form) (integerp form))
      (let* ((name
	      (if (symbolp form)
		  (symbol-name form)
		  (format nil "~W" form)))
	     (len (length name))
	     (res nil))
	(declare (simple-string name)
		 (fixnum len)
		 (list res))

	;; Find matching commands, punting if exact match.
	(flet ((match-command (ele)
		 (let* ((str (car ele))
			(str-len (length str)))
		   (declare (simple-string str)
			    (fixnum str-len))
		   (cond ((< str-len len))
			 ((= str-len len)
			  (when (string= name str :end1 len :end2 len)
			    (return-from debug-command-p (cdr ele))))
			 ((string= name str :end1 len :end2 len)
			  (push ele res))))))
	  (mapc #'match-command *debug-commands*)
	  (mapc #'match-command other-commands))

	;; Return the right value.
	(cond ((not res) nil)
	      ((= (length res) 1)
	       (cdar res))
	      (t ; Just return the names.
	       (do ((cmds res (cdr cmds)))
		   ((not cmds) res)
		 (setf (car cmds) (caar cmds))))))))

;;; Return a list of debug commands (in the same format as
;;; *DEBUG-COMMANDS*) that invoke each active restart.
;;;
;;; Two commands are made for each restart: one for the number, and
;;; one for the restart name (unless it's been shadowed by an earlier
;;; restart of the same name, or it is NIL).
(defun make-restart-commands (&optional (restarts *debug-restarts*))
  (let ((commands)
	(num 0))			; better be the same as show-restarts!
    (dolist (restart restarts)
      (let ((name (string (restart-name restart))))
        (let ((restart-fun
                (lambda ()
		  (/show0 "in restart-command closure, about to i-r-i")
		  (invoke-restart-interactively restart))))
          (push (cons (prin1-to-string num) restart-fun) commands)
          (unless (or (null (restart-name restart)) 
                      (find name commands :key #'car :test #'string=))
            (push (cons name restart-fun) commands))))
    (incf num))
  commands))

;;;; frame-changing commands

(!def-debug-command "UP" ()
  (let ((next (sb!di:frame-up *current-frame*)))
    (cond (next
	   (setf *current-frame* next)
	   (print-frame-call next))
	  (t
	   (format t "~&Top of stack.")))))

(!def-debug-command "DOWN" ()
  (let ((next (sb!di:frame-down *current-frame*)))
    (cond (next
	   (setf *current-frame* next)
	   (print-frame-call next))
	  (t
	   (format t "~&Bottom of stack.")))))

(!def-debug-command-alias "D" "DOWN")

;;; CMU CL had this command, but SBCL doesn't, since it's redundant
;;; with "FRAME 0", and it interferes with abbreviations for the
;;; TOPLEVEL restart.
;;;(!def-debug-command "TOP" ()
;;;  (do ((prev *current-frame* lead)
;;;       (lead (sb!di:frame-up *current-frame*) (sb!di:frame-up lead)))
;;;      ((null lead)
;;;       (setf *current-frame* prev)
;;;       (print-frame-call prev))))

(!def-debug-command "BOTTOM" ()
  (do ((prev *current-frame* lead)
       (lead (sb!di:frame-down *current-frame*) (sb!di:frame-down lead)))
      ((null lead)
       (setf *current-frame* prev)
       (print-frame-call prev))))

(!def-debug-command-alias "B" "BOTTOM")

(!def-debug-command "FRAME" (&optional
			     (n (read-prompting-maybe "frame number: ")))
  (setf *current-frame*
	(multiple-value-bind (next-frame-fun limit-string)
	    (if (< n (sb!di:frame-number *current-frame*))
		(values #'sb!di:frame-up "top")
	      (values #'sb!di:frame-down "bottom"))
	  (do ((frame *current-frame*))
	      ((= n (sb!di:frame-number frame))
	       frame)
	    (let ((next-frame (funcall next-frame-fun frame)))
	      (cond (next-frame
		     (setf frame next-frame))
		    (t
		     (format t
			     "The ~A of the stack was encountered.~%"
			     limit-string)
		     (return frame)))))))
  (print-frame-call *current-frame*))

(!def-debug-command-alias "F" "FRAME")

;;;; commands for entering and leaving the debugger

;;; CMU CL supported this QUIT debug command, but SBCL provides this
;;; functionality with a restart instead. (The QUIT debug command was
;;; removed because it's confusing to have "quit" mean two different
;;; things in the system, "restart the top level REPL" in the debugger
;;; and "terminate the Lisp system" as the SB-EXT:QUIT function.)
;;;
;;;(!def-debug-command "QUIT" ()
;;;  (throw 'sb!impl::toplevel-catcher nil))

;;; CMU CL supported this GO debug command, but SBCL doesn't -- in
;;; SBCL you just type the CONTINUE restart name instead (or "C" or
;;; "RESTART CONTINUE", that's OK too).
;;;(!def-debug-command "GO" ()
;;;  (continue *debug-condition*)
;;;  (error "There is no restart named CONTINUE."))

(!def-debug-command "RESTART" ()
  (/show0 "doing RESTART debug-command")
  (let ((num (read-if-available :prompt)))
    (when (eq num :prompt)
      (show-restarts *debug-restarts* *debug-io*)
      (write-string "restart: ")
      (force-output)
      (setf num (read *debug-io*)))
    (let ((restart (typecase num
		     (unsigned-byte
		      (nth num *debug-restarts*))
		     (symbol
		      (find num *debug-restarts* :key #'restart-name
			    :test (lambda (sym1 sym2)
				    (string= (symbol-name sym1)
					     (symbol-name sym2)))))
		     (t
		      (format t "~S is invalid as a restart name.~%" num)
		      (return-from restart-debug-command nil)))))
      (/show0 "got RESTART")
      (if restart
	  (invoke-restart-interactively restart)
	  ;; FIXME: Even if this isn't handled by WARN, it probably
	  ;; shouldn't go to *STANDARD-OUTPUT*, but *ERROR-OUTPUT* or
	  ;; *QUERY-IO* or something. Look through this file to
	  ;; straighten out stream usage.
	  (princ "There is no such restart.")))))

;;;; information commands

(!def-debug-command "HELP" ()
  ;; CMU CL had a little toy pager here, but "if you aren't running
  ;; ILISP (or a smart windowing system, or something) you deserve to
  ;; lose", so we've dropped it in SBCL. However, in case some
  ;; desperate holdout is running this on a dumb terminal somewhere,
  ;; we tell him where to find the message stored as a string.
  (format *debug-io*
	  "~&~A~2%(The HELP string is stored in ~S.)~%"
	  *debug-help-string*
	  '*debug-help-string*))

(!def-debug-command-alias "?" "HELP")

(!def-debug-command "ERROR" ()
  (format *debug-io* "~A~%" *debug-condition*)
  (show-restarts *debug-restarts* *debug-io*))

(!def-debug-command "BACKTRACE" ()
  (backtrace (read-if-available most-positive-fixnum)))

(!def-debug-command "PRINT" ()
  (print-frame-call *current-frame*))

(!def-debug-command-alias "P" "PRINT")

(!def-debug-command "LIST-LOCALS" ()
  (let ((d-fun (sb!di:frame-debug-fun *current-frame*)))
    (if (sb!di:debug-var-info-available d-fun)
	(let ((*standard-output* *debug-io*)
	      (location (sb!di:frame-code-location *current-frame*))
	      (prefix (read-if-available nil))
	      (any-p nil)
	      (any-valid-p nil))
	  (dolist (v (sb!di:ambiguous-debug-vars
			d-fun
			(if prefix (string prefix) "")))
	    (setf any-p t)
	    (when (eq (sb!di:debug-var-validity v location) :valid)
	      (setf any-valid-p t)
	      (format t "~S~:[#~W~;~*~]  =  ~S~%"
		      (sb!di:debug-var-symbol v)
		      (zerop (sb!di:debug-var-id v))
		      (sb!di:debug-var-id v)
		      (sb!di:debug-var-value v *current-frame*))))

	  (cond
	   ((not any-p)
	    (format t "There are no local variables ~@[starting with ~A ~]~
                       in the function."
		    prefix))
	   ((not any-valid-p)
	    (format t "All variables ~@[starting with ~A ~]currently ~
                       have invalid values."
		    prefix))))
	(write-line "There is no variable information available."))))

(!def-debug-command-alias "L" "LIST-LOCALS")

(!def-debug-command "SOURCE" ()
  (fresh-line)
  (print-code-location-source-form (sb!di:frame-code-location *current-frame*)
				   (read-if-available 0)))

;;;; source location printing

;;; We cache a stream to the last valid file debug source so that we
;;; won't have to repeatedly open the file.
;;;
;;; KLUDGE: This sounds like a bug, not a feature. Opening files is fast
;;; in the 1990s, so the benefit is negligible, less important than the
;;; potential of extra confusion if someone changes the source during
;;; a debug session and the change doesn't show up. And removing this
;;; would simplify the system, which I like. -- WHN 19990903
(defvar *cached-debug-source* nil)
(declaim (type (or sb!di:debug-source null) *cached-debug-source*))
(defvar *cached-source-stream* nil)
(declaim (type (or stream null) *cached-source-stream*))

;;; To suppress the read-time evaluation #. macro during source read,
;;; *READTABLE* is modified. *READTABLE* is cached to avoid
;;; copying it each time, and invalidated when the
;;; *CACHED-DEBUG-SOURCE* has changed.
(defvar *cached-readtable* nil)
(declaim (type (or readtable null) *cached-readtable*))

;;; Stuff to clean up before saving a core
(defun debug-deinit ()
  (setf *cached-debug-source* nil
	*cached-source-stream* nil
	*cached-readtable* nil))

;;; We also cache the last toplevel form that we printed a source for
;;; so that we don't have to do repeated reads and calls to
;;; FORM-NUMBER-TRANSLATIONS.
(defvar *cached-toplevel-form-offset* nil)
(declaim (type (or index null) *cached-toplevel-form-offset*))
(defvar *cached-toplevel-form*)
(defvar *cached-form-number-translations*)

;;; Given a code location, return the associated form-number
;;; translations and the actual top level form. We check our cache ---
;;; if there is a miss, we dispatch on the kind of the debug source.
(defun get-toplevel-form (location)
  (let ((d-source (sb!di:code-location-debug-source location)))
    (if (and (eq d-source *cached-debug-source*)
	     (eql (sb!di:code-location-toplevel-form-offset location)
		  *cached-toplevel-form-offset*))
	(values *cached-form-number-translations* *cached-toplevel-form*)
	(let* ((offset (sb!di:code-location-toplevel-form-offset location))
	       (res
		(ecase (sb!di:debug-source-from d-source)
		  (:file (get-file-toplevel-form location))
		  (:lisp (svref (sb!di:debug-source-name d-source) offset)))))
	  (setq *cached-toplevel-form-offset* offset)
	  (values (setq *cached-form-number-translations*
			(sb!di:form-number-translations res offset))
		  (setq *cached-toplevel-form* res))))))

;;; Locate the source file (if it still exists) and grab the top level
;;; form. If the file is modified, we use the top level form offset
;;; instead of the recorded character offset.
(defun get-file-toplevel-form (location)
  (let* ((d-source (sb!di:code-location-debug-source location))
	 (tlf-offset (sb!di:code-location-toplevel-form-offset location))
	 (local-tlf-offset (- tlf-offset
			      (sb!di:debug-source-root-number d-source)))
	 (char-offset
	  (aref (or (sb!di:debug-source-start-positions d-source)
		    (error "no start positions map"))
		local-tlf-offset))
	 (name (sb!di:debug-source-name d-source)))
    (unless (eq d-source *cached-debug-source*)
      (unless (and *cached-source-stream*
		   (equal (pathname *cached-source-stream*)
			  (pathname name)))
	(setq *cached-readtable* nil)
	(when *cached-source-stream* (close *cached-source-stream*))
	(setq *cached-source-stream* (open name :if-does-not-exist nil))
	(unless *cached-source-stream*
	  (error "The source file no longer exists:~%  ~A" (namestring name)))
	(format t "~%; file: ~A~%" (namestring name)))

	(setq *cached-debug-source*
	      (if (= (sb!di:debug-source-created d-source)
		     (file-write-date name))
		  d-source nil)))

    (cond
     ((eq *cached-debug-source* d-source)
      (file-position *cached-source-stream* char-offset))
     (t
      (format t "~%; File has been modified since compilation:~%;   ~A~@
                 ; Using form offset instead of character position.~%"
	      (namestring name))
      (file-position *cached-source-stream* 0)
      (let ((*read-suppress* t))
	(dotimes (i local-tlf-offset)
	  (read *cached-source-stream*)))))
    (unless *cached-readtable*
      (setq *cached-readtable* (copy-readtable))
      (set-dispatch-macro-character
       #\# #\.
       (lambda (stream sub-char &rest rest)
	 (declare (ignore rest sub-char))
	 (let ((token (read stream t nil t)))
	   (format nil "#.~S" token)))
       *cached-readtable*))
    (let ((*readtable* *cached-readtable*))
      (read *cached-source-stream*))))

(defun print-code-location-source-form (location context)
  (let* ((location (maybe-block-start-location location))
	 (form-num (sb!di:code-location-form-number location)))
    (multiple-value-bind (translations form) (get-toplevel-form location)
      (unless (< form-num (length translations))
	(error "The source path no longer exists."))
      (prin1 (sb!di:source-path-context form
					(svref translations form-num)
					context)))))

;;; step to the next steppable form
(!def-debug-command "STEP" ()
  (let ((restart (find-restart 'continue *debug-condition*)))
    (cond (restart
	   (setf *stepping* t
		 *step* t)
	   (invoke-restart restart))
	  (t
	   (format *debug-io* "~&Non-continuable error, cannot step.~%")))))

;;; miscellaneous commands

(!def-debug-command "DESCRIBE" ()
  (let* ((curloc (sb!di:frame-code-location *current-frame*))
	 (debug-fun (sb!di:code-location-debug-fun curloc))
	 (function (sb!di:debug-fun-fun debug-fun)))
    (if function
	(describe function)
	(format t "can't figure out the function for this frame"))))

(!def-debug-command "SLURP" ()
  (loop while (read-char-no-hang *standard-input*)))

(!def-debug-command "RETURN" (&optional
			      (return (read-prompting-maybe
				       "return: ")))
  (let ((tag (find-if (lambda (x)
			(and (typep (car x) 'symbol)
			     (not (symbol-package (car x)))
			     (string= (car x) "SB-DEBUG-CATCH-TAG")))
		      (sb!di::frame-catches *current-frame*))))
    (if tag
	(throw (car tag)
	  (funcall (sb!di:preprocess-for-eval
		    return
		    (sb!di:frame-code-location *current-frame*))
		   *current-frame*))
	(format t "~@<can't find a tag for this frame ~
                   ~2I~_(hint: try increasing the DEBUG optimization quality ~
                   and recompiling)~:@>"))))

;;;; debug loop command utilities

(defun read-prompting-maybe (prompt)
  (unless (sb!int:listen-skip-whitespace *debug-io*)
    (princ prompt)
    (force-output))
  (read *debug-io*))

(defun read-if-available (default)
  (if (sb!int:listen-skip-whitespace *debug-io*)
      (read *debug-io*)
      default))
