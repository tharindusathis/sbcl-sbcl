;;;; predicate functions (EQUAL and friends, and type predicates)

;;;; This software is part of the SBCL system. See the README file for
;;;; more information.
;;;;
;;;; This software is derived from the CMU CL system, which was
;;;; written at Carnegie Mellon University and released into the
;;;; public domain. The software is in the public domain and is
;;;; provided with absolutely no warranty. See the COPYING and CREDITS
;;;; files for more information.

(in-package "SB!IMPL")

;;;; miscellaneous non-primitive predicates

#!-sb-fluid (declaim (inline streamp))
(defun streamp (stream)
  (typep stream 'stream))

;;; Is X a (VECTOR T)?
(defun vector-t-p (x)
  (or (simple-vector-p x)
      (and (complex-vector-p x)
	   (simple-vector-p (%array-data-vector x)))))

;;;; primitive predicates. These must be supported directly by the
;;;; compiler.

(defun not (object)
  #!+sb-doc
  "Return T if X is NIL, otherwise return NIL."
  (not object))

;;; All the primitive type predicate wrappers share a parallel form..
(macrolet ((def-type-predicate-wrapper (pred)
	     (let* ((name (symbol-name pred))
		    (stem (string-left-trim "%" (string-right-trim "P-" name)))
		    (article (if (position (schar name 0) "AEIOU") "an" "a")))
	       `(defun ,pred (object)
		  ,(format nil
			   "Return true if OBJECT is ~A ~A, and NIL otherwise."
			   article
			   stem)
		  ;; (falling through to low-level implementation)
		  (,pred object)))))
  (def-type-predicate-wrapper array-header-p)
  (def-type-predicate-wrapper arrayp)
  (def-type-predicate-wrapper atom)
  (def-type-predicate-wrapper base-char-p)
  (def-type-predicate-wrapper base-string-p)
  (def-type-predicate-wrapper bignump)
  (def-type-predicate-wrapper bit-vector-p)
  (def-type-predicate-wrapper characterp)
  (def-type-predicate-wrapper code-component-p)
  (def-type-predicate-wrapper consp)
  (def-type-predicate-wrapper compiled-function-p)
  (def-type-predicate-wrapper complexp)
  (def-type-predicate-wrapper complex-double-float-p)
  (def-type-predicate-wrapper complex-float-p)
  #!+long-float (def-type-predicate-wrapper complex-long-float-p)
  (def-type-predicate-wrapper complex-rational-p)
  (def-type-predicate-wrapper complex-single-float-p)
  ;; (COMPLEX-VECTOR-P is not included here since it's awkward to express
  ;; the type it tests for in the Common Lisp type system, and since it's
  ;; only used in the implementation of a few specialized things.)
  (def-type-predicate-wrapper double-float-p)
  (def-type-predicate-wrapper extended-char-p)
  (def-type-predicate-wrapper fdefn-p)
  (def-type-predicate-wrapper fixnump)
  (def-type-predicate-wrapper floatp)
  (def-type-predicate-wrapper functionp)
  (def-type-predicate-wrapper integerp)
  (def-type-predicate-wrapper listp)
  (def-type-predicate-wrapper long-float-p)
  (def-type-predicate-wrapper lra-p)
  (def-type-predicate-wrapper null)
  (def-type-predicate-wrapper numberp)
  (def-type-predicate-wrapper rationalp)
  (def-type-predicate-wrapper ratiop)
  (def-type-predicate-wrapper realp)
  (def-type-predicate-wrapper short-float-p)
  (def-type-predicate-wrapper simple-array-p)
  (def-type-predicate-wrapper simple-bit-vector-p)
  (def-type-predicate-wrapper simple-base-string-p)
  (def-type-predicate-wrapper simple-string-p)
  (def-type-predicate-wrapper simple-vector-p)
  (def-type-predicate-wrapper single-float-p)
  (def-type-predicate-wrapper stringp)
  (def-type-predicate-wrapper %instancep)
  (def-type-predicate-wrapper symbolp)
  (def-type-predicate-wrapper system-area-pointer-p)
  (def-type-predicate-wrapper weak-pointer-p)
  (def-type-predicate-wrapper vectorp)
  ;#!+#.(cl:if (cl:= 32 sb!vm:n-word-bits) '(and) '(or))
  (def-type-predicate-wrapper unsigned-byte-32-p)
  ;#!+#.(cl:if (cl:= 32 sb!vm:n-word-bits) '(and) '(or))
  (def-type-predicate-wrapper signed-byte-32-p)
  #!+#.(cl:if (cl:= 64 sb!vm:n-word-bits) '(and) '(or))
  (def-type-predicate-wrapper unsigned-byte-64-p)
  #!+#.(cl:if (cl:= 64 sb!vm:n-word-bits) '(and) '(or))
  (def-type-predicate-wrapper signed-byte-64-p)
  (def-type-predicate-wrapper simple-array-nil-p)
  (def-type-predicate-wrapper simple-array-unsigned-byte-2-p)
  (def-type-predicate-wrapper simple-array-unsigned-byte-4-p)
  (def-type-predicate-wrapper simple-array-unsigned-byte-8-p)
  (def-type-predicate-wrapper simple-array-unsigned-byte-16-p)
  (def-type-predicate-wrapper simple-array-unsigned-byte-32-p)
  #!+#.(cl:if (cl:= 64 sb!vm:n-word-bits) '(and) '(or))
  (def-type-predicate-wrapper simple-array-unsigned-byte-64-p)
  (def-type-predicate-wrapper simple-array-signed-byte-8-p)
  (def-type-predicate-wrapper simple-array-signed-byte-16-p)
  #!+#.(cl:if (cl:= 32 sb!vm:n-word-bits) '(and) '(or))
  (def-type-predicate-wrapper simple-array-signed-byte-30-p)
  (def-type-predicate-wrapper simple-array-signed-byte-32-p)
  #!+#.(cl:if (cl:= 64 sb!vm:n-word-bits) '(and) '(or))
  (def-type-predicate-wrapper simple-array-signed-byte-61-p)
  #!+#.(cl:if (cl:= 64 sb!vm:n-word-bits) '(and) '(or))
  (def-type-predicate-wrapper simple-array-signed-byte-64-p)
  (def-type-predicate-wrapper simple-array-single-float-p)
  (def-type-predicate-wrapper simple-array-double-float-p)
  #!+long-float (def-type-predicate-wrapper simple-array-long-float-p)
  (def-type-predicate-wrapper simple-array-complex-single-float-p)
  (def-type-predicate-wrapper simple-array-complex-double-float-p)
  #!+long-float (def-type-predicate-wrapper simple-array-complex-long-float-p))

;;; Return the specifier for the type of object. This is not simply
;;; (TYPE-SPECIFIER (CTYPE-OF OBJECT)) because CTYPE-OF has different
;;; goals than TYPE-OF. In particular, speed is more important than
;;; precision, and it is not permitted to return member types.
(defun type-of (object)
  #!+sb-doc
  "Return the type of OBJECT."
  (typecase object
    (fixnum
     (cond
       ((<= 0 object 1) 'bit)
       ((< object 0) 'fixnum)
       (t '(integer 0 #.sb!xc:most-positive-fixnum))))
    (integer
     (if (>= object 0)
	 '(integer #.(1+ sb!xc:most-positive-fixnum))
	 'bignum))
    (standard-char 'standard-char)
    (base-char 'base-char)
    (extended-char 'extended-char)
    ((member t) 'boolean)
    (keyword 'keyword)
    ((or array complex) (type-specifier (ctype-of object)))
    (t
     (let* ((classoid (layout-classoid (layout-of object)))
	    (name (classoid-name classoid)))
       (if (typep object 'instance)
	   (case name
	     (sb!alien-internals:alien-value
	      `(sb!alien:alien
		,(sb!alien-internals:unparse-alien-type
		  (sb!alien-internals:alien-value-type object))))
	     (t
	      (let ((pname (classoid-proper-name classoid)))
		(if (classoid-p pname)
		    (classoid-pcl-class pname)
		    pname))))
	   name)))))

;;;; equality predicates

;;; This is real simple, 'cause the compiler takes care of it.
(defun eq (obj1 obj2)
  #!+sb-doc
  "Return T if OBJ1 and OBJ2 are the same object, otherwise NIL."
  (eq obj1 obj2))

(defun bit-vector-= (x y)
  (declare (type bit-vector x y))
  (if (and (simple-bit-vector-p x)
	   (simple-bit-vector-p y))
      (bit-vector-= x y) ; DEFTRANSFORM
      (and (= (length x) (length y))
	   (do ((i 0 (1+ i))
		(length (length x)))
	       ((= i length) t)
	     (declare (fixnum i))
	     (unless (= (bit x i) (bit y i))
	       (return nil))))))

(defun equal (x y)
  #!+sb-doc
  "Return T if X and Y are EQL or if they are structured components
  whose elements are EQUAL. Strings and bit-vectors are EQUAL if they
  are the same length and have identical components. Other arrays must be
  EQ to be EQUAL."
  (cond ((eql x y) t)
	((consp x)
	 (and (consp y)
	      (equal (car x) (car y))
	      (equal (cdr x) (cdr y))))
	((stringp x)
	 (and (stringp y) (string= x y)))
	((pathnamep x)
	 (and (pathnamep y) (pathname= x y)))
	((bit-vector-p x)
	 (and (bit-vector-p y)
	      (bit-vector-= x y)))
	(t nil)))

;;; EQUALP comparison of HASH-TABLE values
(defun hash-table-equalp (x y)
  (declare (type hash-table x y))
  (or (eq x y)
      (and (hash-table-p y)
	   (eql (hash-table-count x) (hash-table-count y))
	   (eql (hash-table-test x) (hash-table-test y))
	   (block comparison-of-entries
	     (maphash (lambda (key x-value)
			(multiple-value-bind (y-value y-value-p)
			    (gethash key y)
			  (unless (and y-value-p (equalp x-value y-value))
			    (return-from comparison-of-entries nil))))
		      x)
	     t))))

(defun equalp (x y)
  #+nil ; KLUDGE: If doc string, should be accurate: Talk about structures
  ; and HASH-TABLEs.
  "This is like EQUAL, except more liberal in several respects.
  Numbers may be of different types, as long as the values are identical
  after coercion. Characters may differ in alphabetic case. Vectors and
  arrays must have identical dimensions and EQUALP elements, but may differ
  in their type restriction."
  (cond ((eq x y) t)
	((characterp x) (and (characterp y) (char-equal x y)))
	((numberp x) (and (numberp y) (= x y)))
	((consp x)
	 (and (consp y)
	      (equalp (car x) (car y))
	      (equalp (cdr x) (cdr y))))
	((pathnamep x)
	 (and (pathnamep y) (pathname= x y)))
	((hash-table-p x)
	 (and (hash-table-p y)
	      (hash-table-equalp x y)))
	((typep x 'instance)
	 (let* ((layout-x (%instance-layout x))
		(len (layout-length layout-x)))
	   (and (typep y 'instance)
		(eq layout-x (%instance-layout y))
		(structure-classoid-p (layout-classoid layout-x))
		(do ((i 1 (1+ i)))
		    ((= i len) t)
		  (declare (fixnum i))
		  (let ((x-el (%instance-ref x i))
			(y-el (%instance-ref y i)))
		    (unless (or (eq x-el y-el)
				(equalp x-el y-el))
		      (return nil)))))))
	((vectorp x)
	 (let ((length (length x)))
	   (and (vectorp y)
		(= length (length y))
		(dotimes (i length t)
		  (let ((x-el (aref x i))
			(y-el (aref y i)))
		    (unless (or (eq x-el y-el)
				(equalp x-el y-el))
		      (return nil)))))))
	((arrayp x)
	 (and (arrayp y)
	      (= (array-rank x) (array-rank y))
	      (dotimes (axis (array-rank x) t)
		(unless (= (array-dimension x axis)
			   (array-dimension y axis))
		  (return nil)))
	      (dotimes (index (array-total-size x) t)
		(let ((x-el (row-major-aref x index))
		      (y-el (row-major-aref y index)))
		  (unless (or (eq x-el y-el)
			      (equalp x-el y-el))
		    (return nil))))))
	(t nil)))

(/show0 "about to do test cases in pred.lisp")
#!+sb-test
(let ((test-cases `((0.0 ,(load-time-value (make-unportable-float :single-float-negative-zero)) t)
		    (0.0 1.0 nil)
		    (#c(1 0) #c(1.0 0) t)
		    (#c(1.1 0) #c(11/10 0) nil) ; due to roundoff error
		    ("Hello" "hello" t)
		    ("Hello" #(#\h #\E #\l #\l #\o) t)
		    ("Hello" "goodbye" nil))))
  (/show0 "TEST-CASES bound in pred.lisp")
  (dolist (test-case test-cases)
    (/show0 "about to do a TEST-CASE in pred.lisp")
    (destructuring-bind (x y expected-result) test-case
      (let* ((result (equalp x y))
	     (bresult (if result 1 0))
	     (expected-bresult (if expected-result 1 0)))
	(unless (= bresult expected-bresult)
	  (/show0 "failing test in pred.lisp")
	  (error "failed test (EQUALP ~S ~S)" x y))))))
(/show0 "done with test cases in pred.lisp")
