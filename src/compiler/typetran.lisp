;;;; This file contains stuff that implements the portable IR1
;;;; semantics of type tests and coercion. The main thing we do is
;;;; convert complex type operations into simpler code that can be
;;;; compiled inline.

;;;; This software is part of the SBCL system. See the README file for
;;;; more information.
;;;;
;;;; This software is derived from the CMU CL system, which was
;;;; written at Carnegie Mellon University and released into the
;;;; public domain. The software is in the public domain and is
;;;; provided with absolutely no warranty. See the COPYING and CREDITS
;;;; files for more information.

(in-package "SB!C")

;;;; type predicate translation
;;;;
;;;; We maintain a bidirectional association between type predicates
;;;; and the tested type. The presence of a predicate in this
;;;; association implies that it is desirable to implement tests of
;;;; this type using the predicate. These are either predicates that
;;;; the back end is likely to have special knowledge about, or
;;;; predicates so complex that the only reasonable implentation is
;;;; via function call.
;;;;
;;;; Some standard types (such as SEQUENCE) are best tested by letting
;;;; the TYPEP source transform do its thing with the expansion. These
;;;; types (and corresponding predicates) are not maintained in this
;;;; association. In this case, there need not be any predicate
;;;; function unless it is required by the Common Lisp specification.
;;;;
;;;; The mapping between predicates and type structures is considered
;;;; part of the backend; different backends can support different
;;;; sets of predicates.

;;; Establish an association between the type predicate NAME and the
;;; corresponding TYPE. This causes the type predicate to be
;;; recognized for purposes of optimization.
(defmacro define-type-predicate (name type)
  `(%define-type-predicate ',name ',type))
(defun %define-type-predicate (name specifier)
  (let ((type (specifier-type specifier)))
    (setf (gethash name *backend-predicate-types*) type)
    (setf *backend-type-predicates*
	  (cons (cons type name)
		(remove name *backend-type-predicates*
			:key #'cdr)))
    (%deftransform name '(function (t) *) #'fold-type-predicate)
    name))

;;;; IR1 transforms

;;; If we discover the type argument is constant during IR1
;;; optimization, then give the source transform another chance. The
;;; source transform can't pass, since we give it an explicit
;;; constant. At worst, it will convert to %TYPEP, which will prevent
;;; spurious attempts at transformation (and possible repeated
;;; warnings.)
(deftransform typep ((object type))
  (unless (constant-lvar-p type)
    (give-up-ir1-transform "can't open-code test of non-constant type"))
  `(typep object ',(lvar-value type)))

;;; If the lvar OBJECT definitely is or isn't of the specified
;;; type, then return T or NIL as appropriate. Otherwise quietly
;;; GIVE-UP-IR1-TRANSFORM.
(defun ir1-transform-type-predicate (object type)
  (declare (type lvar object) (type ctype type))
  (let ((otype (lvar-type object)))
    (cond ((not (types-equal-or-intersect otype type))
	   nil)
	  ((csubtypep otype type)
	   t)
          ((eq type *empty-type*)
           nil)
	  (t
	   (give-up-ir1-transform)))))

;;; Flush %TYPEP tests whose result is known at compile time.
(deftransform %typep ((object type))
  (unless (constant-lvar-p type)
    (give-up-ir1-transform))
  (ir1-transform-type-predicate
   object
   (ir1-transform-specifier-type (lvar-value type))))

;;; This is the IR1 transform for simple type predicates. It checks
;;; whether the single argument is known to (not) be of the
;;; appropriate type, expanding to T or NIL as appropriate.
(deftransform fold-type-predicate ((object) * * :node node :defun-only t)
  (let ((ctype (gethash (leaf-source-name
			 (ref-leaf
			  (lvar-uses
			   (basic-combination-fun node))))
			*backend-predicate-types*)))
    (aver ctype)
    (ir1-transform-type-predicate object ctype)))

;;; If FIND-CLASS is called on a constant class, locate the CLASS-CELL
;;; at load time.
(deftransform find-classoid ((name) ((constant-arg symbol)) *)
  (let* ((name (lvar-value name))
	 (cell (find-classoid-cell name)))
    `(or (classoid-cell-classoid ',cell)
	 (error "class not yet defined: ~S" name))))

;;;; standard type predicates, i.e. those defined in package COMMON-LISP,
;;;; plus at least one oddball (%INSTANCEP)
;;;;
;;;; Various other type predicates (e.g. low-level representation
;;;; stuff like SIMPLE-ARRAY-SINGLE-FLOAT-P) are defined elsewhere.

;;; FIXME: This function is only called once, at top level. Why not
;;; just expand all its operations into toplevel code?
(defun !define-standard-type-predicates ()
  (define-type-predicate arrayp array)
  ; (The ATOM predicate is handled separately as (NOT CONS).)
  (define-type-predicate bit-vector-p bit-vector)
  (define-type-predicate characterp character)
  (define-type-predicate compiled-function-p compiled-function)
  (define-type-predicate complexp complex)
  (define-type-predicate complex-rational-p (complex rational))
  (define-type-predicate complex-float-p (complex float))
  (define-type-predicate consp cons)
  (define-type-predicate floatp float)
  (define-type-predicate functionp function)
  (define-type-predicate integerp integer)
  (define-type-predicate keywordp keyword)
  (define-type-predicate listp list)
  (define-type-predicate null null)
  (define-type-predicate numberp number)
  (define-type-predicate rationalp rational)
  (define-type-predicate realp real)
  (define-type-predicate simple-bit-vector-p simple-bit-vector)
  (define-type-predicate simple-string-p simple-string)
  (define-type-predicate simple-vector-p simple-vector)
  (define-type-predicate stringp string)
  (define-type-predicate %instancep instance)
  (define-type-predicate funcallable-instance-p funcallable-instance)
  (define-type-predicate symbolp symbol)
  (define-type-predicate vectorp vector))
(!define-standard-type-predicates)

;;;; transforms for type predicates not implemented primitively
;;;;
;;;; See also VM dependent transforms.

(define-source-transform atom (x)
  `(not (consp ,x)))
#!+sb-unicode
(define-source-transform base-char-p (x)
  `(typep ,x 'base-char))

;;;; TYPEP source transform

;;; Return a form that tests the variable N-OBJECT for being in the
;;; binds specified by TYPE. BASE is the name of the base type, for
;;; declaration. We make SAFETY locally 0 to inhibit any checking of
;;; this assertion.
(defun transform-numeric-bound-test (n-object type base)
  (declare (type numeric-type type))
  (let ((low (numeric-type-low type))
	(high (numeric-type-high type)))
    `(locally
       (declare (optimize (safety 0)))
       (and ,@(when low
		(if (consp low)
		    `((> (truly-the ,base ,n-object) ,(car low)))
		    `((>= (truly-the ,base ,n-object) ,low))))
	    ,@(when high
		(if (consp high)
		    `((< (truly-the ,base ,n-object) ,(car high)))
		    `((<= (truly-the ,base ,n-object) ,high))))))))

;;; Do source transformation of a test of a known numeric type. We can
;;; assume that the type doesn't have a corresponding predicate, since
;;; those types have already been picked off. In particular, CLASS
;;; must be specified, since it is unspecified only in NUMBER and
;;; COMPLEX. Similarly, we assume that COMPLEXP is always specified.
;;;
;;; For non-complex types, we just test that the number belongs to the
;;; base type, and then test that it is in bounds. When CLASS is
;;; INTEGER, we check to see whether the range is no bigger than
;;; FIXNUM. If so, we check for FIXNUM instead of INTEGER. This allows
;;; us to use fixnum comparison to test the bounds.
;;;
;;; For complex types, we must test for complex, then do the above on
;;; both the real and imaginary parts. When CLASS is float, we need
;;; only check the type of the realpart, since the format of the
;;; realpart and the imagpart must be the same.
(defun source-transform-numeric-typep (object type)
  (let* ((class (numeric-type-class type))
	 (base (ecase class
		 (integer (containing-integer-type
                           (if (numeric-type-complexp type)
                               (modified-numeric-type type
                                                      :complexp :real)
                               type)))
		 (rational 'rational)
		 (float (or (numeric-type-format type) 'float))
		 ((nil) 'real))))
    (once-only ((n-object object))
      (ecase (numeric-type-complexp type)
	(:real
	 `(and (typep ,n-object ',base)
	       ,(transform-numeric-bound-test n-object type base)))
	(:complex
	 `(and (complexp ,n-object)
	       ,(once-only ((n-real `(realpart (truly-the complex ,n-object)))
			    (n-imag `(imagpart (truly-the complex ,n-object))))
		  `(progn
		     ,n-imag ; ignorable
		     (and (typep ,n-real ',base)
			  ,@(when (eq class 'integer)
			      `((typep ,n-imag ',base)))
			  ,(transform-numeric-bound-test n-real type base)
			  ,(transform-numeric-bound-test n-imag type
							 base))))))))))

;;; Do the source transformation for a test of a hairy type. AND,
;;; SATISFIES and NOT are converted into the obvious code. We convert
;;; unknown types to %TYPEP, emitting an efficiency note if
;;; appropriate.
(defun source-transform-hairy-typep (object type)
  (declare (type hairy-type type))
  (let ((spec (hairy-type-specifier type)))
    (cond ((unknown-type-p type)
	   (when (policy *lexenv* (> speed inhibit-warnings))
	     (compiler-notify "can't open-code test of unknown type ~S"
			      (type-specifier type)))
	   `(%typep ,object ',spec))
	  (t
	   (ecase (first spec)
	     (satisfies `(if (funcall #',(second spec) ,object) t nil))
	     ((not and)
	      (once-only ((n-obj object))
		`(,(first spec) ,@(mapcar (lambda (x)
					    `(typep ,n-obj ',x))
					  (rest spec))))))))))

(defun source-transform-negation-typep (object type)
  (declare (type negation-type type))
  (let ((spec (type-specifier (negation-type-type type))))
    `(not (typep ,object ',spec))))

;;; Do source transformation for TYPEP of a known union type. If a
;;; union type contains LIST, then we pull that out and make it into a
;;; single LISTP call.  Note that if SYMBOL is in the union, then LIST
;;; will be a subtype even without there being any (member NIL).  We
;;; currently just drop through to the general code in this case,
;;; rather than trying to optimize it (but FIXME CSR 2004-04-05: it
;;; wouldn't be hard to optimize it after all).
(defun source-transform-union-typep (object type)
  (let* ((types (union-type-types type))
         (type-cons (specifier-type 'cons))
	 (mtype (find-if #'member-type-p types))
         (members (when mtype (member-type-members mtype))))
    (if (and mtype
             (memq nil members)
             (memq type-cons types))
	(once-only ((n-obj object))
          `(or (listp ,n-obj)
               (typep ,n-obj
                      '(or ,@(mapcar #'type-specifier
                                     (remove type-cons
                                             (remove mtype types)))
                        (member ,@(remove nil members))))))
	(once-only ((n-obj object))
	  `(or ,@(mapcar (lambda (x)
			   `(typep ,n-obj ',(type-specifier x)))
			 types))))))

;;; Do source transformation for TYPEP of a known intersection type.
(defun source-transform-intersection-typep (object type)
  (once-only ((n-obj object))
    `(and ,@(mapcar (lambda (x)
		      `(typep ,n-obj ',(type-specifier x)))
		    (intersection-type-types type)))))

;;; If necessary recurse to check the cons type.
(defun source-transform-cons-typep (object type)
  (let* ((car-type (cons-type-car-type type))
	 (cdr-type (cons-type-cdr-type type)))
    (let ((car-test-p (not (type= car-type *universal-type*)))
	  (cdr-test-p (not (type= cdr-type *universal-type*))))
      (if (and (not car-test-p) (not cdr-test-p))
	  `(consp ,object)
	  (once-only ((n-obj object))
	    `(and (consp ,n-obj)
		  ,@(if car-test-p
			`((typep (car ,n-obj)
				 ',(type-specifier car-type))))
		  ,@(if cdr-test-p
			`((typep (cdr ,n-obj)
				 ',(type-specifier cdr-type))))))))))
 
(defun source-transform-character-set-typep (object type)
  (let ((pairs (character-set-type-pairs type)))
    (if (and (= (length pairs) 1)
            (= (caar pairs) 0)
            (= (cdar pairs) (1- sb!xc:char-code-limit)))
       `(characterp ,object)
       (once-only ((n-obj object))
         (let ((n-code (gensym "CODE")))
           `(and (characterp ,n-obj)
                 (let ((,n-code (sb!xc:char-code ,n-obj)))
                   (or
                    ,@(loop for pair in pairs
                            collect
                            `(<= ,(car pair) ,n-code ,(cdr pair)))))))))))

;;; Return the predicate and type from the most specific entry in
;;; *TYPE-PREDICATES* that is a supertype of TYPE.
(defun find-supertype-predicate (type)
  (declare (type ctype type))
  (let ((res nil)
	(res-type nil))
    (dolist (x *backend-type-predicates*)
      (let ((stype (car x)))
	(when (and (csubtypep type stype)
		   (or (not res-type)
		       (csubtypep stype res-type)))
	  (setq res-type stype)
	  (setq res (cdr x)))))
    (values res res-type)))

;;; Return forms to test that OBJ has the rank and dimensions
;;; specified by TYPE, where STYPE is the type we have checked against
;;; (which is the same but for dimensions.)
(defun test-array-dimensions (obj type stype)
  (declare (type array-type type stype))
  (let ((obj `(truly-the ,(type-specifier stype) ,obj))
	(dims (array-type-dimensions type)))
    (unless (eq dims '*)
      (collect ((res))
	(when (eq (array-type-dimensions stype) '*)
	  (res `(= (array-rank ,obj) ,(length dims))))
	(do ((i 0 (1+ i))
	     (dim dims (cdr dim)))
	    ((null dim))
	  (let ((dim (car dim)))
	    (unless (eq dim '*)
	      (res `(= (array-dimension ,obj ,i) ,dim)))))
	(res)))))

;;; If we can find a type predicate that tests for the type without
;;; dimensions, then use that predicate and test for dimensions.
;;; Otherwise, just do %TYPEP.
(defun source-transform-array-typep (obj type)
  (multiple-value-bind (pred stype) (find-supertype-predicate type)
    (if (and (array-type-p stype)
	     ;; (If the element type hasn't been defined yet, it's
	     ;; not safe to assume here that it will eventually
	     ;; have (UPGRADED-ARRAY-ELEMENT-TYPE type)=T, so punt.)
	     (not (unknown-type-p (array-type-element-type type)))
	     (type= (array-type-specialized-element-type stype)
		    (array-type-specialized-element-type type))
	     (eq (array-type-complexp stype) (array-type-complexp type)))
	(once-only ((n-obj obj))
	  `(and (,pred ,n-obj)
		,@(test-array-dimensions n-obj type stype)))
	`(%typep ,obj ',(type-specifier type)))))

;;; Transform a type test against some instance type. The type test is
;;; flushed if the result is known at compile time. If not properly
;;; named, error. If sealed and has no subclasses, just test for
;;; layout-EQ. If a structure then test for layout-EQ and then a
;;; general test based on layout-inherits. If safety is important,
;;; then we also check whether the layout for the object is invalid
;;; and signal an error if so. Otherwise, look up the indirect
;;; class-cell and call CLASS-CELL-TYPEP at runtime.
(deftransform %instance-typep ((object spec) (* *) * :node node)
  (aver (constant-lvar-p spec))
  (let* ((spec (lvar-value spec))
	 (class (specifier-type spec))
	 (name (classoid-name class))
	 (otype (lvar-type object))
	 (layout (let ((res (info :type :compiler-layout name)))
		   (if (and res (not (layout-invalid res)))
		       res
		       nil))))
    (cond
      ;; Flush tests whose result is known at compile time.
      ((not (types-equal-or-intersect otype class))
       nil)
      ((csubtypep otype class)
       t)
      ;; If not properly named, error.
      ((not (and name (eq (find-classoid name) class)))
       (compiler-error "can't compile TYPEP of anonymous or undefined ~
                        class:~%  ~S"
		       class))
      (t
        ;; Delay the type transform to give type propagation a chance.
        (delay-ir1-transform node :constraint)

       ;; Otherwise transform the type test.
       (multiple-value-bind (pred get-layout)
	   (cond
	     ((csubtypep class (specifier-type 'funcallable-instance))
	      (values 'funcallable-instance-p '%funcallable-instance-layout))
	     ((csubtypep class (specifier-type 'instance))
	      (values '%instancep '%instance-layout))
	     (t
	      (values '(lambda (x) (declare (ignore x)) t) 'layout-of)))
	 (cond
	   ((and (eq (classoid-state class) :sealed) layout
		 (not (classoid-subclasses class)))
	    ;; Sealed and has no subclasses.
	    (let ((n-layout (gensym)))
	      `(and (,pred object)
		    (let ((,n-layout (,get-layout object)))
		      ,@(when (policy *lexenv* (>= safety speed))
			      `((when (layout-invalid ,n-layout)
				  (%layout-invalid-error object ',layout))))
		      (eq ,n-layout ',layout)))))
	   ((and (typep class 'basic-structure-classoid) layout)
	    ;; structure type tests; hierarchical layout depths
	    (let ((depthoid (layout-depthoid layout))
		  (n-layout (gensym)))
	      `(and (,pred object)
		    (let ((,n-layout (,get-layout object)))
		      ,@(when (policy *lexenv* (>= safety speed))
			      `((when (layout-invalid ,n-layout)
				  (%layout-invalid-error object ',layout))))
		      (if (eq ,n-layout ',layout)
			  t
			  (and (> (layout-depthoid ,n-layout)
				  ,depthoid)
			       (locally (declare (optimize (safety 0)))
				 (eq (svref (layout-inherits ,n-layout)
					    ,depthoid)
				     ',layout))))))))
           ((and layout (>= (layout-depthoid layout) 0))
	    ;; hierarchical layout depths for other things (e.g.
	    ;; CONDITIONs)
	    (let ((depthoid (layout-depthoid layout))
		  (n-layout (gensym))
		  (n-inherits (gensym)))
	      `(and (,pred object)
		    (let ((,n-layout (,get-layout object)))
		      ,@(when (policy *lexenv* (>= safety speed))
			  `((when (layout-invalid ,n-layout)
			      (%layout-invalid-error object ',layout))))
		      (if (eq ,n-layout ',layout)
			  t
			  (let ((,n-inherits (layout-inherits ,n-layout)))
			    (declare (optimize (safety 0)))
			    (and (> (length ,n-inherits) ,depthoid)
				 (eq (svref ,n-inherits ,depthoid)
				     ',layout))))))))
	   (t
	    (/noshow "default case -- ,PRED and CLASS-CELL-TYPEP")
	    `(and (,pred object)
		  (classoid-cell-typep (,get-layout object)
				       ',(find-classoid-cell name)
		                       object)))))))))

;;; If the specifier argument is a quoted constant, then we consider
;;; converting into a simple predicate or other stuff. If the type is
;;; constant, but we can't transform the call, then we convert to
;;; %TYPEP. We only pass when the type is non-constant. This allows us
;;; to recognize between calls that might later be transformed
;;; successfully when a constant type is discovered. We don't give an
;;; efficiency note when we pass, since the IR1 transform will give
;;; one if necessary and appropriate.
;;;
;;; If the type is TYPE= to a type that has a predicate, then expand
;;; to that predicate. Otherwise, we dispatch off of the type's type.
;;; These transformations can increase space, but it is hard to tell
;;; when, so we ignore policy and always do them. 
(define-source-transform typep (object spec)
  ;; KLUDGE: It looks bad to only do this on explicitly quoted forms,
  ;; since that would overlook other kinds of constants. But it turns
  ;; out that the DEFTRANSFORM for TYPEP detects any constant
  ;; lvar, transforms it into a quoted form, and gives this
  ;; source transform another chance, so it all works out OK, in a
  ;; weird roundabout way. -- WHN 2001-03-18
  (if (and (consp spec) (eq (car spec) 'quote))
      (let ((type (careful-specifier-type (cadr spec))))
	(or (when (not type)
              (compiler-warn "illegal type specifier for TYPEP: ~S"
                             (cadr spec))
              `(%typep ,object ,spec))
            (let ((pred (cdr (assoc type *backend-type-predicates*
				    :test #'type=))))
	      (when pred `(,pred ,object)))
	    (typecase type
	      (hairy-type
	       (source-transform-hairy-typep object type))
	      (negation-type
	       (source-transform-negation-typep object type))
	      (union-type
	       (source-transform-union-typep object type))
	      (intersection-type
	       (source-transform-intersection-typep object type))
	      (member-type
	       `(member ,object ',(member-type-members type)))
	      (args-type
	       (compiler-warn "illegal type specifier for TYPEP: ~S"
			      (cadr spec))
	       `(%typep ,object ,spec))
	      (t nil))
	    (typecase type
	      (numeric-type
	       (source-transform-numeric-typep object type))
	      (classoid
	       `(%instance-typep ,object ,spec))
	      (array-type
	       (source-transform-array-typep object type))
	      (cons-type
	       (source-transform-cons-typep object type))
             (character-set-type
              (source-transform-character-set-typep object type))
	      (t nil))
	    `(%typep ,object ,spec)))
      (values nil t)))

;;;; coercion

(deftransform coerce ((x type) (* *) * :node node)
  (unless (constant-lvar-p type)
    (give-up-ir1-transform))
  (let ((tspec (ir1-transform-specifier-type (lvar-value type))))
    (if (csubtypep (lvar-type x) tspec)
	'x
	;; Note: The THE here makes sure that specifiers like
	;; (SINGLE-FLOAT 0.0 1.0) can raise a TYPE-ERROR.
	`(the ,(lvar-value type)
	   ,(cond
	     ((csubtypep tspec (specifier-type 'double-float))
	      '(%double-float x))
	     ;; FIXME: #!+long-float (t ,(error "LONG-FLOAT case needed"))
	     ((csubtypep tspec (specifier-type 'float))
	      '(%single-float x))
	     ((and (csubtypep tspec (specifier-type 'simple-vector))
		   ;; Can we avoid checking for dimension issues like
		   ;; (COERCE FOO '(SIMPLE-VECTOR 5)) returning a
		   ;; vector of length 6?
		   (or (policy node (< safety 3)) ; no need in unsafe code
		       (and (array-type-p tspec) ; no need when no dimensions
			    (equal (array-type-dimensions tspec) '(*)))))
	      `(if (simple-vector-p x)
		   x
		   (replace (make-array (length x)) x)))
	     ;; FIXME: other VECTOR types?
	     (t
	      (give-up-ir1-transform)))))))


