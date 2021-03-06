;;;; This file contains load-time support for declaration processing.
;;;; In CMU CL it was split off from the compiler so that the compiler
;;;; doesn't have to be in the cold load, but in SBCL the compiler is
;;;; in the cold load again, so this might not be valuable.

;;;; This software is part of the SBCL system. See the README file for
;;;; more information.
;;;;
;;;; This software is derived from the CMU CL system, which was
;;;; written at Carnegie Mellon University and released into the
;;;; public domain. The software is in the public domain and is
;;;; provided with absolutely no warranty. See the COPYING and CREDITS
;;;; files for more information.

(in-package "SB!C")

;;; A list of UNDEFINED-WARNING structures representing references to unknown
;;; stuff which came up in a compilation unit.
(defvar *undefined-warnings*)
(declaim (list *undefined-warnings*))

;;; Look up some symbols in *FREE-VARS*, returning the var
;;; structures for any which exist. If any of the names aren't
;;; symbols, we complain.
(declaim (ftype (function (list) list) get-old-vars))
(defun get-old-vars (names)
  (collect ((vars))
    (dolist (name names (vars))
      (unless (symbolp name)
	(compiler-error "The name ~S is not a symbol." name))
      (let ((old (gethash name *free-vars*)))
	(when old (vars old))))))

;;; Return a new POLICY containing the policy information represented
;;; by the optimize declaration SPEC. Any parameters not specified are
;;; defaulted from the POLICY argument.
(declaim (ftype (function (list policy) policy) process-optimize-decl))
(defun process-optimize-decl (spec policy)
  (let ((result nil))
    ;; Add new entries from SPEC.
    (dolist (q-and-v-or-just-q (cdr spec))
      (multiple-value-bind (quality raw-value)
	  (if (atom q-and-v-or-just-q)
	      (values q-and-v-or-just-q 3)
	      (destructuring-bind (quality raw-value) q-and-v-or-just-q
		(values quality raw-value)))
	(cond ((not (policy-quality-name-p quality))
	       (compiler-warn "ignoring unknown optimization quality ~
                               ~S in ~S"
			       quality spec))
	      ((not (typep raw-value 'policy-quality))
	       (compiler-warn "ignoring bad optimization value ~S in ~S"
			      raw-value spec))
	      (t
	       ;; we can't do this yet, because CLOS macros expand
	       ;; into code containing INHIBIT-WARNINGS.
	       #+nil
	       (when (eql quality 'sb!ext:inhibit-warnings)
		 (compiler-style-warn "~S is deprecated: use ~S instead"
				      quality 'sb!ext:muffle-conditions))
	       (push (cons quality raw-value)
		     result)))))
    ;; Add any nonredundant entries from old POLICY.
    (dolist (old-entry policy)
      (unless (assq (car old-entry) result)
	(push old-entry result)))
    ;; Voila.
    result))

(declaim (ftype (function (list list) list)
		process-handle-conditions-decl))
(defun process-handle-conditions-decl (spec list)
  (let ((new (copy-alist list)))
    (dolist (clause (cdr spec))
      (destructuring-bind (typespec restart-name) clause
	(let ((ospec (rassoc restart-name new :test #'eq)))
	  (if ospec
	      (setf (car ospec)
		    (type-specifier
		     (type-union (specifier-type (car ospec))
				 (specifier-type typespec))))
	      (push (cons (type-specifier (specifier-type typespec))
			  restart-name)
		    new)))))
    new))
(declaim (ftype (function (list list) list)
		process-muffle-conditions-decl))
(defun process-muffle-conditions-decl (spec list)
  (process-handle-conditions-decl
   (cons 'handle-conditions
	 (mapcar (lambda (x) (list x 'muffle-warning)) (cdr spec)))
   list))

(declaim (ftype (function (list list) list)
		process-unhandle-conditions-decl))
(defun process-unhandle-conditions-decl (spec list)
  (let ((new (copy-alist list)))
    (dolist (clause (cdr spec))
      (destructuring-bind (typespec restart-name) clause
	(let ((ospec (rassoc restart-name new :test #'eq)))
	  (if ospec
	      (let ((type-specifier
		     (type-specifier
		      (type-intersection
		       (specifier-type (car ospec))
		       (specifier-type `(not ,typespec))))))
		(if type-specifier
		    (setf (car ospec) type-specifier)
		    (setq new
			  (delete restart-name new :test #'eq :key #'cdr))))
	      ;; do nothing?
	      nil))))
    new))
(declaim (ftype (function (list list) list)
		process-unmuffle-conditions-decl))
(defun process-unmuffle-conditions-decl (spec list)
  (process-unhandle-conditions-decl
   (cons 'unhandle-conditions
	 (mapcar (lambda (x) (list x 'muffle-warning)) (cdr spec)))
   list))

(declaim (ftype (function (list list) list)
                process-package-lock-decl))
(defun process-package-lock-decl (spec old)
  (let ((decl (car spec))
        (list (cdr spec)))
    (ecase decl
      (disable-package-locks
       (union old list :test #'equal))
      (enable-package-locks
       (set-difference old list :test #'equal)))))

;;; ANSI defines the declaration (FOO X Y) to be equivalent to
;;; (TYPE FOO X Y) when FOO is a type specifier. This function
;;; implements that by converting (FOO X Y) to (TYPE FOO X Y).
(defun canonized-decl-spec (decl-spec)
  (let ((id (first decl-spec)))
    (unless (symbolp id)
      (error "The declaration identifier is not a symbol: ~S" id))
    (let ((id-is-type (info :type :kind id))
	  (id-is-declared-decl (info :declaration :recognized id)))
      (cond ((and id-is-type id-is-declared-decl)
	     (compiler-error
	      "ambiguous declaration ~S:~%  ~
              ~S was declared as a DECLARATION, but is also a type name."
	      decl-spec id))
	    (id-is-type
	     (cons 'type decl-spec))
	    (t
	     decl-spec)))))

(defvar *queued-proclaims*) ; initialized in !COLD-INIT-FORMS

(!begin-collecting-cold-init-forms)
(!cold-init-forms (setf *queued-proclaims* nil))
(!defun-from-collected-cold-init-forms !early-proclaim-cold-init)

(defun sb!xc:proclaim (raw-form)
  #+sb-xc (/show0 "entering PROCLAIM, RAW-FORM=..")
  #+sb-xc (/hexstr raw-form)
  (let* ((form (canonized-decl-spec raw-form))
	 (kind (first form))
	 (args (rest form)))
    (case kind
      (special
       (dolist (name args)
	 (unless (symbolp name)
	   (error "can't declare a non-symbol as SPECIAL: ~S" name))
	 (when (constantp name)
	   (error "can't declare a constant as SPECIAL: ~S" name))
	 (with-single-package-locked-error
             (:symbol name "globally declaring ~A special"))
	 (clear-info :variable :constant-value name)
	 (setf (info :variable :kind name) :special)))
      (type
       (if *type-system-initialized*
	   (let ((type (specifier-type (first args))))
	     (dolist (name (rest args))
	       (unless (symbolp name)
		 (error "can't declare TYPE of a non-symbol: ~S" name))
	       (with-single-package-locked-error
                   (:symbol name "globally declaring the type of ~A"))
	       (when (eq (info :variable :where-from name) :declared)
		 (let ((old-type (info :variable :type name)))
		   (when (type/= type old-type)
		     (style-warn "The new TYPE proclamation~%  ~S~@
                                  for ~S does not match the old TYPE~@
                                  proclamation ~S"
				 type name old-type))))
	       (setf (info :variable :type name) type)
	       (setf (info :variable :where-from name) :declared)))
	   (push raw-form *queued-proclaims*)))
      (ftype
       (if *type-system-initialized*
	   (let ((ctype (specifier-type (first args))))
	     (unless (csubtypep ctype (specifier-type 'function))
	       (error "not a function type: ~S" (first args)))
	     (dolist (name (rest args))
	       (with-single-package-locked-error
                   (:symbol name "globally declaring the ftype of ~A"))
               (when (eq (info :function :where-from name) :declared)
                 (let ((old-type (info :function :type name)))
                   (when (type/= ctype old-type)
                     (style-warn
                      "new FTYPE proclamation~@
                       ~S~@
                       for ~S does not match old FTYPE proclamation~@
                       ~S"
                      ctype name old-type))))

	       ;; Now references to this function shouldn't be warned
	       ;; about as undefined, since even if we haven't seen a
	       ;; definition yet, we know one is planned.
	       ;;
	       ;; Other consequences of we-know-you're-a-function-now
	       ;; are appropriate too, e.g. any MACRO-FUNCTION goes away.
	       (proclaim-as-fun-name name)
	       (note-name-defined name :function)

	       ;; the actual type declaration
	       (setf (info :function :type name) ctype
		     (info :function :where-from name) :declared)))
	   (push raw-form *queued-proclaims*)))
      (freeze-type
       (dolist (type args)
	 (let ((class (specifier-type type)))
	   (when (typep class 'classoid)
	     (setf (classoid-state class) :sealed)
	     (let ((subclasses (classoid-subclasses class)))
	       (when subclasses
		 (dohash (subclass layout subclasses)
		   (declare (ignore layout))
		   (setf (classoid-state subclass) :sealed))))))))
      (optimize
       (setq *policy* (process-optimize-decl form *policy*)))
      (muffle-conditions
       (setq *handled-conditions*
	     (process-muffle-conditions-decl form *handled-conditions*)))
      (unmuffle-conditions
       (setq *handled-conditions*
	     (process-unmuffle-conditions-decl form *handled-conditions*)))
      ((disable-package-locks enable-package-locks)
         (setq *disabled-package-locks*
               (process-package-lock-decl form *disabled-package-locks*)))
      ((inline notinline maybe-inline)
       (dolist (name args)
	 (proclaim-as-fun-name name) ; since implicitly it is a function
	 (setf (info :function :inlinep name)
	       (ecase kind
		 (inline :inline)
		 (notinline :notinline)
		 (maybe-inline :maybe-inline)))))
      (declaration
       (dolist (decl args)
	 (unless (symbolp decl)
	   (error "In~%  ~S~%the declaration to be recognized is not a ~
                  symbol:~%  ~S"
		  form decl))
	 (with-single-package-locked-error
             (:symbol decl "globally declaring ~A as a declaration proclamation"))
	 (setf (info :declaration :recognized decl) t)))
      (t
       (unless (info :declaration :recognized kind)
	 (compiler-warn "unrecognized declaration ~S" raw-form)))))
  #+sb-xc (/show0 "returning from PROCLAIM")
  (values))
