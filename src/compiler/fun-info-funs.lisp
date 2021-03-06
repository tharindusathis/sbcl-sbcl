;;;; functions which have a build order dependency on FUN-INFO
;;;; (because ANSI allows xc host structure slot setters to be
;;;; implemented as SETF expanders instead of SETF functions, so we
;;;; can't safely forward-reference them) and so have to be defined
;;;; physically late instead of in a more logical place

(in-package "SB!C")

(defun %def-reffer (name offset lowtag)
  (let ((fun-info (fun-info-or-lose name)))
    (setf (fun-info-ir2-convert fun-info)
	  (lambda (node block)
	    (ir2-convert-reffer node block name offset lowtag))))
  name)

(defun %def-setter (name offset lowtag)
  (let ((fun-info (fun-info-or-lose name)))
    (setf (fun-info-ir2-convert fun-info)
	  (if (listp name)
	      (lambda (node block)
		(ir2-convert-setfer node block name offset lowtag))
	      (lambda (node block)
		(ir2-convert-setter node block name offset lowtag)))))
  name)

(defun %def-alloc (name words variable-length-p header lowtag inits)
  (let ((info (fun-info-or-lose name)))
    (setf (fun-info-ir2-convert info)
	  (if variable-length-p
	      (lambda (node block)
		(ir2-convert-variable-allocation node block name words header
						 lowtag inits))
	      (lambda (node block)
		(ir2-convert-fixed-allocation node block name words header
					      lowtag inits)))))
  name)
