;;;; stuff originally from CMU CL's error.lisp which can or should
;;;; come late (mostly related to the CONDITION class itself)
;;;;

;;;; This software is part of the SBCL system. See the README file for
;;;; more information.
;;;;
;;;; This software is derived from the CMU CL system, which was
;;;; written at Carnegie Mellon University and released into the
;;;; public domain. The software is in the public domain and is
;;;; provided with absolutely no warranty. See the COPYING and CREDITS
;;;; files for more information.

(in-package "SB!KERNEL")

;;;; the CONDITION class

(/show0 "condition.lisp 20")

(eval-when (:compile-toplevel :load-toplevel :execute)

(/show0 "condition.lisp 24")

(def!struct (condition-classoid (:include slot-classoid)
				(:constructor make-condition-classoid))
  ;; list of CONDITION-SLOT structures for the direct slots of this
  ;; class
  (slots nil :type list)
  ;; list of CONDITION-SLOT structures for all of the effective class
  ;; slots of this class
  (class-slots nil :type list)
  ;; report function or NIL
  (report nil :type (or function null))
  ;; list of alternating initargs and initforms
  (default-initargs () :type list)
  ;; class precedence list as a list of CLASS objects, with all
  ;; non-CONDITION classes removed
  (cpl () :type list)
  ;; a list of all the effective instance allocation slots of this
  ;; class that have a non-constant initform or default-initarg.
  ;; Values for these slots must be computed in the dynamic
  ;; environment of MAKE-CONDITION.
  (hairy-slots nil :type list))

(/show0 "condition.lisp 49")

) ; EVAL-WHEN

(!defstruct-with-alternate-metaclass condition
  :slot-names (actual-initargs assigned-slots)
  :boa-constructor %make-condition-object
  :superclass-name instance
  :metaclass-name condition-classoid
  :metaclass-constructor make-condition-classoid
  :dd-type structure)

(defun make-condition-object (actual-initargs)
  (%make-condition-object actual-initargs nil))

(defstruct (condition-slot (:copier nil))
  (name (missing-arg) :type symbol)
  ;; list of all applicable initargs
  (initargs (missing-arg) :type list)
  ;; names of reader and writer functions
  (readers (missing-arg) :type list)
  (writers (missing-arg) :type list)
  ;; true if :INITFORM was specified
  (initform-p (missing-arg) :type (member t nil))
  ;; If this is a function, call it with no args. Otherwise, it's the
  ;; actual value.
  (initform (missing-arg) :type t)
  ;; allocation of this slot, or NIL until defaulted
  (allocation nil :type (member :instance :class nil))
  ;; If ALLOCATION is :CLASS, this is a cons whose car holds the value.
  (cell nil :type (or cons null))
  ;; slot documentation
  (documentation nil :type (or string null)))

;;; KLUDGE: It's not clear to me why CONDITION-CLASS has itself listed
;;; in its CPL, while other classes derived from CONDITION-CLASS don't
;;; have themselves listed in their CPLs. This behavior is inherited
;;; from CMU CL, and didn't seem to be explained there, and I haven't
;;; figured out whether it's right. -- WHN 19990612
(eval-when (:compile-toplevel :load-toplevel :execute)
  (/show0 "condition.lisp 103")
  (let ((condition-class (locally
			   ;; KLUDGE: There's a DEFTRANSFORM
			   ;; FIND-CLASSOID for constant class names
			   ;; which creates fast but
			   ;; non-cold-loadable, non-compact code. In
			   ;; this context, we'd rather have compact,
			   ;; cold-loadable code. -- WHN 19990928
			   (declare (notinline find-classoid))
			   (find-classoid 'condition))))
    (setf (condition-classoid-cpl condition-class)
	  (list condition-class)))
  (/show0 "condition.lisp 103"))

(setf (condition-classoid-report (locally
				   ;; KLUDGE: There's a DEFTRANSFORM
				   ;; FIND-CLASSOID for constant class
				   ;; names which creates fast but
				   ;; non-cold-loadable, non-compact
				   ;; code. In this context, we'd
				   ;; rather have compact,
				   ;; cold-loadable code. -- WHN
				   ;; 19990928
				   (declare (notinline find-classoid))
				   (find-classoid 'condition)))
      (lambda (cond stream)
	(format stream "Condition ~S was signalled." (type-of cond))))

(eval-when (:compile-toplevel :load-toplevel :execute)

(defun find-condition-layout (name parent-types)
  (let* ((cpl (remove-duplicates
	       (reverse
		(reduce #'append
			(mapcar (lambda (x)
				  (condition-classoid-cpl
				   (find-classoid x)))
				parent-types)))))
	 (cond-layout (info :type :compiler-layout 'condition))
	 (olayout (info :type :compiler-layout name))
	 ;; FIXME: Does this do the right thing in case of multiple
	 ;; inheritance? A quick look at DEFINE-CONDITION didn't make
	 ;; it obvious what ANSI intends to be done in the case of
	 ;; multiple inheritance, so it's not actually clear what the
	 ;; right thing is..
	 (new-inherits
	  (order-layout-inherits (concatenate 'simple-vector
					      (layout-inherits cond-layout)
					      (mapcar #'classoid-layout cpl)))))
    (if (and olayout
	     (not (mismatch (layout-inherits olayout) new-inherits)))
	olayout
	(make-layout :classoid (make-undefined-classoid name)
		     :inherits new-inherits
		     :depthoid -1
		     :length (layout-length cond-layout)))))

) ; EVAL-WHEN

;;; FIXME: ANSI's definition of DEFINE-CONDITION says
;;;   Condition reporting is mediated through the PRINT-OBJECT method
;;;   for the condition type in question, with *PRINT-ESCAPE* always
;;;   being nil. Specifying (:REPORT REPORT-NAME) in the definition of
;;;   a condition type C is equivalent to:
;;;     (defmethod print-object ((x c) stream)
;;;       (if *print-escape* (call-next-method) (report-name x stream)))
;;; The current code doesn't seem to quite match that.
(def!method print-object ((x condition) stream)
  (if *print-escape*
      (print-unreadable-object (x stream :type t :identity t))
      ;; KLUDGE: A comment from CMU CL here said
      ;;   7/13/98 BUG? CPL is not sorted and results here depend on order of
      ;;   superclasses in define-condition call!
      (dolist (class (condition-classoid-cpl (classoid-of x))
		     (error "no REPORT? shouldn't happen!"))
	(let ((report (condition-classoid-report class)))
	  (when report
	    (return (funcall report x stream)))))))

;;;; slots of CONDITION objects

(defvar *empty-condition-slot* '(empty))

(defun find-slot-default (class slot)
  (let ((initargs (condition-slot-initargs slot))
	(cpl (condition-classoid-cpl class)))
    (dolist (class cpl)
      (let ((default-initargs (condition-classoid-default-initargs class)))
	(dolist (initarg initargs)
	  (let ((val (getf default-initargs initarg *empty-condition-slot*)))
	    (unless (eq val *empty-condition-slot*)
	      (return-from find-slot-default
			   (if (functionp val)
			       (funcall val)
			       val)))))))

    (if (condition-slot-initform-p slot)
	(let ((initform (condition-slot-initform slot)))
	  (if (functionp initform)
	      (funcall initform)
	      initform))
	(error "unbound condition slot: ~S" (condition-slot-name slot)))))

(defun find-condition-class-slot (condition-class slot-name)
  (dolist (sclass
	   (condition-classoid-cpl condition-class)
	   (error "There is no slot named ~S in ~S."
		  slot-name condition-class))
    (dolist (slot (condition-classoid-slots sclass))
      (when (eq (condition-slot-name slot) slot-name)
	(return-from find-condition-class-slot slot)))))

(defun condition-writer-function (condition new-value name)
  (dolist (cslot (condition-classoid-class-slots
		  (layout-classoid (%instance-layout condition)))
		 (setf (getf (condition-assigned-slots condition) name)
		       new-value))
    (when (eq (condition-slot-name cslot) name)
      (return (setf (car (condition-slot-cell cslot)) new-value)))))

(defun condition-reader-function (condition name)
  (let ((class (layout-classoid (%instance-layout condition))))
    (dolist (cslot (condition-classoid-class-slots class))
      (when (eq (condition-slot-name cslot) name)
	(return-from condition-reader-function
		     (car (condition-slot-cell cslot)))))
    (let ((val (getf (condition-assigned-slots condition) name
		     *empty-condition-slot*)))
      (if (eq val *empty-condition-slot*)
	  (let ((actual-initargs (condition-actual-initargs condition))
		(slot (find-condition-class-slot class name)))
            (unless slot
	      (error "missing slot ~S of ~S" name condition))
	    (do ((initargs actual-initargs (cddr initargs)))
		((endp initargs)
		 (setf (getf (condition-assigned-slots condition) name)
		       (find-slot-default class slot)))
	      (when (member (car initargs) (condition-slot-initargs slot))
		(return-from condition-reader-function
		  (setf (getf (condition-assigned-slots condition)
			      name)
			(cadr initargs))))))
	  val))))

;;;; MAKE-CONDITION

(defun make-condition (thing &rest args)
  #!+sb-doc
  "Make an instance of a condition object using the specified initargs."
  ;; Note: ANSI specifies no exceptional situations in this function.
  ;; signalling simple-type-error would not be wrong.
  (let* ((thing (or (and (symbolp thing) (find-classoid thing nil))
		    thing))
	 (class (typecase thing
		  (condition-classoid thing)
		  (classoid
		   (error 'simple-type-error
			  :datum thing
			  :expected-type 'condition-class
			  :format-control "~S is not a condition class."
			  :format-arguments (list thing)))
		  (t
		   (error 'simple-type-error
			  :datum thing
			  :expected-type 'condition-class
			  :format-control "bad thing for class argument:~%  ~S"
			  :format-arguments (list thing)))))
	 (res (make-condition-object args)))
    (setf (%instance-layout res) (classoid-layout class))
    ;; Set any class slots with initargs present in this call.
    (dolist (cslot (condition-classoid-class-slots class))
      (dolist (initarg (condition-slot-initargs cslot))
	(let ((val (getf args initarg *empty-condition-slot*)))
	  (unless (eq val *empty-condition-slot*)
	    (setf (car (condition-slot-cell cslot)) val)))))
    ;; Default any slots with non-constant defaults now.
    (dolist (hslot (condition-classoid-hairy-slots class))
      (when (dolist (initarg (condition-slot-initargs hslot) t)
	      (unless (eq (getf args initarg *empty-condition-slot*)
			  *empty-condition-slot*)
		(return nil)))
	(setf (getf (condition-assigned-slots res) (condition-slot-name hslot))
	      (find-slot-default class hslot))))
    res))

;;;; DEFINE-CONDITION

(eval-when (:compile-toplevel :load-toplevel :execute)
(defun %compiler-define-condition (name direct-supers layout
				   all-readers all-writers)
  (with-single-package-locked-error 
      (:symbol name "defining ~A as a condition")
    (sb!xc:proclaim `(ftype (function (t) t) ,@all-readers))
    (sb!xc:proclaim `(ftype (function (t t) t) ,@all-writers))
    (multiple-value-bind (class old-layout)
	(insured-find-classoid name
			       #'condition-classoid-p
			       #'make-condition-classoid)
      (setf (layout-classoid layout) class)
      (setf (classoid-direct-superclasses class)
	    (mapcar #'find-classoid direct-supers))
      (cond ((not old-layout)
	     (register-layout layout))
	    ((not *type-system-initialized*)
	     (setf (layout-classoid old-layout) class)
	     (setq layout old-layout)
	     (unless (eq (classoid-layout class) layout)
	       (register-layout layout)))
	    ((redefine-layout-warning "current"
				      old-layout
				      "new"
				      (layout-length layout)
				      (layout-inherits layout)
				      (layout-depthoid layout))
	     (register-layout layout :invalidate t))
	    ((not (classoid-layout class))
	     (register-layout layout)))
      
      (setf (layout-info layout)
	    (locally
		;; KLUDGE: There's a FIND-CLASS DEFTRANSFORM for constant class
		;; names which creates fast but non-cold-loadable, non-compact
		;; code. In this context, we'd rather have compact, cold-loadable
		;; code. -- WHN 19990928
		(declare (notinline find-classoid))
	      (layout-info (classoid-layout (find-classoid 'condition)))))
      
      (setf (find-classoid name) class)
      
      ;; Initialize CPL slot.
      (setf (condition-classoid-cpl class)
	    (remove-if-not #'condition-classoid-p 
			   (std-compute-class-precedence-list class)))))
  (values))
) ; EVAL-WHEN

;;; Compute the effective slots of CLASS, copying inherited slots and
;;; destructively modifying direct slots.
;;;
;;; FIXME: It'd be nice to explain why it's OK to destructively modify
;;; direct slots. Presumably it follows from the semantics of
;;; inheritance and redefinition of conditions, but finding the cite
;;; and documenting it here would be good. (Or, if this is not in fact
;;; ANSI-compliant, fixing it would also be good.:-)
(defun compute-effective-slots (class)
  (collect ((res (copy-list (condition-classoid-slots class))))
    (dolist (sclass (cdr (condition-classoid-cpl class)))
      (dolist (sslot (condition-classoid-slots sclass))
	(let ((found (find (condition-slot-name sslot) (res)
                           :key #'condition-slot-name)))
	  (cond (found
		 (setf (condition-slot-initargs found)
		       (union (condition-slot-initargs found)
			      (condition-slot-initargs sslot)))
		 (unless (condition-slot-initform-p found)
		   (setf (condition-slot-initform-p found)
			 (condition-slot-initform-p sslot))
		   (setf (condition-slot-initform found)
			 (condition-slot-initform sslot)))
		 (unless (condition-slot-allocation found)
		   (setf (condition-slot-allocation found)
			 (condition-slot-allocation sslot))))
		(t
		 (res (copy-structure sslot)))))))
    (res)))

;;; Early definitions of slot accessor creators.
;;;
;;; Slot accessors must be generic functions, but ANSI does not seem
;;; to specify any of them, and we cannot support it before end of
;;; warm init. So we use ordinary functions inside SBCL, and switch to
;;; GFs only at the end of building.
(declaim (notinline install-condition-slot-reader
                    install-condition-slot-writer))
(defun install-condition-slot-reader (name condition slot-name)
  (declare (ignore condition))
  (setf (fdefinition name)
        (lambda (condition)
          (condition-reader-function condition slot-name))))
(defun install-condition-slot-writer (name condition slot-name)
  (declare (ignore condition))
  (setf (fdefinition name)
        (lambda (new-value condition)
          (condition-writer-function condition new-value slot-name))))

(defun %define-condition (name parent-types layout slots documentation
			  report default-initargs all-readers all-writers)
  (with-single-package-locked-error 
      (:symbol name "defining ~A as a condition")
    (%compiler-define-condition name parent-types layout all-readers all-writers)
    (let ((class (find-classoid name)))
      (setf (condition-classoid-slots class) slots)
      (setf (condition-classoid-report class) report)
      (setf (condition-classoid-default-initargs class) default-initargs)
      (setf (fdocumentation name 'type) documentation)
      
      (dolist (slot slots)
	
	;; Set up reader and writer functions.
	(let ((slot-name (condition-slot-name slot)))
	  (dolist (reader (condition-slot-readers slot))
	    (install-condition-slot-reader reader name slot-name))
	  (dolist (writer (condition-slot-writers slot))
	    (install-condition-slot-writer writer name slot-name))))
      
      ;; Compute effective slots and set up the class and hairy slots
      ;; (subsets of the effective slots.)
      (let ((eslots (compute-effective-slots class))
	    (e-def-initargs
	     (reduce #'append
		     (mapcar #'condition-classoid-default-initargs
			   (condition-classoid-cpl class)))))
	(dolist (slot eslots)
	  (ecase (condition-slot-allocation slot)
	    (:class
	     (unless (condition-slot-cell slot)
	       (setf (condition-slot-cell slot)
		     (list (if (condition-slot-initform-p slot)
			       (let ((initform (condition-slot-initform slot)))
				 (if (functionp initform)
				     (funcall initform)
				     initform))
			       *empty-condition-slot*))))
	     (push slot (condition-classoid-class-slots class)))
	    ((:instance nil)
	     (setf (condition-slot-allocation slot) :instance)
	     (when (or (functionp (condition-slot-initform slot))
		       (dolist (initarg (condition-slot-initargs slot) nil)
			 (when (functionp (getf e-def-initargs initarg))
			   (return t))))
	       (push slot (condition-classoid-hairy-slots class))))))))
    name))

(defmacro define-condition (name (&rest parent-types) (&rest slot-specs)
				 &body options)
  #!+sb-doc
  "DEFINE-CONDITION Name (Parent-Type*) (Slot-Spec*) Option*
   Define NAME as a condition type. This new type inherits slots and its
   report function from the specified PARENT-TYPEs. A slot spec is a list of:
     (slot-name :reader <rname> :initarg <iname> {Option Value}*

   The DEFINE-CLASS slot options :ALLOCATION, :INITFORM, [slot] :DOCUMENTATION
   and :TYPE and the overall options :DEFAULT-INITARGS and
   [type] :DOCUMENTATION are also allowed.

   The :REPORT option is peculiar to DEFINE-CONDITION. Its argument is either
   a string or a two-argument lambda or function name. If a function, the
   function is called with the condition and stream to report the condition.
   If a string, the string is printed.

   Condition types are classes, but (as allowed by ANSI and not as described in
   CLtL2) are neither STANDARD-OBJECTs nor STRUCTURE-OBJECTs. WITH-SLOTS and
   SLOT-VALUE may not be used on condition objects."
  (let* ((parent-types (or parent-types '(condition)))
	 (layout (find-condition-layout name parent-types))
	 (documentation nil)
	 (report nil)
	 (default-initargs ()))
    (collect ((slots)
	      (all-readers nil append)
	      (all-writers nil append))
      (dolist (spec slot-specs)
	(when (keywordp spec)
	  (warn "Keyword slot name indicates probable syntax error:~%  ~S"
		spec))
	(let* ((spec (if (consp spec) spec (list spec)))
	       (slot-name (first spec))
	       (allocation :instance)
	       (initform-p nil)
	       documentation
	       initform)
	  (collect ((initargs)
		    (readers)
		    (writers))
	    (do ((options (rest spec) (cddr options)))
		((null options))
	      (unless (and (consp options) (consp (cdr options)))
		(error "malformed condition slot spec:~%  ~S." spec))
	      (let ((arg (second options)))
		(case (first options)
		  (:reader (readers arg))
		  (:writer (writers arg))
		  (:accessor
		   (readers arg)
		   (writers `(setf ,arg)))
		  (:initform
		   (when initform-p
		     (error "more than one :INITFORM in ~S" spec))
		   (setq initform-p t)
		   (setq initform arg))
		  (:initarg (initargs arg))
		  (:allocation
		   (setq allocation arg))
		  (:documentation
		   (when documentation
		     (error "more than one :DOCUMENTATION in ~S" spec))
		   (unless (stringp arg)
		     (error "slot :DOCUMENTATION argument is not a string: ~S"
			    arg))
		   (setq documentation arg))
		  (:type)
		  (t
		   (error "unknown slot option:~%  ~S" (first options))))))

	    (all-readers (readers))
	    (all-writers (writers))
	    (slots `(make-condition-slot
		     :name ',slot-name
		     :initargs ',(initargs)
		     :readers ',(readers)
		     :writers ',(writers)
		     :initform-p ',initform-p
		     :documentation ',documentation
		     :initform
		     ,(if (constantp initform)
			  `',(eval initform)
			  `#'(lambda () ,initform)))))))

      (dolist (option options)
	(unless (consp option)
	  (error "bad option:~%  ~S" option))
	(case (first option)
	  (:documentation (setq documentation (second option)))
	  (:report
	   (let ((arg (second option)))
	     (setq report
		   (if (stringp arg)
		       `#'(lambda (condition stream)
			  (declare (ignore condition))
			  (write-string ,arg stream))
		       `#'(lambda (condition stream)
			  (funcall #',arg condition stream))))))
	  (:default-initargs
	   (do ((initargs (rest option) (cddr initargs)))
	       ((endp initargs))
	     (let ((val (second initargs)))
	       (setq default-initargs
		     (list* `',(first initargs)
			    (if (constantp val)
				`',(eval val)
				`#'(lambda () ,val))
			    default-initargs)))))
	  (t
	   (error "unknown option: ~S" (first option)))))

      `(progn
	 (eval-when (:compile-toplevel)
	   (%compiler-define-condition ',name ',parent-types ',layout
				       ',(all-readers) ',(all-writers)))
	 (eval-when (:load-toplevel :execute)
	   (%define-condition ',name
			      ',parent-types
			      ',layout
			      (list ,@(slots))
			      ,documentation
			      ,report
			      (list ,@default-initargs)
			      ',(all-readers)
			      ',(all-writers)))))))

;;;; DESCRIBE on CONDITIONs

;;; a function to be used as the guts of DESCRIBE-OBJECT (CONDITION T)
;;; eventually (once we get CLOS up and running so that we can define
;;; methods)
(defun describe-condition (condition stream)
  (format stream
	  "~&~@<~S ~_is a ~S. ~_Its slot values are ~_~S.~:>~%"
	  condition
	  (type-of condition)
	  (concatenate 'list
		       (condition-actual-initargs condition)
		       (condition-assigned-slots condition))))

;;;; various CONDITIONs specified by ANSI

(define-condition serious-condition (condition) ())

(define-condition error (serious-condition) ())

(define-condition warning (condition) ())
(define-condition style-warning (warning) ())

(defun simple-condition-printer (condition stream)
  (apply #'format
	 stream
	 (simple-condition-format-control condition)
	 (simple-condition-format-arguments condition)))

(define-condition simple-condition ()
  ((format-control :reader simple-condition-format-control
		   :initarg :format-control
                   :type format-control)
   (format-arguments :reader simple-condition-format-arguments
		     :initarg :format-arguments
		     :initform '()
                     :type list))
  (:report simple-condition-printer))

(define-condition simple-warning (simple-condition warning) ())

(define-condition simple-error (simple-condition error) ())

;;; not specified by ANSI, but too useful not to have around.
(define-condition simple-style-warning (simple-condition style-warning) ())

(define-condition storage-condition (serious-condition) ())

(define-condition type-error (error)
  ((datum :reader type-error-datum :initarg :datum)
   (expected-type :reader type-error-expected-type :initarg :expected-type))
  (:report
   (lambda (condition stream)
     (format stream
	     "~@<The value ~2I~:_~S ~I~_is not of type ~2I~_~S.~:>"
	     (type-error-datum condition)
	     (type-error-expected-type condition)))))

(define-condition simple-type-error (simple-condition type-error) ())

(define-condition program-error (error) ())
(define-condition parse-error   (error) ())
(define-condition control-error (error) ())
(define-condition stream-error  (error)
  ((stream :reader stream-error-stream :initarg :stream)))

(define-condition end-of-file (stream-error) ()
  (:report
   (lambda (condition stream)
     (format stream
	     "end of file on ~S"
	     (stream-error-stream condition)))))

(define-condition file-error (error)
  ((pathname :reader file-error-pathname :initarg :pathname))
  (:report
   (lambda (condition stream)
     (format stream "error on file ~S" (file-error-pathname condition)))))

(define-condition package-error (error)
  ((package :reader package-error-package :initarg :package)))

(define-condition cell-error (error)
  ((name :reader cell-error-name :initarg :name)))

(define-condition unbound-variable (cell-error) ()
  (:report
   (lambda (condition stream)
     (format stream
	     "The variable ~S is unbound."
	     (cell-error-name condition)))))

(define-condition undefined-function (cell-error) ()
  (:report
   (lambda (condition stream)
     (format stream
	     "The function ~S is undefined."
	     (cell-error-name condition)))))

(define-condition special-form-function (undefined-function) ()
  (:report
   (lambda (condition stream)
     (format stream
	     "Cannot FUNCALL the SYMBOL-FUNCTION of special operator ~S."
	     (cell-error-name condition)))))

(define-condition arithmetic-error (error)
  ((operation :reader arithmetic-error-operation
	      :initarg :operation
	      :initform nil)
   (operands :reader arithmetic-error-operands
	     :initarg :operands))
  (:report (lambda (condition stream)
	     (format stream
		     "arithmetic error ~S signalled"
		     (type-of condition))
	     (when (arithmetic-error-operation condition)
	       (format stream
		       "~%Operation was ~S, operands ~S."
		       (arithmetic-error-operation condition)
		       (arithmetic-error-operands condition))))))

(define-condition division-by-zero         (arithmetic-error) ())
(define-condition floating-point-overflow  (arithmetic-error) ())
(define-condition floating-point-underflow (arithmetic-error) ())
(define-condition floating-point-inexact   (arithmetic-error) ())
(define-condition floating-point-invalid-operation (arithmetic-error) ())

(define-condition print-not-readable (error)
  ((object :reader print-not-readable-object :initarg :object))
  (:report
   (lambda (condition stream)
     (let ((obj (print-not-readable-object condition))
	   (*print-array* nil))
       (format stream "~S cannot be printed readably." obj)))))

(define-condition reader-error (parse-error stream-error)
  ((format-control
    :reader reader-error-format-control
    :initarg :format-control)
   (format-arguments
    :reader reader-error-format-arguments
    :initarg :format-arguments
    :initform '()))
  (:report
   (lambda (condition stream)
     (let* ((error-stream (stream-error-stream condition))
	    (pos (file-position error-stream)))
       (let (lineno colno)
	 (when (and pos
		    (< pos sb!xc:array-dimension-limit)
		    ;; KLUDGE: lseek() (which is what FILE-POSITION
		    ;; reduces to on file-streams) is undefined on
		    ;; "some devices", which in practice means that it
		    ;; can claim to succeed on /dev/stdin on Darwin
		    ;; and Solaris.  This is obviously bad news,
		    ;; because the READ-SEQUENCE below will then
		    ;; block, not complete, and the report will never
		    ;; be printed.  As a workaround, we exclude
		    ;; interactive streams from this attempt to report
		    ;; positions.  -- CSR, 2003-08-21
		    (not (interactive-stream-p error-stream))
		    (file-position error-stream :start))
	   (let ((string
		  (make-string pos
			       :element-type (stream-element-type error-stream))))
	     (when (= pos (read-sequence string error-stream))
	       (setq lineno (1+ (count #\Newline string))
		     colno (- pos
			      (or (position #\Newline string :from-end t) -1)
			      1))))
	   (file-position error-stream pos))
	 (format stream
		 "READER-ERROR ~@[at ~W ~]~
                  ~@[(line ~W~]~@[, column ~W) ~]~
                  on ~S:~%~?"
		 pos lineno colno error-stream
		 (reader-error-format-control condition)
		 (reader-error-format-arguments condition)))))))

;;;; special SBCL extension conditions

;;; an error apparently caused by a bug in SBCL itself
;;;
;;; Note that we don't make any serious effort to use this condition
;;; for *all* errors in SBCL itself. E.g. type errors and array
;;; indexing errors can occur in functions called from SBCL code, and
;;; will just end up as ordinary TYPE-ERROR or invalid index error,
;;; because the signalling code has no good way to know that the
;;; underlying problem is a bug in SBCL. But in the fairly common case
;;; that the signalling code does know that it's found a bug in SBCL,
;;; this condition is appropriate, reusing boilerplate and helping
;;; users to recognize it as an SBCL bug.
(define-condition bug (simple-error)
  ()
  (:report
   (lambda (condition stream)
     (format stream
	     "~@<  ~? ~:@_~?~:>"
	     (simple-condition-format-control condition)
	     (simple-condition-format-arguments condition)
	     "~@<This is probably a bug in SBCL itself. (Alternatively, ~
              SBCL might have been corrupted by bad user code, e.g. by an ~
              undefined Lisp operation like ~S, or by stray pointers from ~
              alien code or from unsafe Lisp code; or there might be a bug ~
              in the OS or hardware that SBCL is running on.) If it seems to ~
              be a bug in SBCL itself, the maintainers would like to know ~
              about it. Bug reports are welcome on the SBCL ~
              mailing lists, which you can find at ~
              <http://sbcl.sourceforge.net/>.~:@>"
	     '((fmakunbound 'compile))))))

;;; a condition for use in stubs for operations which aren't supported
;;; on some platforms
;;;
;;; E.g. in sbcl-0.7.0.5, it might be appropriate to do something like
;;;   #-(or freebsd linux)
;;;   (defun load-foreign (&rest rest)
;;;     (error 'unsupported-operator :name 'load-foreign))
;;;   #+(or freebsd linux)
;;;   (defun load-foreign ... actual definition ...)
;;; By signalling a standard condition in this case, we make it
;;; possible for test code to distinguish between (1) intentionally
;;; unimplemented and (2) unintentionally just screwed up somehow.
;;; (Before this condition was defined, test code tried to deal with 
;;; this by checking for FBOUNDP, but that didn't work reliably. In
;;; sbcl-0.7.0, a a package screwup left the definition of
;;; LOAD-FOREIGN in the wrong package, so it was unFBOUNDP even on
;;; architectures where it was supposed to be supported, and the
;;; regression tests cheerfully passed because they assumed that
;;; unFBOUNDPness meant they were running on an system which didn't
;;; support the extension.)
(define-condition unsupported-operator (simple-error) ())


;;; (:ansi-cl :function remove)
;;; (:ansi-cl :section (a b c))
;;; (:ansi-cl :glossary "similar")
;;;
;;; (:sbcl :node "...")
;;; (:sbcl :variable *ed-functions*)
;;;
;;; FIXME: this is not the right place for this.
(defun print-reference (reference stream)
  (ecase (car reference)
    (:amop
     (format stream "AMOP")
     (format stream ", ")
     (destructuring-bind (type data) (cdr reference)
       (ecase type
	 (:generic-function (format stream "Generic Function ~S" data))
	 (:section (format stream "Section ~{~D~^.~}" data)))))
    (:ansi-cl
     (format stream "The ANSI Standard")
     (format stream ", ")
     (destructuring-bind (type data) (cdr reference)
       (ecase type
	 (:function (format stream "Function ~S" data))
	 (:special-operator (format stream "Special Operator ~S" data))
	 (:macro (format stream "Macro ~S" data))
	 (:section (format stream "Section ~{~D~^.~}" data))
	 (:glossary (format stream "Glossary entry for ~S" data))
	 (:issue (format stream "writeup for Issue ~A" data)))))
    (:sbcl
     (format stream "The SBCL Manual")
     (format stream ", ")
     (destructuring-bind (type data) (cdr reference)
       (ecase type
	 (:node (format stream "Node ~S" data))
	 (:variable (format stream "Variable ~S" data))
	 (:function (format stream "Function ~S" data)))))
    ;; FIXME: other documents (e.g. CLIM, Franz documentation :-)
    ))
(define-condition reference-condition ()
  ((references :initarg :references :reader reference-condition-references)))
(defvar *print-condition-references* t)
(def!method print-object :around ((o reference-condition) s)
  (call-next-method)
  (unless (or *print-escape* *print-readably*)
    (when (and *print-condition-references*
               (reference-condition-references o))
      (format s "~&See also:~%")
      (pprint-logical-block (s nil :per-line-prefix "  ")
	(do* ((rs (reference-condition-references o) (cdr rs))
	      (r (car rs) (car rs)))
	     ((null rs))
	  (print-reference r s)
	  (unless (null (cdr rs))
	    (terpri s)))))))

(define-condition duplicate-definition (reference-condition warning)
  ((name :initarg :name :reader duplicate-definition-name))
  (:report (lambda (c s)
	     (format s "~@<Duplicate definition for ~S found in ~
                        one file.~@:>"
		     (duplicate-definition-name c))))
  (:default-initargs :references (list '(:ansi-cl :section (3 2 2 3)))))

(define-condition package-at-variance (reference-condition simple-warning) 
  ()
  (:default-initargs :references (list '(:ansi-cl :macro defpackage))))

(define-condition defconstant-uneql (reference-condition error)
  ((name :initarg :name :reader defconstant-uneql-name)
   (old-value :initarg :old-value :reader defconstant-uneql-old-value)
   (new-value :initarg :new-value :reader defconstant-uneql-new-value))
  (:report
   (lambda (condition stream)
     (format stream
	     "~@<The constant ~S is being redefined (from ~S to ~S)~@:>"
	     (defconstant-uneql-name condition)
	     (defconstant-uneql-old-value condition)
	     (defconstant-uneql-new-value condition))))
  (:default-initargs :references (list '(:ansi-cl :macro defconstant)
				       '(:sbcl :node "Idiosyncrasies"))))

(define-condition array-initial-element-mismatch 
    (reference-condition simple-warning)
  ()
  (:default-initargs 
      :references (list 
		   '(:ansi-cl :function make-array) 
		   '(:ansi-cl :function sb!xc:upgraded-array-element-type))))

(define-condition displaced-to-array-too-small-error
    (reference-condition simple-error)
  ()
  (:default-initargs
      :references (list '(:ansi-cl :function adjust-array))))

(define-condition type-warning (reference-condition simple-warning)
  ()
  (:default-initargs :references (list '(:sbcl :node "Handling of Types"))))

(define-condition local-argument-mismatch (reference-condition simple-warning)
  ()
  (:default-initargs :references (list '(:ansi-cl :section (3 2 2 3)))))

(define-condition format-args-mismatch (reference-condition)
  ()
  (:default-initargs :references (list '(:ansi-cl :section (22 3 10 2)))))

(define-condition format-too-few-args-warning 
    (format-args-mismatch simple-warning)
  ())
(define-condition format-too-many-args-warning
    (format-args-mismatch simple-style-warning)
  ())

(define-condition extension-failure (reference-condition simple-error)
  ())

#!+sb-package-locks
(progn

(define-condition package-lock-violation (reference-condition package-error)
  ((format-control :initform nil :initarg :format-control 
		   :reader package-error-format-control)
   (format-arguments :initform nil :initarg :format-arguments
		     :reader package-error-format-arguments))
  (:report 
   (lambda (condition stream)
     (let ((control (package-error-format-control condition)))
       (if control
	   (apply #'format stream
                  (format nil "~~@<Lock on package ~A violated when ~A.~~:@>"
                          (package-name (package-error-package condition))
                          control)
                  (package-error-format-arguments condition))
	   (format stream "~@<Lock on package ~A violated.~:@>"
		   (package-name (package-error-package condition)))))))
  ;; no :default-initargs -- reference-stuff provided by the
  ;; signalling form in target-package.lisp
  #!+sb-doc
  (:documentation
   "Subtype of CL:PACKAGE-ERROR. A subtype of this error is signalled
when a package-lock is violated."))

(define-condition package-locked-error (package-lock-violation) ()
  #!+sb-doc
  (:documentation
   "Subtype of SB-EXT:PACKAGE-LOCK-VIOLATION. An error of this type is
signalled when an operation on a package violates a package lock."))

(define-condition symbol-package-locked-error (package-lock-violation)
  ((symbol :initarg :symbol :reader package-locked-error-symbol))
  #!+sb-doc
  (:documentation
   "Subtype of SB-EXT:PACKAGE-LOCK-VIOLATION. An error of this type is
signalled when an operation on a symbol violates a package lock. The
symbol that caused the violation is accessed by the function
SB-EXT:PACKAGE-LOCKED-ERROR-SYMBOL."))

) ; progn

(define-condition undefined-alien-error (error) ()
  (:report
   (lambda (condition stream)
     (declare (ignore condition))
     (format stream "Attempt to access an undefined alien value."))))

;;;; various other (not specified by ANSI) CONDITIONs
;;;;
;;;; These might logically belong in other files; they're here, after
;;;; setup of CONDITION machinery, only because that makes it easier to
;;;; get cold init to work.

;;; OAOOM warning: see cross-condition.lisp
(define-condition encapsulated-condition (condition)
  ((condition :initarg :condition :reader encapsulated-condition)))

(define-condition values-type-error (type-error)
  ()
  (:report
   (lambda (condition stream)
     (format stream
	     "~@<The values set ~2I~:_[~{~S~^ ~}] ~I~_is not of type ~2I~_~S.~:>"
	     (type-error-datum condition)
	     (type-error-expected-type condition)))))

;;; KLUDGE: a condition for floating point errors when we can't or
;;; won't figure out what type they are. (In FreeBSD and OpenBSD we
;;; don't know how, at least as of sbcl-0.6.7; in Linux we probably
;;; know how but the old code was broken by the conversion to POSIX
;;; signal handling and hasn't been fixed as of sbcl-0.6.7.)
;;;
;;; FIXME: Perhaps this should also be a base class for all
;;; floating point exceptions?
(define-condition floating-point-exception (arithmetic-error)
  ((flags :initarg :traps
          :initform nil
	  :reader floating-point-exception-traps))
  (:report (lambda (condition stream)
	     (format stream
		     "An arithmetic error ~S was signalled.~%"
		     (type-of condition))
	     (let ((traps (floating-point-exception-traps condition)))
	       (if traps
		   (format stream
			   "Trapping conditions are: ~%~{ ~S~^~}~%"
			   traps)
		   (write-line
		    "No traps are enabled? How can this be?"
		    stream))))))

(define-condition index-too-large-error (type-error)
  ()
  (:report
   (lambda (condition stream)
     (format stream
	     "The index ~S is too large."
	     (type-error-datum condition)))))

(define-condition bounding-indices-bad-error (reference-condition type-error)
  ((object :reader bounding-indices-bad-object :initarg :object))
  (:report
   (lambda (condition stream)
     (let* ((datum (type-error-datum condition))
	    (start (car datum))
	    (end (cdr datum))
	    (object (bounding-indices-bad-object condition)))
       (etypecase object
	 (sequence
	  (format stream
		  "The bounding indices ~S and ~S are bad ~
                   for a sequence of length ~S."
		  start end (length object)))
	 (array
	  ;; from WITH-ARRAY-DATA
	  (format stream
		  "The START and END parameters ~S and ~S are ~
                   bad for an array of total size ~S."
		  start end (array-total-size object)))))))
  (:default-initargs 
      :references 
      (list '(:ansi-cl :glossary "bounding index designator")
	    '(:ansi-cl :issue "SUBSEQ-OUT-OF-BOUNDS:IS-AN-ERROR"))))

(define-condition nil-array-accessed-error (reference-condition type-error)
  ()
  (:report (lambda (condition stream)
	     (declare (ignore condition))
	     (format stream
		     "An attempt to access an array of element-type ~
                      NIL was made.  Congratulations!")))
  (:default-initargs
      :references (list '(:ansi-cl :function sb!xc:upgraded-array-element-type)
			'(:ansi-cl :section (15 1 2 1))
			'(:ansi-cl :section (15 1 2 2)))))

(define-condition io-timeout (stream-error)
  ((direction :reader io-timeout-direction :initarg :direction))
  (:report
   (lambda (condition stream)
     (declare (type stream stream))
     (format stream
	     "I/O timeout ~(~A~)ing ~S"
	     (io-timeout-direction condition)
	     (stream-error-stream condition)))))

(define-condition namestring-parse-error (parse-error)
  ((complaint :reader namestring-parse-error-complaint :initarg :complaint)
   (args :reader namestring-parse-error-args :initarg :args :initform nil)
   (namestring :reader namestring-parse-error-namestring :initarg :namestring)
   (offset :reader namestring-parse-error-offset :initarg :offset))
  (:report
   (lambda (condition stream)
     (format stream
	     "parse error in namestring: ~?~%  ~A~%  ~V@T^"
	     (namestring-parse-error-complaint condition)
	     (namestring-parse-error-args condition)
	     (namestring-parse-error-namestring condition)
	     (namestring-parse-error-offset condition)))))

(define-condition simple-package-error (simple-condition package-error) ())

(define-condition reader-package-error (reader-error) ())

(define-condition reader-eof-error (end-of-file)
  ((context :reader reader-eof-error-context :initarg :context))
  (:report
   (lambda (condition stream)
     (format stream
	     "unexpected end of file on ~S ~A"
	     (stream-error-stream condition)
	     (reader-eof-error-context condition)))))

(define-condition reader-impossible-number-error (reader-error)
  ((error :reader reader-impossible-number-error-error :initarg :error))
  (:report
   (lambda (condition stream)
     (let ((error-stream (stream-error-stream condition)))
       (format stream "READER-ERROR ~@[at ~W ~]on ~S:~%~?~%Original error: ~A"
	       (file-position error-stream) error-stream
	       (reader-error-format-control condition)
	       (reader-error-format-arguments condition)
	       (reader-impossible-number-error-error condition))))))

(define-condition timeout (serious-condition) ())

;;; Single stepping conditions

(define-condition step-condition ()
  ((form :initarg :form :reader step-condition-form))
  #!+sb-doc
  (:documentation "Common base class of single-stepping conditions.
STEP-CONDITION-FORM holds a string representation of the form being
stepped."))

#!+sb-doc
(setf (fdocumentation 'step-condition-form 'function)
      "Form associated with the STEP-CONDITION.")

(define-condition step-form-condition (step-condition)
  ((source-path :initarg :source-path :reader step-condition-source-path)
   (pathname :initarg :pathname :reader step-condition-pathname))
  #!+sb-doc
  (:documentation "Condition signalled by code compiled with
single-stepping information when about to execute a form.
STEP-CONDITION-FORM holds the form, STEP-CONDITION-PATHNAME holds the
pathname of the original file or NIL, and STEP-CONDITION-SOURCE-PATH
holds the source-path to the original form within that file or NIL.
Associated with this condition are always the restarts STEP-INTO,
STEP-NEXT, and STEP-CONTINUE."))

#!+sb-doc
(setf (fdocumentation 'step-condition-source-path 'function)
      "Source-path of the original form associated with the
STEP-FORM-CONDITION or NIL."
      (fdocumentation 'step-condition-pathname 'function)
      "Pathname of the original source-file associated with the
STEP-FORM-CONDITION or NIL.")

(define-condition step-result-condition (step-condition)
  ((result :initarg :result :reader step-condition-result)))

#!+sb-doc
(setf (fdocumentation 'step-condition-result 'function)
      "Return values associated with STEP-VALUES-CONDITION as a list,
or the variable value associated with STEP-VARIABLE-CONDITION.")

(define-condition step-values-condition (step-result-condition)
  ()
  #!+sb-doc
  (:documentation "Condition signalled by code compiled with
single-stepping information after executing a form.
STEP-CONDITION-FORM holds the form, and STEP-CONDITION-RESULT holds
the values returned by the form as a list. No associated restarts."))

(define-condition step-variable-condition (step-result-condition)
  ()
  #!+sb-doc
  (:documentation "Condition signalled by code compiled with
single-stepping information when referencing a variable.
STEP-CONDITION-FORM hold the symbol, and STEP-CONDITION-RESULT holds
the value of the variable. No associated restarts."))


;;;; restart definitions

(define-condition abort-failure (control-error) ()
  (:report
   "An ABORT restart was found that failed to transfer control dynamically."))

(defun abort (&optional condition)
  #!+sb-doc
  "Transfer control to a restart named ABORT, signalling a CONTROL-ERROR if
   none exists."
  (invoke-restart (find-restart-or-control-error 'abort condition))
  ;; ABORT signals an error in case there was a restart named ABORT
  ;; that did not transfer control dynamically. This could happen with
  ;; RESTART-BIND.
  (error 'abort-failure))

(defun muffle-warning (&optional condition)
  #!+sb-doc
  "Transfer control to a restart named MUFFLE-WARNING, signalling a
   CONTROL-ERROR if none exists."
  (invoke-restart (find-restart-or-control-error 'muffle-warning condition)))

(macrolet ((define-nil-returning-restart (name args doc)
	     #!-sb-doc (declare (ignore doc))
	     `(defun ,name (,@args &optional condition)
		#!+sb-doc ,doc
		;; FIXME: Perhaps this shared logic should be pulled out into
		;; FLET MAYBE-INVOKE-RESTART? See whether it shrinks code..
	        (let ((restart (find-restart ',name condition)))
		  (when restart
		    (invoke-restart restart ,@args))))))
  (define-nil-returning-restart continue ()
    "Transfer control to a restart named CONTINUE, or return NIL if none exists.")
  (define-nil-returning-restart store-value (value)
    "Transfer control and VALUE to a restart named STORE-VALUE, or return NIL if
   none exists.")
  (define-nil-returning-restart use-value (value)
    "Transfer control and VALUE to a restart named USE-VALUE, or return NIL if
   none exists."))

;;; single-stepping restarts

(macrolet ((def (name doc)
	       #!-sb-doc (declare (ignore doc))
	       `(defun ,name (condition)
		 #!+sb-doc ,doc
		 (invoke-restart (find-restart-or-control-error ',name condition)))))
  (def step-continue
      "Transfers control to the STEP-CONTINUE restart associated with
the condition, continuing execution without stepping. Signals a
CONTROL-ERROR if the restart does not exist.")
  (def step-next
      "Transfers control to the STEP-NEXT restart associated with the
condition, executing the current form without stepping and continuing
stepping with the next form. Signals CONTROL-ERROR is the restart does
not exists.")
  (def step-into
      "Transfers control to the STEP-INTO restart associated with the
condition, stepping into the current form. Signals a CONTROL-ERROR is
the restart does not exist."))

(/show0 "condition.lisp end of file")

