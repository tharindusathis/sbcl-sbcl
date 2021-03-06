;;;; os-independent stream functions requiring reader machinery

;;;; This software is part of the SBCL system. See the README file for
;;;; more information.
;;;;
;;;; This software is derived from the CMU CL system, which was
;;;; written at Carnegie Mellon University and released into the
;;;; public domain. The software is in the public domain and is
;;;; provided with absolutely no warranty. See the COPYING and CREDITS
;;;; files for more information.

(in-package "SB!IMPL")

;;; In the interest of ``once and only once'' this macro contains the
;;; framework necessary to implement a peek-char function, which has
;;; two special-cases (one for gray streams and one for echo streams)
;;; in addition to the normal case.
;;;
;;; All arguments are forms which will be used for a specific purpose
;;; PEEK-TYPE - the current peek-type as defined by ANSI CL
;;; EOF-VALUE - the eof-value argument to peek-char
;;; CHAR-VAR - the variable which will be used to store the current character
;;; READ-FORM - the form which will be used to read a character
;;; UNREAD-FORM - ditto for unread-char
;;; SKIPPED-CHAR-FORM - the form to execute when skipping a character
;;; EOF-DETECTED-FORM - the form to execute when EOF has been detected
;;;                     (this will default to CHAR-VAR)
(sb!xc:defmacro generalized-peeking-mechanism
    (peek-type eof-value char-var read-form unread-form
     &optional (skipped-char-form nil) (eof-detected-form nil))
  `(let ((,char-var ,read-form))
    (cond ((eql ,char-var ,eof-value) 
           ,(if eof-detected-form
                eof-detected-form
                char-var))
          ((characterp ,peek-type)
           (do ((,char-var ,char-var ,read-form))
               ((or (eql ,char-var ,eof-value) 
                    (char= ,char-var ,peek-type))
                (cond ((eql ,char-var ,eof-value)
                       ,(if eof-detected-form
                            eof-detected-form
                            char-var))
                      (t ,unread-form
                         ,char-var)))
             ,skipped-char-form))
          ((eql ,peek-type t)
           (do ((,char-var ,char-var ,read-form))
               ((or (eql ,char-var ,eof-value)
                    (not (whitespacep ,char-var)))
                (cond ((eql ,char-var ,eof-value)
                       ,(if eof-detected-form
                            eof-detected-form
                            char-var))
                      (t ,unread-form
                         ,char-var)))
             ,skipped-char-form))
          ((null ,peek-type)
           ,unread-form
           ,char-var)
          (t
           (bug "Impossible case reached in PEEK-CHAR")))))

;;; rudi (2004-08-09): There was an inline declaration for read-char,
;;; unread-char, read-byte, listen here that was removed because these
;;; functions are redefined when simple-streams are loaded.

#!-sb-fluid (declaim (inline ansi-stream-peek-char))
(defun ansi-stream-peek-char (peek-type stream eof-error-p eof-value
                              recursive-p)
  (cond ((typep stream 'echo-stream)
         (echo-misc stream
                    :peek-char
                    peek-type
                    (list eof-error-p eof-value)))
        (t
         (generalized-peeking-mechanism
          peek-type eof-value char
          (ansi-stream-read-char stream eof-error-p eof-value recursive-p)
          (ansi-stream-unread-char char stream)))))

(defun peek-char (&optional (peek-type nil)
			    (stream *standard-input*)
			    (eof-error-p t)
			    eof-value
			    recursive-p)
  (the (or character boolean) peek-type)
  (let ((stream (in-synonym-of stream)))
    (if (ansi-stream-p stream)
        (ansi-stream-peek-char peek-type stream eof-error-p eof-value
                               recursive-p)
        ;; by elimination, must be Gray streams FUNDAMENTAL-STREAM
        (generalized-peeking-mechanism
         peek-type :eof char
         (if (null peek-type)
             (stream-peek-char stream)
             (stream-read-char stream))
         (if (null peek-type)
             ()
             (stream-unread-char stream char))
         ()
         (eof-or-lose stream eof-error-p eof-value)))))

(defun echo-misc (stream operation &optional arg1 arg2)
  (let* ((in (two-way-stream-input-stream stream))
	 (out (two-way-stream-output-stream stream)))
    (case operation
      (:listen
       (or (not (null (echo-stream-unread-stuff stream)))
	   (if (ansi-stream-p in)
	       (or (/= (the fixnum (ansi-stream-in-index in))
		       +ansi-stream-in-buffer-length+)
		   (funcall (ansi-stream-misc in) in :listen))
	       (stream-misc-dispatch in :listen))))
      (:unread (push arg1 (echo-stream-unread-stuff stream)))
      (:element-type
       (let ((in-type (stream-element-type in))
	     (out-type (stream-element-type out)))
	 (if (equal in-type out-type)
	     in-type `(and ,in-type ,out-type))))
      (:close
       (set-closed-flame stream))
      (:peek-char
       ;; For the special case of peeking into an echo-stream
       ;; arg1 is PEEK-TYPE, arg2 is (EOF-ERROR-P EOF-VALUE)
       ;; returns peeked-char, eof-value, or errors end-of-file
       ;;
       ;; Note: This code could be moved into PEEK-CHAR if desired.
       ;; I am unsure whether this belongs with echo-streams because it is
       ;; echo-stream specific, or PEEK-CHAR because it is peeking code.
       ;; -- mrd 2002-11-18
       ;;
       ;; UNREAD-CHAR-P indicates whether the current character was one
       ;; that was previously unread.  In that case, we need to ensure that
       ;; the semantics for UNREAD-CHAR are held; the character should
       ;; not be echoed again.
       (let ((unread-char-p nil))
	 (flet ((outfn (c)
		  (unless unread-char-p
		    (if (ansi-stream-p out)
			(funcall (ansi-stream-out out) out c)
			;; gray-stream
			(stream-write-char out c))))
		(infn ()
		  ;; Obtain input from unread buffer or input stream,
		  ;; and set the flag appropriately.
		  (cond ((not (null (echo-stream-unread-stuff stream)))
			 (setf unread-char-p t)
			 (pop (echo-stream-unread-stuff stream)))
			(t
			 (setf unread-char-p nil)
			 (read-char in (first arg2) (second arg2))))))
	   (generalized-peeking-mechanism
	    arg1 (second arg2) char
	    (infn)
	    (unread-char char in)
	    (outfn char)))))
      (t
       (or (if (ansi-stream-p in)
	       (funcall (ansi-stream-misc in) in operation arg1 arg2)
	       (stream-misc-dispatch in operation arg1 arg2))
	   (if (ansi-stream-p out)
	       (funcall (ansi-stream-misc out) out operation arg1 arg2)
	       (stream-misc-dispatch out operation arg1 arg2)))))))

