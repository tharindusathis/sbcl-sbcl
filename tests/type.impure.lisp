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

(load "assertoid.lisp")
(use-package "ASSERTOID")

(defmacro assert-nil-nil (expr)
  `(assert (equal '(nil nil) (multiple-value-list ,expr))))
(defmacro assert-nil-t (expr)
  `(assert (equal '(nil t) (multiple-value-list ,expr))))
(defmacro assert-t-t (expr)
  `(assert (equal '(t t) (multiple-value-list ,expr))))

(defmacro assert-t-t-or-uncertain (expr)
  `(assert (let ((list (multiple-value-list ,expr)))
	     (or (equal '(nil nil) list)
		 (equal '(t t) list)))))

(let ((types '(character
	       integer fixnum (integer 0 10)
	       single-float (single-float -1.0 1.0) (single-float 0.1)
	       (real 4 8) (real -1 7) (real 2 11)
	       null symbol keyword
	       (member #\a #\b #\c) (member 1 #\a) (member 3.0 3.3)
              (member #\a #\c #\d #\f) (integer -1 1)
	       unsigned-byte
	       (rational -1 7) (rational -2 4)
	       ratio
	       )))
  (dolist (i types)
    (format t "type I=~S~%" i)
    (dolist (j types)
      (format t "  type J=~S~%" j)
      (assert (subtypep i `(or ,i ,j)))
      (assert (subtypep i `(or ,j ,i)))
      (assert (subtypep i `(or ,i ,i ,j)))
      (assert (subtypep i `(or ,j ,i)))
      (dolist (k types)
	(format t "    type K=~S~%" k)
	(assert (subtypep `(or ,i ,j) `(or ,i ,j ,k)))
	(assert (subtypep `(or ,i ,j) `(or ,k ,j ,i)))))))

;;; gotchas that can come up in handling subtypeness as "X is a
;;; subtype of Y if each of the elements of X is a subtype of Y"
(let ((subtypep-values (multiple-value-list
			(subtypep '(single-float -1.0 1.0)
				  '(or (real -100.0 0.0)
				       (single-float 0.0 100.0))))))
  (assert (member subtypep-values
		  '(;; The system isn't expected to
		    ;; understand the subtype relationship.
		    (nil nil)
		    ;; But if it does, that'd be neat.
		    (t t)
		    ;; (And any other return would be wrong.)
		    )
		  :test #'equal)))

(defun type-evidently-= (x y)
  (and (subtypep x y)
       (subtypep y x)))

(assert (subtypep 'single-float 'float))

(assert (type-evidently-= '(integer 0 10) '(or (integer 0 5) (integer 4 10))))

;;; Bug 50(c,d): numeric types with empty ranges should be NIL
(assert (type-evidently-= 'nil '(integer (0) (0))))
(assert (type-evidently-= 'nil '(rational (0) (0))))
(assert (type-evidently-= 'nil '(float (0.0) (0.0))))

;;; sbcl-0.6.10 did (UPGRADED-ARRAY-ELEMENT-TYPE 'SOME-UNDEF-TYPE)=>T
;;; and (UPGRADED-COMPLEX-PART-TYPE 'SOME-UNDEF-TYPE)=>T.
(assert (raises-error? (upgraded-array-element-type 'some-undef-type)))
(assert (eql (upgraded-array-element-type t) t))
(assert (raises-error? (upgraded-complex-part-type 'some-undef-type)))
(assert (subtypep (upgraded-complex-part-type 'fixnum) 'real))

;;; Do reasonable things with undefined types, and with compound types
;;; built from undefined types.
;;;
;;; part I: TYPEP
(assert (typep #(11) '(simple-array t 1)))
(assert (typep #(11) '(simple-array (or integer symbol) 1)))
(assert (raises-error? (typep #(11) '(simple-array undef-type 1))))
(assert (not (typep 11 '(simple-array undef-type 1))))
;;; part II: SUBTYPEP

(assert (subtypep '(vector some-undef-type) 'vector))
(assert (not (subtypep '(vector some-undef-type) 'integer)))
(assert-nil-nil (subtypep 'utype-1 'utype-2))
(assert-nil-nil (subtypep '(vector utype-1) '(vector utype-2)))
(assert-nil-nil (subtypep '(vector utype-1) '(vector t)))
(assert-nil-nil (subtypep '(vector t) '(vector utype-2)))

;;; ANSI specifically disallows bare AND and OR symbols as type specs.
(assert (raises-error? (typep 11 'and)))
(assert (raises-error? (typep 11 'or)))
(assert (raises-error? (typep 11 'member)))
(assert (raises-error? (typep 11 'values)))
(assert (raises-error? (typep 11 'eql)))
(assert (raises-error? (typep 11 'satisfies)))
(assert (raises-error? (typep 11 'not)))
;;; and while it doesn't specifically disallow illegal compound
;;; specifiers from the CL package, we don't have any.
(assert (raises-error? (subtypep 'fixnum '(fixnum 1))))
(assert (raises-error? (subtypep 'class '(list))))
(assert (raises-error? (subtypep 'foo '(ratio 1/2 3/2))))
(assert (raises-error? (subtypep 'character '(character 10))))
#+nil ; doesn't yet work on PCL-derived internal types
(assert (raises-error? (subtypep 'lisp '(class))))
#+nil
(assert (raises-error? (subtypep 'bar '(method number number))))

;;; Of course empty lists of subtypes are still OK.
(assert (typep 11 '(and)))
(assert (not (typep 11 '(or))))

;;; bug 12: type system didn't grok nontrivial intersections
(assert (subtypep '(and symbol (satisfies keywordp)) 'symbol))
(assert (not (subtypep '(and symbol (satisfies keywordp)) 'null)))
(assert (subtypep 'keyword 'symbol))
(assert (not (subtypep 'symbol 'keyword)))
(assert (subtypep 'ratio 'real))
(assert (subtypep 'ratio 'number))

;;; bug 50.g: Smarten up hairy type specifiers slightly. We may wish
;;; to revisit this, perhaps by implementing a COMPLEMENT type
;;; (analogous to UNION and INTERSECTION) to take the logic out of the
;;; HAIRY domain.
(assert-nil-t (subtypep 'atom 'cons))
(assert-nil-t (subtypep 'cons 'atom))
;;; These two are desireable but not necessary for ANSI conformance;
;;; maintenance work on other parts of the system broke them in
;;; sbcl-0.7.13.11 -- CSR
#+nil
(assert-nil-t (subtypep '(not list) 'cons))
#+nil
(assert-nil-t (subtypep '(not float) 'single-float))
(assert-t-t (subtypep '(not atom) 'cons))
(assert-t-t (subtypep 'cons '(not atom)))
;;; ANSI requires that SUBTYPEP relationships among built-in primitive
;;; types never be uncertain, i.e. never return NIL as second value.
;;; Prior to about sbcl-0.7.2.6, ATOM caused a lot of problems here
;;; (because it's a negation type, implemented as a HAIRY-TYPE, and
;;; CMU CL's HAIRY-TYPE logic punted a lot).
(assert-t-t (subtypep 'integer 'atom))
(assert-t-t (subtypep 'function 'atom))
(assert-nil-t (subtypep 'list 'atom))
(assert-nil-t (subtypep 'atom 'integer))
(assert-nil-t (subtypep 'atom 'function))
(assert-nil-t (subtypep 'atom 'list))
;;; ATOM is equivalent to (NOT CONS):
(assert-t-t (subtypep 'integer '(not cons)))
(assert-nil-t (subtypep 'list '(not cons)))
(assert-nil-t (subtypep '(not cons) 'integer))
(assert-nil-t (subtypep '(not cons) 'list))
;;; And we'd better check that all the named types are right. (We also
;;; do some more tests on ATOM here, since once CSR experimented with
;;; making it a named type.)
(assert-t-t (subtypep 'nil 'nil))
(assert-t-t (subtypep 'nil 'atom))
(assert-t-t (subtypep 'nil 't))
(assert-nil-t (subtypep 'atom 'nil))
(assert-t-t (subtypep 'atom 'atom))
(assert-t-t (subtypep 'atom 't))
(assert-nil-t (subtypep 't 'nil))
(assert-nil-t (subtypep 't 'atom))
(assert-t-t (subtypep 't 't))
;;; Also, LIST is now somewhat special, in that (NOT LIST) should be
;;; recognized as a subtype of ATOM:
(assert-t-t (subtypep '(not list) 'atom))
(assert-nil-t (subtypep 'atom '(not list)))
;;; These used to fail, because when the two arguments to subtypep are
;;; of different specifier-type types (e.g. HAIRY and UNION), there
;;; are two applicable type methods -- in this case
;;; HAIRY-COMPLEX-SUBTYPEP-ARG1-TYPE-METHOD and
;;; UNION-COMPLEX-SUBTYPEP-ARG2-TYPE-METHOD. Both of these exist, but
;;; [!%]INVOKE-TYPE-METHOD aren't smart enough to know that if one of
;;; them returns NIL, NIL (indicating uncertainty) it should try the
;;; other. However, as of sbcl-0.7.2.6 or so, CALL-NEXT-METHOD-ish
;;; logic in those type methods fixed it.
(assert-nil-t (subtypep '(not cons) 'list))
(assert-nil-t (subtypep '(not single-float) 'float))
;;; Somewhere along the line (probably when adding CALL-NEXT-METHOD-ish
;;; logic in SUBTYPEP type methods) we fixed bug 58 too:
(assert-t-t (subtypep '(and zilch integer) 'zilch))
(assert-t-t (subtypep '(and integer zilch) 'zilch))

;;; Bug 84: SB-KERNEL:CSUBTYPEP was a bit enthusiastic at
;;; special-casing calls to subtypep involving *EMPTY-TYPE*,
;;; corresponding to the NIL type-specifier; we were bogusly returning
;;; NIL, T (indicating surety) for the following:
(assert-nil-nil (subtypep '(satisfies some-undefined-fun) 'nil))

;;; It turns out that, as of sbcl-0.7.2, we require to be able to
;;; detect this to compile src/compiler/node.lisp (and in particular,
;;; the definition of the component structure). Since it's a sensible
;;; thing to want anyway, let's test for it here:
(assert-t-t (subtypep '(or some-undefined-type (member :no-ir2-yet :dead))
		      '(or some-undefined-type (member :no-ir2-yet :dead))))
;;; BUG 158 (failure to compile loops with vector references and
;;; increments of greater than 1) was a symptom of type system
;;; uncertainty, to wit:
(assert-t-t (subtypep '(and (mod 536870911) (or (integer 0 0) (integer 2 536870912)))
		      '(mod 536870911))) ; aka SB-INT:INDEX.
;;; floating point types can be tricky.
(assert-t-t (subtypep '(member 0.0) '(single-float 0.0 0.0)))
(assert-t-t (subtypep '(member -0.0) '(single-float 0.0 0.0)))
(assert-t-t (subtypep '(member 0.0) '(single-float -0.0 0.0)))
(assert-t-t (subtypep '(member -0.0) '(single-float 0.0 -0.0)))
(assert-t-t (subtypep '(member 0.0d0) '(double-float 0.0d0 0.0d0)))
(assert-t-t (subtypep '(member -0.0d0) '(double-float 0.0d0 0.0d0)))
(assert-t-t (subtypep '(member 0.0d0) '(double-float -0.0d0 0.0d0)))
(assert-t-t (subtypep '(member -0.0d0) '(double-float 0.0d0 -0.0d0)))

(assert-nil-t (subtypep '(single-float 0.0 0.0) '(member 0.0)))
(assert-nil-t (subtypep '(single-float 0.0 0.0) '(member -0.0)))
(assert-nil-t (subtypep '(single-float -0.0 0.0) '(member 0.0)))
(assert-nil-t (subtypep '(single-float 0.0 -0.0) '(member -0.0)))
(assert-nil-t (subtypep '(double-float 0.0d0 0.0d0) '(member 0.0d0)))
(assert-nil-t (subtypep '(double-float 0.0d0 0.0d0) '(member -0.0d0)))
(assert-nil-t (subtypep '(double-float -0.0d0 0.0d0) '(member 0.0d0)))
(assert-nil-t (subtypep '(double-float 0.0d0 -0.0d0) '(member -0.0d0)))

(assert-t-t (subtypep '(member 0.0 -0.0) '(single-float 0.0 0.0)))
(assert-t-t (subtypep '(single-float 0.0 0.0) '(member 0.0 -0.0)))
(assert-t-t (subtypep '(member 0.0d0 -0.0d0) '(double-float 0.0d0 0.0d0)))
(assert-t-t (subtypep '(double-float 0.0d0 0.0d0) '(member 0.0d0 -0.0d0)))

(assert-t-t (subtypep '(not (single-float 0.0 0.0)) '(not (member 0.0))))
(assert-t-t (subtypep '(not (double-float 0.0d0 0.0d0)) '(not (member 0.0d0))))

(assert-t-t (subtypep '(float -0.0) '(float 0.0)))
(assert-t-t (subtypep '(float 0.0) '(float -0.0)))
(assert-t-t (subtypep '(float (0.0)) '(float (-0.0))))
(assert-t-t (subtypep '(float (-0.0)) '(float (0.0))))

;;;; Douglas Thomas Crosher rewrote the CMU CL type test system to
;;;; allow inline type tests for CONDITIONs and STANDARD-OBJECTs, and
;;;; generally be nicer, and Martin Atzmueller ported the patches.
;;;; They look nice but they're nontrivial enough that it's not
;;;; obvious from inspection that everything is OK. Let's make sure
;;;; that things still basically work.

;; structure type tests setup
(defstruct structure-foo1)
(defstruct (structure-foo2 (:include structure-foo1))
  x)
(defstruct (structure-foo3 (:include structure-foo2)))
(defstruct (structure-foo4 (:include structure-foo3))
  y z)

;; structure-class tests setup
(defclass structure-class-foo1 () () (:metaclass cl:structure-class))
(defclass structure-class-foo2 (structure-class-foo1)
  () (:metaclass cl:structure-class))
(defclass structure-class-foo3 (structure-class-foo2)
  () (:metaclass cl:structure-class))
(defclass structure-class-foo4 (structure-class-foo3)
  () (:metaclass cl:structure-class))

;; standard-class tests setup
(defclass standard-class-foo1 () () (:metaclass cl:standard-class))
(defclass standard-class-foo2 (standard-class-foo1)
  () (:metaclass cl:standard-class))
(defclass standard-class-foo3 (standard-class-foo2)
  () (:metaclass cl:standard-class))
(defclass standard-class-foo4 (standard-class-foo3)
  () (:metaclass cl:standard-class))

;; condition tests setup
(define-condition condition-foo1 (condition) ())
(define-condition condition-foo2 (condition-foo1) ())
(define-condition condition-foo3 (condition-foo2) ())
(define-condition condition-foo4 (condition-foo3) ())

;;; inline type tests
(format t "~&/setting up *TESTS-OF-INLINE-TYPE-TESTS*~%")
(defparameter *tests-of-inline-type-tests*
  '(progn

     ;; structure type tests
     (assert (typep (make-structure-foo3) 'structure-foo2))
     (assert (not (typep (make-structure-foo1) 'structure-foo4)))
     (assert (typep (nth-value 1
			       (ignore-errors (structure-foo2-x
					       (make-structure-foo1))))
		    'type-error))
     (assert (null (ignore-errors
		     (setf (structure-foo2-x (make-structure-foo1)) 11))))

     ;; structure-class tests
     (assert (typep (make-instance 'structure-class-foo3)
		    'structure-class-foo2))
     (assert (not (typep (make-instance 'structure-class-foo1)
			 'structure-class-foo4)))
     (assert (null (ignore-errors
		     (setf (slot-value (make-instance 'structure-class-foo1)
				       'x)
			   11))))

     ;; standard-class tests
     (assert (typep (make-instance 'standard-class-foo3)
		    'standard-class-foo2))
     (assert (not (typep (make-instance 'standard-class-foo1)
			 'standard-class-foo4)))
     (assert (null (ignore-errors
		     (setf (slot-value (make-instance 'standard-class-foo1) 'x)
			   11))))

     ;; condition tests
     (assert (typep (make-condition 'condition-foo3)
		    'condition-foo2))
     (assert (not (typep (make-condition 'condition-foo1)
			 'condition-foo4)))
     (assert (null (ignore-errors
		     (setf (slot-value (make-condition 'condition-foo1) 'x)
			   11))))
     (assert (subtypep 'error 't))
     (assert (subtypep 'simple-condition 'condition))
     (assert (subtypep 'simple-error 'simple-condition))
     (assert (subtypep 'simple-error 'error))
     (assert (not (subtypep 'condition 'simple-condition)))
     (assert (not (subtypep 'error 'simple-error)))
     (assert (eq (car (sb-pcl:class-direct-superclasses
		       (find-class 'simple-condition)))
		 (find-class 'condition)))
    
     #+nil ; doesn't look like a good test
     (let ((subclasses (mapcar #'find-class
                               '(simple-type-error
                                 simple-error
                                 simple-warning
                                 sb-int:simple-file-error
                                 sb-int:simple-style-warning))))
       (assert (null (set-difference
                      (sb-pcl:class-direct-subclasses (find-class
                                                       'simple-condition))
                      subclasses))))
    
     ;; precedence lists
     (assert (equal (sb-pcl:class-precedence-list 
	 	     (find-class 'simple-condition))
	            (mapcar #'find-class '(simple-condition
			 		   condition
				 	   sb-pcl::slot-object
					   sb-kernel:instance
					   t))))

     ;; stream classes
     (assert (equal (sb-pcl:class-direct-superclasses (find-class
						       'fundamental-stream))
		    (mapcar #'find-class '(standard-object stream))))
     (assert (null (set-difference
		    (sb-pcl:class-direct-subclasses (find-class
						     'fundamental-stream))
		    (mapcar #'find-class '(fundamental-binary-stream
					   fundamental-character-stream
					   fundamental-output-stream
					   fundamental-input-stream)))))
     (assert (equal (sb-pcl:class-precedence-list (find-class
						   'fundamental-stream))
		    (mapcar #'find-class '(fundamental-stream
					   standard-object
					   sb-pcl::std-object
					   sb-pcl::slot-object
					   stream
					   sb-kernel:instance
					   t))))
     (assert (equal (sb-pcl:class-precedence-list (find-class
						   'fundamental-stream))
		    (mapcar #'find-class '(fundamental-stream
					   standard-object
					   sb-pcl::std-object
					   sb-pcl::slot-object stream
					   sb-kernel:instance t))))
     (assert (subtypep (find-class 'stream) (find-class t)))
     (assert (subtypep (find-class 'fundamental-stream) 'stream))
     (assert (not (subtypep 'stream 'fundamental-stream)))))
;;; Test under the interpreter.
(eval *tests-of-inline-type-tests*)
(format t "~&/done with interpreted *TESTS-OF-INLINE-TYPE-TESTS*~%")
;;; Test under the compiler.
(defun tests-of-inline-type-tests ()
  #.*tests-of-inline-type-tests*)
(tests-of-inline-type-tests)
(format t "~&/done with compiled (TESTS-OF-INLINE-TYPE-TESTS)~%")

;;; Redefinition of classes should alter the type hierarchy (BUG 140):
(defclass superclass () ())
(defclass maybe-subclass () ())
(assert-nil-t (subtypep 'maybe-subclass 'superclass))
(defclass maybe-subclass (superclass) ())
(assert-t-t (subtypep 'maybe-subclass 'superclass))
(defclass maybe-subclass () ())
(assert-nil-t (subtypep 'maybe-subclass 'superclass))

;;; Prior to sbcl-0.7.6.27, there was some confusion in ARRAY types
;;; specialized on some as-yet-undefined type which would cause this
;;; program to fail (bugs #123 and #165). Verify that it doesn't.
(defun foo (x)
  (declare (type (vector bar) x))
  (aref x 1))
(deftype bar () 'single-float)
(assert (eql (foo (make-array 3 :element-type 'bar :initial-element 0.0f0))
	     0.0f0))

;;; bug 260a
(assert-t-t
 (let* ((s (gensym))
        (t1 (sb-kernel:specifier-type s)))
   (eval `(defstruct ,s))
   (sb-kernel:type= t1 (sb-kernel:specifier-type s))))

;;; bug found by PFD's random subtypep tester
(let ((t1 '(cons rational (cons (not rational) (cons integer t))))
      (t2 '(not (cons (integer 0 1) (cons single-float long-float)))))
  (assert-t-t (subtypep t1 t2))
  (assert-nil-t (subtypep t2 t1))
  (assert-t-t (subtypep `(not ,t2) `(not ,t1)))
  (assert-nil-t (subtypep `(not ,t1) `(not ,t2))))

;;; success
(quit :unix-status 104)
