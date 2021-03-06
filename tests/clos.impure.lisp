;;;; miscellaneous side-effectful tests of CLOS

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

(defpackage "CLOS-IMPURE"
  (:use "CL" "ASSERTOID"))
(in-package "CLOS-IMPURE")

;;; It should be possible to do DEFGENERIC and DEFMETHOD referring to
;;; structure types defined earlier in the file.
(defstruct struct-a x y)
(defstruct struct-b x y z)
(defmethod wiggle ((a struct-a))
  (+ (struct-a-x a)
     (struct-a-y a)))
(defgeneric jiggle (arg))
(defmethod jiggle ((a struct-a))
  (- (struct-a-x a)
     (struct-a-y a)))
(defmethod jiggle ((b struct-b))
  (- (struct-b-x b)
     (struct-b-y b)
     (struct-b-z b)))
(assert (= (wiggle (make-struct-a :x 6 :y 5))
           (jiggle (make-struct-b :x 19 :y 6 :z 2))))

;;; Compiling DEFGENERIC should prevent "undefined function" style
;;; warnings from code within the same file.
(defgeneric gf-defined-in-this-file (x y))
(defun function-using-gf-defined-in-this-file (x y n)
  (unless (minusp n)
    (gf-defined-in-this-file x y)))

;;; Until Martin Atzmueller ported Pierre Mai's CMU CL fixes in
;;; sbcl-0.6.12.25, the implementation of NO-APPLICABLE-METHOD was
;;; broken in such a way that the code here would signal an error.
(defgeneric zut-n-a-m (a b c))
(defmethod no-applicable-method ((zut-n-a-m (eql #'zut-n-a-m)) &rest args)
  (format t "~&No applicable method for ZUT-N-A-M ~S, yet.~%" args))
(zut-n-a-m 1 2 3)

;;; bug reported and fixed by Alexey Dejneka sbcl-devel 2001-09-10:
;;; This DEFGENERIC shouldn't cause an error.
(defgeneric ad-gf (a) (:method :around (x) x))

;;; DEFGENERIC and DEFMETHOD shouldn't accept &REST when it's not
;;; followed by a variable:
;;; e.g. (DEFMETHOD FOO ((X T) &REST) NIL) should signal an error.
(eval-when (:load-toplevel :compile-toplevel :execute)
  (defmacro expect-error (&body body)
    `(multiple-value-bind (res condition)
      (ignore-errors (progn ,@body))
      (declare (ignore res))
      (typep condition 'error))))
(assert (expect-error
         (macroexpand-1
          '(defmethod foo0 ((x t) &rest) nil))))
(assert (expect-error (defgeneric foo1 (x &rest))))
(assert (expect-error (defgeneric foo2 (x a &rest))))
(defgeneric foo3 (x &rest y))
(defmethod foo3 ((x t) &rest y) nil)
(defmethod foo4 ((x t) &rest z &key y) nil)
(defgeneric foo4 (x &rest z &key y))
(assert (expect-error (defgeneric foo5 (x &rest))))
(assert (expect-error (macroexpand-1 '(defmethod foo6 (x &rest)))))

;;; more lambda-list checking
;;;
;;; DEFGENERIC lambda lists are subject to various limitations, as per
;;; section 3.4.2 of the ANSI spec. Since Alexey Dejneka's patch for
;;; bug 191-b ca. sbcl-0.7.22, these limitations should be enforced.
(labels ((coerce-to-boolean (x)
	   (if x t nil))
	 (%like-or-dislike (expr expected-failure-p)
           (declare (type boolean expected-failure-p))
           (format t "~&trying ~S~%" expr)
           (multiple-value-bind (fun warnings-p failure-p)
	     (compile nil
		      `(lambda ()
                         ,expr))
	     (declare (ignore fun))
	     ;; In principle the constraint on WARNINGS-P below seems
	     ;; reasonable, but in practice we get warnings about
	     ;; undefined functions from the DEFGENERICs, apparently
	     ;; because the DECLAIMs which ordinarily prevent such
	     ;; warnings don't take effect because EVAL-WHEN
	     ;; (:COMPILE-TOPLEVEL) loses its magic when compiled
	     ;; within a LAMBDA. So maybe we can't test WARNINGS-P
	     ;; after all?
             ;;(unless expected-failure-p
	     ;;  (assert (not warnings-p)))
	     (assert (eq (coerce-to-boolean failure-p) expected-failure-p))))
         (like (expr)
           (%like-or-dislike expr nil))
         (dislike (expr)
           (%like-or-dislike expr t)))
  ;; basic sanity
  (dislike '(defgeneric gf-for-ll-test-0 ("a" #p"b")))
  (like    '(defgeneric gf-for-ll-test-1 ()))
  (like    '(defgeneric gf-for-ll-test-2 (x)))
  ;; forbidden default or supplied-p for &OPTIONAL or &KEY arguments
  (dislike '(defgeneric gf-for-ll-test-3 (x &optional (y 0)))) 
  (like    '(defgeneric gf-for-ll-test-4 (x &optional y))) 
  (dislike '(defgeneric gf-for-ll-test-5 (x y &key (z :z z-p)))) 
  (like    '(defgeneric gf-for-ll-test-6 (x y &key z)))
  (dislike '(defgeneric gf-for-ll-test-7 (x &optional (y 0) &key z))) 
  (like    '(defgeneric gf-for-ll-test-8 (x &optional y &key z))) 
  (dislike '(defgeneric gf-for-ll-test-9 (x &optional y &key (z :z)))) 
  (like    '(defgeneric gf-for-ll-test-10 (x &optional y &key z))) 
  (dislike '(defgeneric gf-for-ll-test-11 (&optional &key (k :k k-p))))
  (like    '(defgeneric gf-for-ll-test-12 (&optional &key k)))
  ;; forbidden &AUX
  (dislike '(defgeneric gf-for-ll-test-13 (x y z &optional a &aux g h)))
  (like    '(defgeneric gf-for-ll-test-14 (x y z &optional a)))
  (dislike '(defgeneric gf-for-ll-test-bare-aux-1 (x &aux)))
  (like    '(defgeneric gf-for-ll-test-bare-aux-2 (x)))
  ;; also can't use bogoDEFMETHODish type-qualifier-ish decorations
  ;; on required arguments
  (dislike '(defgeneric gf-for-11-test-15 ((arg t))))
  (like '(defgeneric gf-for-11-test-16 (arg))))

;;; structure-class tests setup
(defclass structure-class-foo1 () () (:metaclass cl:structure-class))
(defclass structure-class-foo2 (structure-class-foo1)
  () (:metaclass cl:structure-class))

;;; standard-class tests setup
(defclass standard-class-foo1 () () (:metaclass cl:standard-class))
(defclass standard-class-foo2 (standard-class-foo1)
  () (:metaclass cl:standard-class))

(assert (typep (class-of (make-instance 'structure-class-foo1))
               'structure-class))
(assert (typep (make-instance 'structure-class-foo1) 'structure-class-foo1))
(assert (typep (make-instance 'standard-class-foo1) 'standard-class-foo1))

;;; DEFGENERIC's blow-away-old-methods behavior is specified to have
;;; special hacks to distinguish between defined-with-DEFGENERIC-:METHOD
;;; methods and defined-with-DEFMETHOD methods, so that reLOADing
;;; DEFGENERIC-containing files does the right thing instead of 
;;; randomly slicing your generic functions. (APD made this work
;;; in sbcl-0.7.0.2.)
(defgeneric born-to-be-redefined (x)
  (:method ((x integer))
    'integer))
(defmethod born-to-be-redefined ((x real))
  'real)
(assert (eq (born-to-be-redefined 1) 'integer))
(defgeneric born-to-be-redefined (x))
(assert (eq (born-to-be-redefined 1) 'real)) ; failed until sbcl-0.7.0.2
(defgeneric born-to-be-redefined (x)
  (:method ((x integer))
    'integer))
(defmethod born-to-be-redefined ((x integer))
  'int)
(assert (eq (born-to-be-redefined 1) 'int))
(defgeneric born-to-be-redefined (x))
(assert (eq (born-to-be-redefined 1) 'int))

;;; In the removal of ITERATE from SB-PCL, a bug was introduced
;;; preventing forward-references and also change-class (which
;;; forward-references used interally) from working properly.  One
;;; symptom was reported by Brian Spilsbury (sbcl-devel 2002-04-08),
;;; and another on IRC by Dan Barlow simultaneously.  Better check
;;; that it doesn't happen again.
;;;
;;; First, the forward references:
(defclass forward-ref-a (forward-ref-b) ())
(defclass forward-ref-b () ())
;;; (a couple more complicated examples found by Paul Dietz' test
;;; suite):
(defclass forward-ref-c1 (forward-ref-c2) ())
(defclass forward-ref-c2 (forward-ref-c3) ())

(defclass forward-ref-d1 (forward-ref-d2 forward-ref-d3) ())
(defclass forward-ref-d2 (forward-ref-d4 forward-ref-d5) ())

;;; Then change-class
(defclass class-with-slots ()
  ((a-slot :initarg :a-slot :accessor a-slot)
   (b-slot :initarg :b-slot :accessor b-slot)
   (c-slot :initarg :c-slot :accessor c-slot)))

(let ((foo (make-instance 'class-with-slots
			  :a-slot 1
			  :b-slot 2
			  :c-slot 3)))
  (let ((bar (change-class foo 'class-with-slots)))
    (assert (= (a-slot bar) 1))
    (assert (= (b-slot bar) 2))
    (assert (= (c-slot bar) 3))))

;;; some more CHANGE-CLASS testing, now that we have an ANSI-compliant
;;; version (thanks to Espen Johnsen)
(defclass from-class ()
  ((foo :initarg :foo :accessor foo)))
(defclass to-class ()
  ((foo :initarg :foo :accessor foo)
   (bar :initarg :bar :accessor bar)))
(let* ((from (make-instance 'from-class :foo 1))
       (to (change-class from 'to-class :bar 2)))
  (assert (= (foo to) 1))
  (assert (= (bar to) 2)))

;;; Until Pierre Mai's patch (sbcl-devel 2002-06-18, merged in
;;; sbcl-0.7.4.39) the :MOST-SPECIFIC-LAST option had no effect.
(defgeneric bug180 (x)
  (:method-combination list :most-specific-last))
(defmethod bug180 list ((x number))
  'number)
(defmethod bug180 list ((x fixnum))
  'fixnum)
(assert (equal (bug180 14) '(number fixnum)))

;;; printing a structure class should not loop indefinitely (or cause
;;; a stack overflow):
(defclass test-printing-structure-class ()
  ((slot :initarg :slot))
  (:metaclass structure-class))
(print (make-instance 'test-printing-structure-class :slot 2))

;;; structure-classes should behave nicely when subclassed
(defclass super-structure ()
  ((a :initarg :a :accessor a-accessor)
   (b :initform 2 :reader b-reader))
  (:metaclass structure-class))
(defclass sub-structure (super-structure)
  ((c :initarg :c :writer c-writer :accessor c-accessor))
  (:metaclass structure-class))
(let ((foo (make-instance 'sub-structure :a 1 :c 3)))
  (assert (= (a-accessor foo) 1))
  (assert (= (b-reader foo) 2))
  (assert (= (c-accessor foo) 3))
  (setf (a-accessor foo) 4)
  (c-writer 5 foo)
  (assert (= (a-accessor foo) 4))
  (assert (= (c-accessor foo) 5)))

;;; At least as of sbcl-0.7.4, PCL has code to support a special
;;; encoding of effective method functions for slot accessors as
;;; FIXNUMs. Given this special casing, it'd be easy for slot accessor
;;; functions to get broken in special ways even though ordinary
;;; generic functions work. As of sbcl-0.7.4 we didn't have any tests
;;; for that possibility. Now we have a few tests:
(defclass fish ()
  ((fin :reader ffin :writer ffin!)
   (tail :reader ftail :writer ftail!)))
(defvar *fish* (make-instance 'fish))
(ffin! 'triangular-fin *fish*)
(defclass cod (fish) ())
(defvar *cod* (make-instance 'cod))
(defparameter *clos-dispatch-side-fx* (make-array 0 :fill-pointer 0))
(defmethod ffin! (new-fin (cod cod))
  (format t "~&about to set ~S fin to ~S~%" cod new-fin)
  (vector-push-extend '(cod) *clos-dispatch-side-fx*)
  (prog1
      (call-next-method)
    (format t "~&done setting ~S fin to ~S~%" cod new-fin)))
(defmethod ffin! :before (new-fin (cod cod))
  (vector-push-extend '(:before cod) *clos-dispatch-side-fx*)
  (format t "~&exploring the CLOS dispatch zoo with COD fins~%"))
(ffin! 'almost-triang-fin *cod*)
(assert (eq (ffin *cod*) 'almost-triang-fin))
(assert (equalp #((:before cod) (cod)) *clos-dispatch-side-fx*))

;;; Until sbcl-0.7.6.21, the long form of DEFINE-METHOD-COMBINATION
;;; ignored its options; Gerd Moellmann found and fixed the problem
;;; for cmucl (cmucl-imp 2002-06-18).
(define-method-combination test-mc (x)
  ;; X above being a method-group-specifier
  ((primary () :required t))
  `(call-method ,(first primary)))

(defgeneric gf (obj)
  (:method-combination test-mc 1))

(defmethod gf (obj)
  obj)

;;; Until sbcl-0.7.7.20, some conditions weren't being signalled, and
;;; some others were of the wrong type:
(macrolet ((assert-program-error (form)
	     `(multiple-value-bind (value error)
	          (ignore-errors ,form)
	        (unless (and (null value) (typep error 'program-error))
                  (error "~S failed: ~S, ~S" ',form value error)))))
  (assert-program-error (defclass foo001 () (a b a)))
  (assert-program-error (defclass foo002 () 
			  (a b) 
			  (:default-initargs x 'a x 'b)))
  (assert-program-error (defclass foo003 ()
			  ((a :allocation :class :allocation :class))))
  (assert-program-error (defclass foo004 ()
			  ((a :silly t))))
  ;; and some more, found by Wolfhard Buss and fixed for cmucl by Gerd
  ;; Moellmann in sbcl-0.7.8.x:
  (assert-program-error (progn
			  (defmethod odd-key-args-checking (&key (key 42)) key)
			  (odd-key-args-checking 3)))
  (assert (= (odd-key-args-checking) 42))
  (assert (eq (odd-key-args-checking :key t) t))
  ;; yet some more, fixed in sbcl-0.7.9.xx
  (assert-program-error (defclass foo005 ()
			  (:metaclass sb-pcl::funcallable-standard-class)
			  (:metaclass 1)))
  (assert-program-error (defclass foo006 ()
			  ((a :reader (setf a)))))
  (assert-program-error (defclass foo007 ()
			  ((a :initarg 1))))
  (assert-program-error (defclass foo008 ()
			  (a :initarg :a)
			  (:default-initargs :a 1)
			  (:default-initargs :a 2)))
  ;; and also BUG 47d, fixed in sbcl-0.8alpha.0.26
  (assert-program-error (defgeneric if (x)))
  ;; DEFCLASS should detect an error if slot names aren't suitable as
  ;; variable names:
  (assert-program-error (defclass foo009 ()
			  ((:a :initarg :a))))
  (assert-program-error (defclass foo010 ()
			  (("a" :initarg :a))))
  (assert-program-error (defclass foo011 ()
			  ((#1a() :initarg :a))))
  (assert-program-error (defclass foo012 ()
			  ((t :initarg :t))))
  (assert-program-error (defclass foo013 () ("a")))
  ;; specialized lambda lists have certain restrictions on ordering,
  ;; repeating keywords, and the like:
  (assert-program-error (defmethod foo014 ((foo t) &rest) nil))
  (assert-program-error (defmethod foo015 ((foo t) &rest x y) nil))
  (assert-program-error (defmethod foo016 ((foo t) &allow-other-keys) nil))
  (assert-program-error (defmethod foo017 ((foo t)
					   &optional x &optional y) nil))
  (assert-program-error (defmethod foo018 ((foo t) &rest x &rest y) nil))
  (assert-program-error (defmethod foo019 ((foo t) &rest x &optional y) nil))
  (assert-program-error (defmethod foo020 ((foo t) &key x &optional y) nil))
  (assert-program-error (defmethod foo021 ((foo t) &key x &rest y) nil)))

;;; DOCUMENTATION's argument-precedence-order wasn't being faithfully
;;; preserved through the bootstrap process until sbcl-0.7.8.39.
;;; (thanks to Gerd Moellmann)
(let ((answer (documentation '+ 'function)))
  (assert (stringp answer))
  (defmethod documentation ((x (eql '+)) y) "WRONG")
  (assert (string= (documentation '+ 'function) answer)))

;;; only certain declarations are permitted in DEFGENERIC
(macrolet ((assert-program-error (form)
	     `(multiple-value-bind (value error)
	          (ignore-errors ,form)
	        (assert (null value))
	        (assert (typep error 'program-error)))))
  (assert-program-error (defgeneric bogus-declaration (x)
			  (declare (special y))))
  (assert-program-error (defgeneric bogus-declaration2 (x)
			  (declare (notinline concatenate)))))
;;; CALL-NEXT-METHOD should call NO-NEXT-METHOD if there is no next
;;; method.
(defmethod no-next-method-test ((x integer)) (call-next-method))
(assert (null (ignore-errors (no-next-method-test 1))))
(defmethod no-next-method ((g (eql #'no-next-method-test)) m &rest args)
  'success)
(assert (eq (no-next-method-test 1) 'success))
(assert (null (ignore-errors (no-next-method-test 'foo))))

;;; regression test for bug 176, following a fix that seems
;;; simultaneously to fix 140 while not exposing 176 (by Gerd
;;; Moellmann, merged in sbcl-0.7.9.12).
(dotimes (i 10)
  (let ((lastname (intern (format nil "C176-~D" (1- i))))
        (name (intern (format nil "C176-~D" i))))
  (eval `(defclass ,name
             (,@(if (= i 0) nil (list lastname)))
           ()))
  (eval `(defmethod initialize-instance :after ((x ,name) &rest any)
           (declare (ignore any))))))
(defclass b176 () (aslot-176))
(defclass c176-0 (b176) ())
(assert (= 1 (setf (slot-value (make-instance 'c176-9) 'aslot-176) 1)))

;;; DEFINE-METHOD-COMBINATION was over-eager at checking for duplicate
;;; primary methods:
(define-method-combination dmc-test-mc (&optional (order :most-specific-first))
  ((around (:around))
   (primary (dmc-test-mc) :order order :required t))
   (let ((form (if (rest primary)
                   `(and ,@(mapcar #'(lambda (method)
                                       `(call-method ,method))
                                   primary))
                   `(call-method ,(first primary)))))
     (if around
         `(call-method ,(first around)
                       (,@(rest around)
                        (make-method ,form)))
         form)))

(defgeneric dmc-test-mc (&key k)
  (:method-combination dmc-test-mc))

(defmethod dmc-test-mc dmc-test-mc (&key k)
	   k)

(dmc-test-mc :k 1)
;;; While I'm at it, DEFINE-METHOD-COMBINATION is defined to return
;;; the NAME argument, not some random method object. So:
(assert (eq (define-method-combination dmc-test-return-foo)
	    'dmc-test-return-foo))
(assert (eq (define-method-combination dmc-test-return-bar :operator and)
	    'dmc-test-return-bar))
(assert (eq (define-method-combination dmc-test-return
		(&optional (order :most-specific-first))
	      ((around (:around))
	       (primary (dmc-test-return) :order order :required t))
	      (let ((form (if (rest primary)
			      `(and ,@(mapcar #'(lambda (method)
						  `(call-method ,method))
					      primary))
			      `(call-method ,(first primary)))))
		(if around
		    `(call-method ,(first around)
		      (,@(rest around)
		       (make-method ,form)))
		    form)))
	    'dmc-test-return))

;;; DEFMETHOD should signal an ERROR if an incompatible lambda list is
;;; given:
(defmethod incompatible-ll-test-1 (x) x)
(assert (raises-error? (defmethod incompatible-ll-test-1 (x y) y)))
(assert (raises-error? (defmethod incompatible-ll-test-1 (x &rest y) y)))
;;; Sneakily using a bit of MOPness to check some consistency
(assert (= (length
	    (sb-pcl:generic-function-methods #'incompatible-ll-test-1)) 1))

(defmethod incompatible-ll-test-2 (x &key bar) bar)
(assert (raises-error? (defmethod incompatible-ll-test-2 (x) x)))
(defmethod incompatible-ll-test-2 (x &rest y) y)
(assert (= (length
	    (sb-pcl:generic-function-methods #'incompatible-ll-test-2)) 1))
(defmethod incompatible-ll-test-2 ((x integer) &key bar) bar)
(assert (= (length
	    (sb-pcl:generic-function-methods #'incompatible-ll-test-2)) 2))

;;; Per Christophe, this is an illegal method call because of 7.6.5
(assert (raises-error? (incompatible-ll-test-2 t 1 2)))

(assert (eq (incompatible-ll-test-2 1 :bar 'yes) 'yes))

(defmethod incompatible-ll-test-3 ((x integer)) x)
(remove-method #'incompatible-ll-test-3
               (find-method #'incompatible-ll-test-3
                            nil
                            (list (find-class 'integer))))
(assert (raises-error? (defmethod incompatible-ll-test-3 (x y) (list x y))))


;;; Attempting to instantiate classes with forward references in their
;;; CPL should signal errors (FIXME: of what type?)
(defclass never-finished-class (this-one-unfinished-too) ())
(multiple-value-bind (result error)
    (ignore-errors (make-instance 'never-finished-class))
  (assert (null result))
  (assert (typep error 'error)))
(multiple-value-bind (result error)
    (ignore-errors (make-instance 'this-one-unfinished-too))
  (assert (null result))
  (assert (typep error 'error)))

;;; Classes with :ALLOCATION :CLASS slots should be subclassable (and
;;; weren't for a while in sbcl-0.7.9.xx)
(defclass superclass-with-slot ()
  ((a :allocation :class)))
(defclass subclass-for-class-allocation (superclass-with-slot) ())
(make-instance 'subclass-for-class-allocation)

;;; bug #136: CALL-NEXT-METHOD was being a little too lexical,
;;; resulting in failure in the following:
(defmethod call-next-method-lexical-args ((x integer))
  x)
(defmethod call-next-method-lexical-args :around ((x integer))
  (let ((x (1+ x)))
    (call-next-method)))
(assert (= (call-next-method-lexical-args 3) 3))

;;; DEFINE-METHOD-COMBINATION with arguments was hopelessly broken
;;; until 0.7.9.5x
(defvar *d-m-c-args-test* nil)
(define-method-combination progn-with-lock ()
  ((methods ()))
  (:arguments object)
  `(unwind-protect
    (progn (lock (object-lock ,object))
	   ,@(mapcar #'(lambda (method)
			 `(call-method ,method))
		     methods))
    (unlock (object-lock ,object))))
(defun object-lock (obj)
  (push "object-lock" *d-m-c-args-test*)
  obj)
(defun unlock (obj)
  (push "unlock" *d-m-c-args-test*)
  obj)
(defun lock (obj)
  (push "lock" *d-m-c-args-test*)
  obj)
(defgeneric d-m-c-args-test (x)
  (:method-combination progn-with-lock))
(defmethod d-m-c-args-test ((x symbol))
  (push "primary" *d-m-c-args-test*))
(defmethod d-m-c-args-test ((x number))
  (error "foo"))
(assert (equal (d-m-c-args-test t) '("primary" "lock" "object-lock")))
(assert (equal *d-m-c-args-test*
	       '("unlock" "object-lock" "primary" "lock" "object-lock")))
(setf *d-m-c-args-test* nil)
(ignore-errors (d-m-c-args-test 1))
(assert (equal *d-m-c-args-test*
	       '("unlock" "object-lock" "lock" "object-lock")))

;;; The walker (on which DEFMETHOD depended) didn't know how to handle
;;; SYMBOL-MACROLET properly.  In fact, as of sbcl-0.7.10.20 it still
;;; doesn't, but it does well enough to compile the following without
;;; error (the problems remain in asking for a complete macroexpansion
;;; of an arbitrary form).
(symbol-macrolet ((x 1))
  (defmethod bug222 (z)
    (macrolet ((frob (form) `(progn ,form ,x)))
      (frob (print x)))))
(assert (= (bug222 t) 1))

;;; also, a test case to guard against bogus environment hacking:
(eval-when (:compile-toplevel :load-toplevel :execute)
  (setq bug222-b 3))
;;; this should at the least compile:
(let ((bug222-b 1))
  (defmethod bug222-b (z stream)
    (macrolet ((frob (form) `(progn ,form ,bug222-b)))
      (frob (format stream "~D~%" bug222-b)))))
;;; and it would be nice (though not specified by ANSI) if the answer
;;; were as follows:
(let ((x (make-string-output-stream)))
  ;; not specified by ANSI
  (assert (= (bug222-b t x) 3))
  ;; specified.
  (assert (char= (char (get-output-stream-string x) 0) #\1)))

;;; REINITIALIZE-INSTANCE, in the ctor optimization, wasn't checking
;;; for invalid initargs where it should:
(defclass class234 () ())
(defclass subclass234 (class234) ())
(defvar *bug234* 0)
(defun bug-234 ()
  (reinitialize-instance (make-instance 'class234) :dummy 0))
(defun subbug-234 ()
  (reinitialize-instance (make-instance 'subclass234) :dummy 0))
(assert (raises-error? (bug-234) program-error))
(defmethod shared-initialize :after ((i class234) slots &key dummy)
  (incf *bug234*))
(assert (typep (subbug-234) 'subclass234))
(assert (= *bug234*
	   ;; once for MAKE-INSTANCE, once for REINITIALIZE-INSTANCE
	   2))

;;; also, some combinations of MAKE-INSTANCE and subclassing missed
;;; new methods (Gerd Moellmann sbcl-devel 2002-12-29):
(defclass class234-b1 () ())
(defclass class234-b2 (class234-b1) ())
(defvar *bug234-b* 0)
(defun bug234-b ()
  (make-instance 'class234-b2))
(compile 'bug234-b)
(bug234-b)
(assert (= *bug234-b* 0))
(defmethod initialize-instance :before ((x class234-b1) &rest args)
  (declare (ignore args))
  (incf *bug234-b*))
(bug234-b)
(assert (= *bug234-b* 1))

;;; we should be able to make classes with uninterned names:
(defclass #:class-with-uninterned-name () ())

;;; SLOT-MISSING should be called when there are missing slots.
(defclass class-with-all-slots-missing () ())
(defmethod slot-missing (class (o class-with-all-slots-missing)
			 slot-name op
			 &optional new-value)
  op)
(assert (eq (slot-value (make-instance 'class-with-all-slots-missing) 'foo)
	    'slot-value))
(assert (eq (funcall (lambda (x) (slot-value x 'bar))
		     (make-instance 'class-with-all-slots-missing))
	    'slot-value))
(assert (eq (funcall (lambda (x) (setf (slot-value x 'baz) 'baz))
		     (make-instance 'class-with-all-slots-missing))
	    ;; SLOT-MISSING's value is specified to be ignored; we
	    ;; return NEW-VALUE.
	    'baz))

;;; we should be able to specialize on anything that names a class.
(defclass name-for-class () ())
(defmethod something-that-specializes ((x name-for-class)) 1)
(setf (find-class 'other-name-for-class) (find-class 'name-for-class))
(defmethod something-that-specializes ((x other-name-for-class)) 2)
(assert (= (something-that-specializes (make-instance 'name-for-class)) 2))
(assert (= (something-that-specializes (make-instance 'other-name-for-class))
	   2))

;;; more forward referenced classes stuff
(defclass frc-1 (frc-2) ())
(assert (subtypep 'frc-1 (find-class 'frc-2)))
(assert (subtypep (find-class 'frc-1) 'frc-2))
(assert (not (subtypep (find-class 'frc-2) 'frc-1)))
(defclass frc-2 (frc-3) ((a :initarg :a)))
(assert (subtypep 'frc-1 (find-class 'frc-3)))
(defclass frc-3 () ())
(assert (typep (make-instance 'frc-1 :a 2) (find-class 'frc-1)))
(assert (typep (make-instance 'frc-2 :a 3) (find-class 'frc-2)))

;;; check that we can define classes with two slots of different names
;;; (even if it STYLE-WARNs).
(defclass odd-name-class ()
  ((name :initarg :name)
   (cl-user::name :initarg :name2)))
(let ((x (make-instance 'odd-name-class :name 1 :name2 2)))
  (assert (= (slot-value x 'name) 1))
  (assert (= (slot-value x 'cl-user::name) 2)))

;;; ALLOCATE-INSTANCE should work on structures, even if defined by
;;; DEFSTRUCT (and not DEFCLASS :METACLASS STRUCTURE-CLASS).
(defstruct allocatable-structure a)
(assert (typep (allocate-instance (find-class 'allocatable-structure))
	       'allocatable-structure))

;;; Bug found by Paul Dietz when devising CPL tests: somewhat
;;; amazingly, calls to CPL would work a couple of times, and then
;;; start returning NIL.  A fix was found (relating to the
;;; applicability of constant-dfun optimization) by Gerd Moellmann.
(defgeneric cpl (x)
  (:method-combination list)
  (:method list ((x broadcast-stream)) 'broadcast-stream)
  (:method list ((x integer)) 'integer)
  (:method list ((x number)) 'number)
  (:method list ((x stream)) 'stream)
  (:method list ((x structure-object)) 'structure-object))
(assert (equal (cpl 0) '(integer number)))
(assert (equal (cpl 0) '(integer number)))
(assert (equal (cpl 0) '(integer number)))
(assert (equal (cpl 0) '(integer number)))
(assert (equal (cpl 0) '(integer number)))
(assert (equal (cpl (make-broadcast-stream))
	       '(broadcast-stream stream structure-object)))
(assert (equal (cpl (make-broadcast-stream))
	       '(broadcast-stream stream structure-object)))
(assert (equal (cpl (make-broadcast-stream))
	       '(broadcast-stream stream structure-object)))

;;; Bug in CALL-NEXT-METHOD: assignment to the method's formal
;;; parameters shouldn't affect the arguments to the next method for a
;;; no-argument call to CALL-NEXT-METHOD
(defgeneric cnm-assignment (x)
  (:method (x) x)
  (:method ((x integer)) (setq x 3)
	   (list x (call-next-method) (call-next-method x))))
(assert (equal (cnm-assignment 1) '(3 1 3)))

;;; Bug reported by Istvan Marko 2003-07-09
(let ((class-name (gentemp)))
  (loop for i from 1 to 9
        for slot-name = (intern (format nil "X~D" i))
        for initarg-name = (intern (format nil "X~D" i) :keyword)
        collect `(,slot-name :initarg ,initarg-name) into slot-descs
        append `(,initarg-name (list 0)) into default-initargs
        finally (eval `(defclass ,class-name ()
                         (,@slot-descs)
                         (:default-initargs ,@default-initargs))))
  (let ((f (compile nil `(lambda () (make-instance ',class-name)))))
    (assert (typep (funcall f) class-name))))

;;; bug 262: DEFMETHOD failed on a generic function without a lambda
;;; list
(ensure-generic-function 'bug262)
(defmethod bug262 (x y)
  (list x y))
(assert (equal (bug262 1 2) '(1 2)))

;;; salex on #lisp 2003-10-13 reported that type declarations inside
;;; WITH-SLOTS are too hairy to be checked
(defun ensure-no-notes (form)
  (handler-case (compile nil `(lambda () ,form))
    (sb-ext:compiler-note (c)
      ;; FIXME: it would be better to check specifically for the "type
      ;; is too hairy" note
      (error c))))
(defvar *x*)
(ensure-no-notes '(with-slots (a) *x*
                   (declare (integer a))
                   a))
(ensure-no-notes '(with-slots (a) *x*
                   (declare (integer a))
                   (declare (notinline slot-value))
                   a))

;;; from CLHS 7.6.5.1
(defclass character-class () ((char :initarg :char)))
(defclass picture-class () ((glyph :initarg :glyph)))
(defclass character-picture-class (character-class picture-class) ())

(defmethod width ((c character-class) &key font) font)
(defmethod width ((p picture-class) &key pixel-size) pixel-size)

(assert (raises-error? 
	 (width (make-instance 'character-class :char #\Q) 
		:font 'baskerville :pixel-size 10)
	 program-error))
(assert (raises-error?
	 (width (make-instance 'picture-class :glyph #\Q)
		:font 'baskerville :pixel-size 10)
	 program-error))
(assert (eq (width (make-instance 'character-picture-class :char #\Q)
		   :font 'baskerville :pixel-size 10)
	    'baskerville))

;;; class redefinition shouldn't give any warnings, in the usual case
(defclass about-to-be-redefined () ((some-slot :accessor some-slot)))
(handler-bind ((warning #'error))
  (defclass about-to-be-redefined () ((some-slot :accessor some-slot))))

;;; attempts to add accessorish methods to generic functions with more
;;; complex lambda lists should fail
(defgeneric accessoroid (object &key &allow-other-keys))
(assert (raises-error?
	 (defclass accessoroid-class () ((slot :accessor accessoroid)))
	 program-error))

;;; reported by Bruno Haible sbcl-devel 2004-04-15
(defclass shared-slot-and-redefinition ()
  ((size :initarg :size :initform 1 :allocation :class)))
(let ((i (make-instance 'shared-slot-and-redefinition)))
  (defclass shared-slot-and-redefinition ()
    ((size :initarg :size :initform 2 :allocation :class)))
  (assert (= (slot-value i 'size) 1)))

;;; reported by Bruno Haible sbcl-devel 2004-04-15
(defclass superclass-born-to-be-obsoleted () (a))
(defclass subclass-born-to-be-obsoleted (superclass-born-to-be-obsoleted) ())
(defparameter *born-to-be-obsoleted*
  (make-instance 'subclass-born-to-be-obsoleted))
(defparameter *born-to-be-obsoleted-obsoleted* nil)
(defmethod update-instance-for-redefined-class
    ((o subclass-born-to-be-obsoleted) a d pl &key)
  (setf *born-to-be-obsoleted-obsoleted* t))
(make-instances-obsolete 'superclass-born-to-be-obsoleted)
(slot-boundp *born-to-be-obsoleted* 'a)
(assert *born-to-be-obsoleted-obsoleted*)

;;; additional test suggested by Bruno Haible sbcl-devel 2004-04-21
(defclass super-super-obsoleted () (a))
(defclass super-obsoleted-1 (super-super-obsoleted) ())
(defclass super-obsoleted-2 (super-super-obsoleted) ())
(defclass obsoleted (super-obsoleted-1 super-obsoleted-2) ())
(defparameter *obsoleted* (make-instance 'obsoleted))
(defparameter *obsoleted-counter* 0)
(defmethod update-instance-for-redefined-class ((o obsoleted) a d pl &key)
  (incf *obsoleted-counter*))
(make-instances-obsolete 'super-super-obsoleted)
(slot-boundp *obsoleted* 'a)
(assert (= *obsoleted-counter* 1))

;;; shared -> local slot transfers of inherited slots, reported by
;;; Bruno Haible
(let (i)
  (defclass super-with-magic-slot () 
    ((magic :initarg :size :initform 1 :allocation :class)))
  (defclass sub-of-super-with-magic-slot (super-with-magic-slot) ())
  (setq i (make-instance 'sub-of-super-with-magic-slot))
  (defclass super-with-magic-slot () 
    ((magic :initarg :size :initform 2)))
  (assert (= 1 (slot-value i 'magic))))

;;; MAKE-INSTANCES-OBSOLETE return values
(defclass one-more-to-obsolete () ())
(assert (eq 'one-more-to-obsolete 
	    (make-instances-obsolete 'one-more-to-obsolete)))
(assert (eq (find-class 'one-more-to-obsolete) 
	    (make-instances-obsolete (find-class 'one-more-to-obsolete))))

;;; Sensible error instead of a BUG. Reported by Thomas Burdick.
(multiple-value-bind (value err)
    (ignore-errors
      (defclass slot-def-with-duplicate-accessors ()
	((slot :writer get-slot :reader get-slot))))
  (assert (typep err 'error))
  (assert (not (typep err 'sb-int:bug))))

;;; BUG 321: errors in parsing DEFINE-METHOD-COMBINATION arguments
;;; lambda lists.

(define-method-combination w-args ()
  ((method-list *))
  (:arguments arg1 arg2 &aux (extra :extra))
  `(progn ,@(mapcar (lambda (method) `(call-method ,method)) method-list)))
(defgeneric mc-test-w-args (p1 p2 s)
  (:method-combination w-args)
  (:method ((p1 number) (p2 t) s)
    (vector-push-extend (list 'number p1 p2) s))
  (:method ((p1 string) (p2 t) s)
    (vector-push-extend (list 'string p1 p2) s))
  (:method ((p1 t) (p2 t) s) (vector-push-extend (list t p1 p2) s)))
(let ((v (make-array 0 :adjustable t :fill-pointer t)))
  (assert (= (mc-test-w-args 1 2 v) 1))
  (assert (equal (aref v 0) '(number 1 2)))
  (assert (equal (aref v 1) '(t 1 2))))

;;; BUG 276: declarations and mutation.
(defmethod fee ((x fixnum))
  (setq x (/ x 2))
  x)
(assert (= (fee 1) 1/2))
(defmethod fum ((x fixnum))
  (setf x (/ x 2))
  x)
(assert (= (fum 3) 3/2))
(defmethod fii ((x fixnum))
  (declare (special x))
  (setf x (/ x 2))
  x)
(assert (= (fii 1) 1/2))
(defvar *faa*)
(defmethod faa ((*faa* string-stream))
  (setq *faa* (make-broadcast-stream *faa*))
  (write-line "Break, you sucker!" *faa*)
  'ok)
(assert (eq 'ok (faa (make-string-output-stream))))

;;; Bug reported by Zach Beane; incorrect return of (function
;;; ',fun-name) in defgeneric
(assert
 (typep (funcall (compile nil
                          '(lambda () (flet ((nonsense () nil))
                                        (defgeneric nonsense ())))))
        'generic-function))

(assert
 (typep (funcall (compile nil
                          '(lambda () (flet ((nonsense-2 () nil))
                                        (defgeneric nonsense-2 ()
                                          (:method () t))))))
        'generic-function))

;;; bug reported by Bruno Haible: (setf find-class) using a
;;; forward-referenced class
(defclass fr-sub (fr-super) ())
(setf (find-class 'fr-alt) (find-class 'fr-super))
(assert (eq (find-class 'fr-alt) (find-class 'fr-super)))

;;;; success
(sb-ext:quit :unix-status 104)
