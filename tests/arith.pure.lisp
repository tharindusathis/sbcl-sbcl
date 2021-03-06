;;;; arithmetic tests with no side effects

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

(cl:in-package :cl-user)

;;; Once upon a time, in the process of porting CMUCL's SPARC backend
;;; to SBCL, multiplications were excitingly broken.  While it's
;;; unlikely that anything with such fundamental arithmetic errors as
;;; these are going to get this far, it's probably worth checking.
(macrolet ((test (op res1 res2)
	     `(progn
	       (assert (= (,op 4 2) ,res1))
	       (assert (= (,op 2 4) ,res2))
	       (assert (= (funcall (compile nil (lambda (x y) (,op x y))) 4 2) 
			,res1))
	       (assert (= (funcall (compile nil (lambda (x y) (,op x y))) 2 4) 
			,res2)))))
  (test + 6 6)
  (test - 2 -2)
  (test * 8 8)
  (test / 2 1/2)
  (test expt 16 16))

;;; In a bug reported by Wolfhard Buss on cmucl-imp 2002-06-18 (BUG
;;; 184), sbcl didn't catch all divisions by zero, notably divisions
;;; of bignums and ratios by 0.  Fixed in sbcl-0.7.6.13.
(assert (raises-error? (/ 2/3 0) division-by-zero))
(assert (raises-error? (/ (1+ most-positive-fixnum) 0) division-by-zero))

;;; In a bug reported by Raymond Toy on cmucl-imp 2002-07-18, (COERCE
;;; <RATIONAL> '(COMPLEX FLOAT)) was failing to return a complex
;;; float; a patch was given by Wolfhard Buss cmucl-imp 2002-07-19.
(assert (= (coerce 1 '(complex float)) #c(1.0 0.0)))
(assert (= (coerce 1/2 '(complex float)) #c(0.5 0.0)))
(assert (= (coerce 1.0d0 '(complex float)) #c(1.0d0 0.0d0)))

;;; (COERCE #c(<RATIONAL> <RATIONAL>) '(complex float)) resulted in
;;; an error up to 0.8.17.31
(assert (= (coerce #c(1 2) '(complex float)) #c(1.0 2.0)))

;;; COERCE also sometimes failed to verify that a particular coercion
;;; was possible (in particular coercing rationals to bounded float
;;; types.
(assert (raises-error? (coerce 1 '(float 2.0 3.0)) type-error))
(assert (raises-error? (coerce 1 '(single-float -1.0 0.0)) type-error))
(assert (eql (coerce 1 '(single-float -1.0 2.0)) 1.0))

;;; ANSI says MIN and MAX should signal TYPE-ERROR if any argument
;;; isn't REAL. SBCL 0.7.7 didn't in the 1-arg case. (reported as a
;;; bug in CMU CL on #lisp IRC by lrasinen 2002-09-01)
(assert (null (ignore-errors (min '(1 2 3)))))
(assert (= (min -1) -1))
(assert (null (ignore-errors (min 1 #(1 2 3)))))
(assert (= (min 10 11) 10))
(assert (null (ignore-errors (min (find-package "CL") -5.0))))
(assert (= (min 5.0 -3) -3))
(assert (null (ignore-errors (max #c(4 3)))))
(assert (= (max 0) 0))
(assert (null (ignore-errors (max "MIX" 3))))
(assert (= (max -1 10.0) 10.0))
(assert (null (ignore-errors (max 3 #'max))))
(assert (= (max -3 0) 0))

;;; (CEILING x 2^k) was optimized incorrectly
(loop for divisor in '(-4 4)
      for ceiler = (compile nil `(lambda (x)
                                   (declare (fixnum x))
                                   (declare (optimize (speed 3)))
                                   (ceiling x ,divisor)))
      do (loop for i from -5 to 5
               for exact-q = (/ i divisor)
               do (multiple-value-bind (q r)
                      (funcall ceiler i)
                    (assert (= (+ (* q divisor) r) i))
                    (assert (<= exact-q q))
                    (assert (< q (1+ exact-q))))))

;;; (TRUNCATE x 2^k) was optimized incorrectly
(loop for divisor in '(-4 4)
      for truncater = (compile nil `(lambda (x)
                                      (declare (fixnum x))
                                      (declare (optimize (speed 3)))
                                      (truncate x ,divisor)))
      do (loop for i from -9 to 9
               for exact-q = (/ i divisor)
               do (multiple-value-bind (q r)
                      (funcall truncater i)
                    (assert (= (+ (* q divisor) r) i))
                    (assert (<= (abs q) (abs exact-q)))
                    (assert (< (abs exact-q) (1+ (abs q)))))))

;;; CEILING had a corner case, spotted by Paul Dietz
(assert (= (ceiling most-negative-fixnum (1+ most-positive-fixnum)) -1))

;;; give any optimizers of constant multiplication a light testing.
;;; 100 may seem low, but (a) it caught CSR's initial errors, and (b)
;;; before checking in, CSR tested with 10000.  So one hundred
;;; checkins later, we'll have doubled the coverage.
(dotimes (i 100)
  (let* ((x (random most-positive-fixnum))
	 (x2 (* x 2))
	 (x3 (* x 3)))
    (let ((fn (handler-bind ((sb-ext:compiler-note
                              (lambda (c)
                                (when (<= x3 most-positive-fixnum)
                                  (error c)))))
		(compile nil
			 `(lambda (y)
			    (declare (optimize speed) (type (integer 0 3) y))
			    (* y ,x))))))
      (unless (and (= (funcall fn 0) 0)
		   (= (funcall fn 1) x)
		   (= (funcall fn 2) x2)
		   (= (funcall fn 3) x3))
	(error "bad results for ~D" x)))))

;;; Bugs reported by Paul Dietz:

;;; (GCD 0 x) must return (abs x)
(dolist (x (list -10 (* 3 most-negative-fixnum)))
  (assert (= (gcd 0 x) (abs x))))
;;; LCM returns a non-negative number
(assert (= (lcm 4 -10) 20))
(assert (= (lcm 0 0) 0))

;;; PPC bignum arithmetic bug:
(multiple-value-bind (quo rem)
    (truncate 291351647815394962053040658028983955 10000000000000000000000000)
  (assert (= quo 29135164781))
  (assert (= rem 5394962053040658028983955)))

;;; x86 LEA bug:
(assert (= (funcall
	    (compile nil '(lambda (x) (declare (bit x)) (+ x #xf0000000)))
	    1)
	   #xf0000001))

;;; LOGBITP on bignums:
(dolist (x '(((1+ most-positive-fixnum) 1 nil)
	     ((1+ most-positive-fixnum) -1 t)
	     ((1+ most-positive-fixnum) (1+ most-positive-fixnum) nil)
	     ((1+ most-positive-fixnum) (1- most-negative-fixnum) t)
	     (1 (ash most-negative-fixnum 1) nil)
	     (#.(- sb-vm:n-word-bits sb-vm:n-lowtag-bits) most-negative-fixnum t)
	     (#.(1+ (- sb-vm:n-word-bits sb-vm:n-lowtag-bits)) (ash most-negative-fixnum 1) t)
	     (#.(+ 2 (- sb-vm:n-word-bits sb-vm:n-lowtag-bits)) (ash most-negative-fixnum 1) t)
	     (#.(+ sb-vm:n-word-bits 32) (ash most-negative-fixnum #.(+ 32 sb-vm:n-lowtag-bits 1)) nil)
	     (#.(+ sb-vm:n-word-bits 33) (ash most-negative-fixnum #.(+ 32 sb-vm:n-lowtag-bits 1)) t)))
  (destructuring-bind (index int result) x
    (assert (eq (eval `(logbitp ,index ,int)) result))))

;;; off-by-1 type inference error for %DPB and %DEPOSIT-FIELD:
(let ((f (compile nil '(lambda (b)
                        (integer-length (dpb b (byte 4 28) -1005))))))
  (assert (= (funcall f 1230070) 32)))
(let ((f (compile nil '(lambda (b)
                        (integer-length (deposit-field b (byte 4 28) -1005))))))
  (assert (= (funcall f 1230070) 32)))

;;; type inference leading to an internal compiler error:
(let ((f (compile nil '(lambda (x)
			(declare (type fixnum x))
			(ldb (byte 0 0) x)))))
  (assert (= (funcall f 1) 0))
  (assert (= (funcall f most-positive-fixnum) 0))
  (assert (= (funcall f -1) 0)))

;;; Alpha bignum arithmetic bug:
(assert (= (* 966082078641 419216044685) 404997107848943140073085))

;;; Alpha smallnum arithmetic bug:
(assert (= (ash -129876 -1026) -1))

;;; Alpha middlenum (yes, really! Affecting numbers between 2^32 and
;;; 2^64 :) arithmetic bug
(let ((fn (compile nil '(LAMBDA (A B C D)
          (DECLARE (TYPE (INTEGER -1621 -513) A)
                   (TYPE (INTEGER -3 34163) B)
                   (TYPE (INTEGER -9485132993 81272960) C)
                   (TYPE (INTEGER -255340814 519943) D)
                   (IGNORABLE A B C D)
                   (OPTIMIZE (SPEED 3) (SAFETY 1) (DEBUG 1)))
          (TRUNCATE C (MIN -100 4149605))))))
  (assert (= (funcall fn -1332 5864 -6963328729 -43789079) 69633287)))

;;; Here's another fantastic Alpha backend bug: the code to load
;;; immediate 64-bit constants into a register was wrong.
(let ((fn (compile nil '(LAMBDA (A B C D)
          (DECLARE (TYPE (INTEGER -3563 2733564) A)
                   (TYPE (INTEGER -548947 7159) B)
                   (TYPE (INTEGER -19 0) C)
                   (TYPE (INTEGER -2546009 0) D)
                   (IGNORABLE A B C D)
                   (OPTIMIZE (SPEED 3) (SAFETY 1) (DEBUG 1)))
          (CASE A
            ((89 125 16) (ASH A (MIN 18 -706)))
            (T (DPB -3 (BYTE 30 30) -1)))))))
  (assert (= (funcall fn 1227072 -529823 -18 -792831) -2147483649)))

;;; ASH of a negative bignum by a bignum count would erroneously
;;; return 0 prior to sbcl-0.8.4.4
(assert (= (ash (1- most-negative-fixnum) (1- most-negative-fixnum)) -1))

;;; Whoops.  Too much optimization in division operators for 0
;;; divisor.
(macrolet ((frob (name)
	     `(let ((fn (compile nil '(lambda (x)
				       (declare (optimize speed) (fixnum x))
				       (,name x 0)))))
	       (assert (raises-error? (funcall fn 1) division-by-zero)))))
  (frob mod)
  (frob truncate)
  (frob rem)
  (frob /)
  (frob floor)
  (frob ceiling))
