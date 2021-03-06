;;;; that part of the condition system which can or should come early
;;;; (mostly macro-related)

;;;; This software is part of the SBCL system. See the README file for
;;;; more information.
;;;;
;;;; This software is derived from the CMU CL system, which was
;;;; written at Carnegie Mellon University and released into the
;;;; public domain. The software is in the public domain and is
;;;; provided with absolutely no warranty. See the COPYING and CREDITS
;;;; files for more information.

(in-package "SB!KERNEL")

;;; a list of lists of restarts
(defvar *restart-clusters* '())

;;; an ALIST (condition . restarts) which records the restarts currently
;;; associated with Condition
(defvar *condition-restarts* ())

(defvar *handler-clusters* nil)

(defstruct (restart (:copier nil) (:predicate nil))
  (name (missing-arg) :type symbol :read-only t)
  (function (missing-arg) :type function)
  (report-function nil :type (or null function))
  (interactive-function nil :type (or null function))
  (test-function (lambda (cond) (declare (ignore cond)) t) :type function))
(def!method print-object ((restart restart) stream)
  (if *print-escape*
      (print-unreadable-object (restart stream :type t :identity t)
	(prin1 (restart-name restart) stream))
      (restart-report restart stream)))

(defun compute-restarts (&optional condition)
  #!+sb-doc
  "Return a list of all the currently active restarts ordered from most
   recently established to less recently established. If CONDITION is
   specified, then only restarts associated with CONDITION (or with no
   condition) will be returned."
  (let ((associated ())
	(other ()))
    (dolist (alist *condition-restarts*)
      (if (eq (car alist) condition)
	  (setq associated (cdr alist))
	  (setq other (append (cdr alist) other))))
    (collect ((res))
      (dolist (restart-cluster *restart-clusters*)
	(dolist (restart restart-cluster)
	  (when (and (or (not condition)
			 (member restart associated)
			 (not (member restart other)))
		     (funcall (restart-test-function restart)
                              condition))
	    (res restart))))
      (res))))

#!+sb-doc
(setf (fdocumentation 'restart-name 'function)
      "Return the name of the given restart object.")

(defun restart-report (restart stream)
  (funcall (or (restart-report-function restart)
	       (let ((name (restart-name restart)))
		 (lambda (stream)
		   (if name (format stream "~S" name)
		       (format stream "~S" restart)))))
	   stream))

(defun find-restart (name &optional condition)
  #!+sb-doc
  "Return the first restart named NAME. If NAME names a restart, the restart
   is returned if it is currently active. If no such restart is found, NIL is
   returned. It is an error to supply NIL as a name. If CONDITION is specified
   and not NIL, then only restarts associated with that condition (or with no
   condition) will be returned."
  (let ((restarts (compute-restarts condition)))
    (declare (type list restarts))
    (find-if (lambda (x)
               (or (eq x name)
                   (eq (restart-name x) name)))
             restarts)))

;;; helper for the various functions which are ANSI-spec'ed to do
;;; something with a restart or signal CONTROL-ERROR if there is none
(defun find-restart-or-control-error (identifier &optional condition)
  (or (find-restart identifier condition)
      (error 'simple-control-error
	     :format-control "No restart ~S is active~@[ for ~S~]."
	     :format-arguments (list identifier condition))))

(defun invoke-restart (restart &rest values)
  #!+sb-doc
  "Calls the function associated with the given restart, passing any given
   arguments. If the argument restart is not a restart or a currently active
   non-nil restart name, then a CONTROL-ERROR is signalled."
  (/show "entering INVOKE-RESTART" restart)
  (let ((real-restart (find-restart-or-control-error restart)))
    (apply (restart-function real-restart) values)))

(defun interactive-restart-arguments (real-restart)
  (let ((interactive-function (restart-interactive-function real-restart)))
    (if interactive-function
	(funcall interactive-function)
	'())))

(defun invoke-restart-interactively (restart)
  #!+sb-doc
  "Calls the function associated with the given restart, prompting for any
   necessary arguments. If the argument restart is not a restart or a
   currently active non-NIL restart name, then a CONTROL-ERROR is signalled."
  (let* ((real-restart (find-restart-or-control-error restart))
	 (args (interactive-restart-arguments real-restart)))
    (apply (restart-function real-restart) args)))

(defun assert-error (assertion places datum &rest arguments)
  (let ((cond (if datum
		(coerce-to-condition datum
						    arguments
						    'simple-error
						    'error)
		(make-condition 'simple-error
				:format-control "The assertion ~S failed."
				:format-arguments (list assertion)))))
    (restart-case
	(error cond)
      (continue ()
		:report (lambda (stream)
			  (format stream "Retry assertion")
			  (if places
			      (format stream
				      " with new value~P for ~{~S~^, ~}."
				      (length places)
				      places)
			      (format stream ".")))
		nil))))

;;; READ-EVALUATED-FORM is used as the interactive method for restart cases
;;; setup by the Common Lisp "casing" (e.g., CCASE and CTYPECASE) macros
;;; and by CHECK-TYPE.
(defun read-evaluated-form ()
  (format *query-io* "~&Type a form to be evaluated:~%")
  (list (eval (read *query-io*))))

(defun check-type-error (place place-value type type-string)
  (let ((condition
	 (make-condition
	  'simple-type-error
	  :datum place-value
	  :expected-type type
	  :format-control
	  "The value of ~S is ~S, which is not ~:[of type ~S~;~:*~A~]."
	  :format-arguments (list place place-value type-string type))))
    (restart-case (error condition)
      (store-value (value)
	:report (lambda (stream)
		  (format stream "Supply a new value for ~S." place))
	:interactive read-evaluated-form
	value))))

(defun case-body-error (name keyform keyform-value expected-type keys)
  (restart-case
      (error 'case-failure
	     :name name
	     :datum keyform-value
	     :expected-type expected-type
	     :possibilities keys)
    (store-value (value)
      :report (lambda (stream)
		(format stream "Supply a new value for ~S." keyform))
      :interactive read-evaluated-form
      value)))
