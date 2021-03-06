;;;; Linkage table specifics

;;;; This software is part of the SBCL system. See the README file for
;;;; more information.
;;;;
;;;; This software is derived from the CMU CL system, which was
;;;; written at Carnegie Mellon University and released into the
;;;; public domain. The software is in the public domain and is
;;;; provided with absolutely no warranty. See the COPYING and CREDITS
;;;; files for more information.

;;;; Linkage table itself is a mmapped memory area in C-land, which is
;;;; initialized by INIT-LINKAGE-TABLE once all shared objects have
;;;; been reopened, based on the information stored in *LINKAGE-INFO*.
;;;;
;;;; For data entries the linkage table holds the real address
;;;; of the foreign symbol, and for code the entries are jumps
;;;; to the real addresses.

(in-package "SB!IMPL")

(defvar *foreign-lock*) ; initialized in foreign-load.lisp

(define-alien-routine arch-write-linkage-table-jmp void
  (table-address system-area-pointer)
  (real-address system-area-pointer))

(define-alien-routine arch-write-linkage-table-ref void
  (table-address system-area-pointer)
  (real-address system-area-pointer))

(defvar *linkage-info* (make-hash-table :test 'equal))

(defstruct linkage-info datap address)

(defun write-linkage-table-entry (table-address real-address datap)
  (/show0 "write-linkage-table-entry")
  (let ((reloc (int-sap table-address))
	(target (int-sap real-address)))
    (if datap
	(arch-write-linkage-table-ref reloc target)
	(arch-write-linkage-table-jmp reloc target))))

;;; Add the linkage information about a foreign symbol in the
;;; persistent table, and write the linkage-table entry.
(defun link-foreign-symbol (name datap)
  (/show0 "link-foreign-symbol")
  (let ((table-address (+ (* (hash-table-count *linkage-info*)
			     sb!vm:linkage-table-entry-size)
			  sb!vm:linkage-table-space-start))
	(real-address (get-dynamic-foreign-symbol-address name)))
    (aver real-address)
    (unless (< table-address sb!vm:linkage-table-space-end)
      (error "Linkage-table full (~D entries): cannot link ~S."
             (hash-table-count *linkage-info*)
             name))
    (write-linkage-table-entry table-address real-address datap)
    (setf (gethash name *linkage-info*)
          (make-linkage-info :address table-address :datap datap))))

;;; Add a foreign linkage entry if none exists, return the address
;;; in the linkage table.
(defun ensure-foreign-symbol-linkage (name datap)
  (/show0 "ensure-foreign-symbol-linkage")
  (sb!thread:with-mutex (*foreign-lock*)
    (let ((info (or (gethash name *linkage-info*)
                    (link-foreign-symbol name datap))))
      (when info
        (linkage-info-address info)))))

;;; Update the linkage-table. Called during initialization after all
;;; shared libraries have been reopened, and after a previously loaded
;;; shared object is reloaded.
(defun update-linkage-table ()
  ;; Doesn't take care of it's own locking -- callers are responsible
  (maphash (lambda (name info)
             (let ((datap (linkage-info-datap info))
                   (table-address (linkage-info-address info))
                   (real-address (get-dynamic-foreign-symbol-address name)))
	       (aver (and table-address real-address))
	       (write-linkage-table-entry table-address
					  real-address
					  datap)))
           *linkage-info*))
