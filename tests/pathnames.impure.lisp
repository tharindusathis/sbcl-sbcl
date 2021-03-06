;;;; miscellaneous tests of pathname-related stuff

;;;; This file is naturally impure because we mess with
;;;; LOGICAL-PATHNAME-TRANSLATIONS.

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

(setf (logical-pathname-translations "demo0")
      '(("**;*.*.*" "/tmp/")))

;;; In case of a parse error we want to get a condition of type
;;; CL:PARSE-ERROR (or more specifically, of type
;;; SB-KERNEL:NAMESTRING-PARSE-ERROR).
(assert
  (typep (grab-condition (logical-pathname "demo0::bla;file.lisp"))
         'parse-error))

;;; some things SBCL-0.6.9 used not to parse correctly:
;;;
;;; SBCL used to throw an error saying there's no translation.
(assert (equal (namestring (translate-logical-pathname "demo0:file.lisp"))
               "/tmp/file.lisp"))
;;; We do not match a null directory to every wild path:
(assert (not (pathname-match-p "demo0:file.lisp"
                               (logical-pathname "demo0:tmp;**;*.*.*"))))
;;; Remove "**" from our resulting pathname when the source-dir is NIL:
(setf (logical-pathname-translations "demo1")
      '(("**;*.*.*" "/tmp/**/*.*") (";**;*.*.*" "/tmp/rel/**/*.*")))
(assert (not (equal (namestring (translate-logical-pathname "demo1:foo.lisp"))
                    "/tmp/**/foo.lisp")))
;;; That should be correct:
(assert (equal (namestring (translate-logical-pathname "demo1:foo.lisp"))
               "/tmp/foo.lisp"))
;;; Check for absolute/relative path confusion:
(assert (not (equal (namestring (translate-logical-pathname "demo1:;foo.lisp"))
                     "tmp/rel/foo.lisp")))
(assert (equal (namestring (translate-logical-pathname "demo1:;foo.lisp"))
               "/tmp/rel/foo.lisp"))
                     
;;; Under SBCL: new function #'UNPARSE-ENOUGH-NAMESTRING, to
;;; handle the following case exactly (otherwise we get an error:
;;; "#'IDENTITY CALLED WITH 2 ARGS."
(setf (logical-pathname-translations "demo2")
        '(("test;**;*.*" "/tmp/demo2/test")))
(enough-namestring "demo2:test;foo.lisp")

;;; When a pathname comes from a logical host, it should be in upper
;;; case. (This doesn't seem to be specifically required in the ANSI
;;; spec, but it's left up to the implementors, and the arguments made
;;; in the cleanup issue PATHNAME-LOGICAL:ADD seem to be a pretty
;;; compelling reason for the implementors to choose case
;;; insensitivity and a canonical case.)
(setf (logical-pathname-translations "FOO") 
      '(("**;*.*.*" "/full/path/to/foo/**/*.*")))
(let* ((pn1 (make-pathname :host "FOO" :directory "etc" :name "INETD" 
                           :type "conf"))
       (pn2 (make-pathname :host "foo" :directory "ETC" :name "inetd" 
                           :type "CONF"))
       (pn3 (read-from-string (prin1-to-string pn1))))
  (assert (equal pn1 pn2))
  (assert (equal pn1 pn3)))

;;; In addition to the upper-case constraint above, if the logical-pathname
;;; contains a string component in e.g. the directory, name and type slot,
;;; these should be valid "WORDS", according to CLHS 19.3.1.
;;; FIXME: currently SBCL throws NAMESTRING-PARSE-ERROR: should this be
;;; a TYPE-ERROR?

(locally
  ;; MAKE-PATHNAME is UNSAFELY-FLUSHABLE
  (declare (optimize safety))
  
  (assert (not (ignore-errors
		(make-pathname :host "FOO" :directory "!bla" :name "bar"))))
  
  ;; error: name-component not valid
  (assert (not (ignore-errors
		(make-pathname :host "FOO" :directory "bla" :name "!bar"))))
  
  ;; error: type-component not valid.
  (assert (not (ignore-errors
		(make-pathname :host "FOO" :directory "bla" :name "bar"
			       :type "&baz")))))

;;; We may need to parse the host as a LOGICAL-NAMESTRING HOST. The
;;; HOST in PARSE-NAMESTRING can be either a string or :UNSPECIFIC
;;; without actually requiring the system to signal an error (apart
;;; from host mismatches).
(assert (equal (namestring (parse-namestring "" "FOO")) "FOO:"))
(assert (equal (namestring (parse-namestring "" :unspecific)) ""))

;;; The third would work if the call were (and it should continue to
;;; work ...)
(parse-namestring ""
                  (pathname-host
                   (translate-logical-pathname
                    "FOO:")))

;;; ANSI says PARSE-NAMESTRING returns TYPE-ERROR on host mismatch.
(let ((cond (grab-condition (parse-namestring "foo:jeamland" "demo2"))))
  (assert (typep cond 'type-error)))

;;; turning one logical pathname into another:
(setf (logical-pathname-translations "foo")
       '(("todemo;*.*.*" "demo0:*.*.*")))
(assert (equal (namestring (translate-logical-pathname "foo:todemo;x.y"))
               (namestring (translate-logical-pathname "demo0:x.y"))))

;;; ANSI, in its wisdom, specifies that it's an error (specifically a
;;; TYPE-ERROR) to query the system about the translations of a string
;;; which doesn't have any translations. It's not clear why we don't
;;; just return NIL in that case, but they make the rules..
(let ((cond (grab-condition (logical-pathname-translations "unregistered-host"))))
  (assert (typep cond 'type-error)))

(assert (not (string-equal (host-namestring (parse-namestring "OTHER-HOST:ILLEGAL/LPN")) "OTHER-HOST")))
(assert (string-equal (pathname-name (parse-namestring "OTHER-HOST:ILLEGAL/LPN")) "LPN"))

;;; FIXME: A comment on this section up to sbcl-0.6.11.30 or so said
;;;   examples from CLHS: Section 19.4, LOGICAL-PATHNAME-TRANSLATIONS
;;;   (sometimes converted to the Un*x way of things)
;;; but when I looked it up I didn't see the connection. Presumably
;;; there's some code in this section which should be attributed
;;; to something in the ANSI spec, but I don't know what code it is
;;; or what section of the specification has the related code.
(setf (logical-pathname-translations "test0")
        '(("**;*.*.*"              "/library/foo/**/")))
(assert (equal (namestring (translate-logical-pathname
                            "test0:foo;bar;baz;mum.quux"))
               "/library/foo/foo/bar/baz/mum.quux"))
(setf (logical-pathname-translations "prog")
        '(("RELEASED;*.*.*"        "MY-UNIX:/sys/bin/my-prog/")
          ("RELEASED;*;*.*.*"      "MY-UNIX:/sys/bin/my-prog/*/")
          ("EXPERIMENTAL;*.*.*"    "MY-UNIX:/usr/Joe/development/prog/")
          ("EXPERIMENTAL;*;*.*.*"  "MY-UNIX:/usr/Joe/development/prog/*/")))
(setf (logical-pathname-translations "prog")
        '(("CODE;*.*.*"             "/lib/prog/")))
(assert (equal (namestring (translate-logical-pathname
                            "prog:code;documentation.lisp"))
               "/lib/prog/documentation.lisp"))
(setf (logical-pathname-translations "prog")
        '(("CODE;DOCUMENTATION.*.*" "/lib/prog/docum.*")
          ("CODE;*.*.*"             "/lib/prog/")))
(assert (equal (namestring (translate-logical-pathname
                            "prog:code;documentation.lisp"))
               "/lib/prog/docum.lisp"))

;;; ANSI section 19.3.1.1.5 specifies that translation to a filesystem
;;; which doesn't have versions should ignore the version slot. CMU CL
;;; didn't ignore this as it should, but we do.
(assert (equal (namestring (translate-logical-pathname
                            "test0:foo;bar;baz;mum.quux.3"))
               "/library/foo/foo/bar/baz/mum.quux"))

;;;; MERGE-PATHNAME tests
;;;;
;;;; There are some things we don't bother testing, just because they're
;;;; not meaningful on the underlying filesystem anyway.
;;;;
;;;; Mostly that means that we don't do devices, we don't do versions
;;;; except minimally in LPNs (they get lost in the translation to
;;;; physical hosts, so it's not much of an issue), and we don't do
;;;; hosts except for LPN hosts
;;;;
;;;; Although these tests could conceivably be useful in principle for
;;;; other implementations, they depend quite heavily on the rules for
;;;; namestring parsing, which are implementation-specific. So, success
;;;; or failure in these tests doesn't tell you anything about
;;;; ANSI-compliance unless your PARSE-NAMESTRING works like ours.

;;; Needs to be done at compile time, so that the #p"" read-macro
;;; correctly parses things as logical pathnames. This is not a
;;; problem as was, as this is an impure file and so gets loaded in,
;;; but just for future proofing...
(eval-when (:compile-toplevel :load-toplevel :execute)
  (setf (logical-pathname-translations "scratch")
        '(("**;*.*.*" "/usr/local/doc/**/*"))))

(loop for (expected-result . params) in
      `(;; trivial merge
        (#P"/usr/local/doc/foo" #p"foo" #p"/usr/local/doc/")
        ;; If pathname does not specify a host, device, directory,
        ;; name, or type, each such component is copied from
        ;; default-pathname.
        ;; 1) no name, no type
        (#p"/supplied-dir/name.type" #p"/supplied-dir/" #p"/dir/name.type")
        ;; 2) no directory, no type
        (#p"/dir/supplied-name.type" #p"supplied-name" #p"/dir/name.type")
        ;; 3) no name, no dir (must use make-pathname as ".foo" is parsed
        ;; as a name)
        (#p"/dir/name.supplied-type"
         ,(make-pathname :type "supplied-type")
         #p"/dir/name.type")
        ;; If (pathname-directory pathname) is a list whose car is
        ;; :relative, and (pathname-directory default-pathname) is a
        ;; list, then the merged directory is [...]
        (#p"/aaa/bbb/ccc/ddd/qqq/www" #p"qqq/www" #p"/aaa/bbb/ccc/ddd/eee")
        ;; except that if the resulting list contains a string or
        ;; :wild immediately followed by :back, both of them are
        ;; removed.
        (#P"/aaa/bbb/ccc/blah/eee"
         ;; "../" in a namestring is parsed as :up not :back, so make-pathname
         ,(make-pathname :directory '(:relative :back "blah"))
         #p"/aaa/bbb/ccc/ddd/eee")
        ;; If (pathname-directory default-pathname) is not a list or
        ;; (pathname-directory pathname) is not a list whose car is
        ;; :relative, the merged directory is (or (pathname-directory
        ;; pathname) (pathname-directory default-pathname))
        (#P"/absolute/path/name.type"
         #p"/absolute/path/name"
         #p"/dir/default-name.type")
        ;; === logical pathnames ===
        ;; recognizes a logical pathname namestring when
        ;; default-pathname is a logical pathname
        ;; FIXME: 0.6.12.23 fails this one.
	;;
	;; And, as it happens, it's right to fail it. Because
	;; #p"name1" is read in with the ambient *d-p-d* value, which
	;; has a physical (Unix) host; therefore, the host of the
	;; default-pathname argument to merge-pathnames is
	;; irrelevant. The result is (correctly) different if
	;; '#p"name1"' is replaced by "name1", below, though it's
	;; still not what one might expect... -- CSR, 2002-05-09
        #+nil (#P"scratch:foo;name1" #p"name1" #p"scratch:foo;")
        ;; or when the namestring begins with the name of a defined
        ;; logical host followed by a colon [I assume that refers to pathname
        ;; rather than default-pathname]
        (#p"SCRATCH:FOO;NAME2" #p"scratch:;name2" #p"scratch:foo;")
        ;; conduct the previous set of tests again, with a lpn first argument
        (#P"SCRATCH:USR;LOCAL;DOC;FOO" #p"scratch:;foo" #p"/usr/local/doc/")
        (#p"SCRATCH:SUPPLIED-DIR;NAME.TYPE"
	 #p"scratch:supplied-dir;"
	 #p"/dir/name.type")
        (#p"SCRATCH:DIR;SUPPLIED-NAME.TYPE"
	 #p"scratch:;supplied-name"
	 #p"/dir/name.type")
        (#p"SCRATCH:DIR;NAME.SUPPLIED-TYPE"
         ,(make-pathname :host "scratch" :type "supplied-type")
	 #p"/dir/name.type")
        (#p"SCRATCH:AAA;BBB;CCC;DDD;FOO;BAR"
         ,(make-pathname :host "scratch"
			 :directory '(:relative "foo")
			 :name "bar")
         #p"/aaa/bbb/ccc/ddd/eee")
        (#p"SCRATCH:AAA;BBB;CCC;FOO;BAR"
         ,(make-pathname :host "scratch"
			 :directory '(:relative :back "foo")
			 :name "bar")
         #p"/aaa/bbb/ccc/ddd/eee")
        (#p"SCRATCH:ABSOLUTE;PATH;NAME.TYPE"
         #p"scratch:absolute;path;name" #p"/dir/default-name.type")

        ;; FIXME: test version handling in LPNs
        )
      do (let ((result (apply #'merge-pathnames params)))
	   (macrolet ((frob (op)
			`(assert (equal (,op result) (,op expected-result)))))
	     (frob pathname-host)
	     (frob pathname-directory)
	     (frob pathname-name)
	     (frob pathname-type))))

;;; host-namestring testing
(assert (string=
	 (namestring (parse-namestring "/foo" (host-namestring #p"/bar")))
	 "/foo"))
(assert (string=
	 (namestring (parse-namestring "FOO" (host-namestring #p"SCRATCH:BAR")))
	 "SCRATCH:FOO"))
(assert (raises-error?
	 (setf (logical-pathname-translations "")
	       (list '("**;*.*.*" "/**/*.*")))))

;;; Bug 200: translate-logical-pathname is according to the spec supposed
;;; not to give errors if asked to translate a namestring for a valid
;;; physical pathname.  Failed in 0.7.7.28 and before
(assert (string= (namestring (translate-logical-pathname "/")) "/"))


;;; Not strictly pathname logic testing, but until sbcl-0.7.6.19 we
;;; had difficulty with non-FILE-STREAM stream arguments to pathname
;;; functions (they would cause memory protection errors).  Make sure
;;; that those errors are gone:
(assert (raises-error? (pathname (make-string-input-stream "FOO"))
		       type-error))
(assert (raises-error? (merge-pathnames (make-string-output-stream))
		       type-error))

;;; ensure read/print consistency (or print-not-readable-error) on
;;; pathnames:
(let ((pathnames (list
		  (make-pathname :name "foo" :type "txt" :version :newest)
		  (make-pathname :name "foo" :type "txt" :version 1)
		  (make-pathname :name "foo" :type ".txt")
		  (make-pathname :name "foo." :type "txt")
		  (parse-namestring "SCRATCH:FOO.TXT.1")
		  (parse-namestring "SCRATCH:FOO.TXT.NEWEST")
		  (parse-namestring "SCRATCH:FOO.TXT"))))
  (dolist (p pathnames)
    (print p)
    (handler-case
	(let ((*print-readably* t))
	  (assert (equal (read-from-string (format nil "~S" p)) p)))
      (print-not-readable () nil))))

;;; BUG 330: "PARSE-NAMESTRING should accept namestrings as the
;;; default argument" ...and streams as well
(assert (equal (parse-namestring "foo" nil "/")
	       (parse-namestring "foo" nil #P"/")))
(let ((test "parse-namestring-test.tmp"))
  (unwind-protect
       (with-open-file (f test :direction :output)
	 ;; FIXME: This test is a bit flaky, since we only check that
	 ;; no error is signalled. The dilemma here is "what is the
	 ;; correct result when defaults is a _file_, not a
	 ;; directory". Currently (0.8.10.73) we get #P"foo" here (as
	 ;; opposed to eg. #P"/path/to/current/foo"), which is
	 ;; possibly mildly surprising but probably conformant.
	 (assert (parse-namestring "foo" nil f)))
    (when (probe-file test)
      (delete-file test))))

;;; ENOUGH-NAMESTRING should probably not fail when the namestring in
;;; question has a :RELATIVE pathname.
(assert (equal (enough-namestring #p"foo" #p"./") "foo"))

;;; bug reported by Artem V. Andreev: :WILD not handled in unparsing
;;; directory lists.
(assert (equal (namestring #p"/tmp/*/") "/tmp/*/"))
;;;; success
(quit :unix-status 104)
