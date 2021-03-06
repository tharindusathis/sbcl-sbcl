;;;; machine-independent aspects of the object representation

;;;; This software is part of the SBCL system. See the README file for
;;;; more information.
;;;;
;;;; This software is derived from the CMU CL system, which was
;;;; written at Carnegie Mellon University and released into the
;;;; public domain. The software is in the public domain and is
;;;; provided with absolutely no warranty. See the COPYING and CREDITS
;;;; files for more information.

(in-package "SB!VM")

;;;; KLUDGE: The primitive objects here may look like self-contained
;;;; definitions, but in general they're not. In particular, if you
;;;; try to add a slot to them, beware of the following:
;;;;   * (mysterious crashes which occur after changing the length
;;;;     of SIMPLE-FUN, just adding a new slot not even doing anything
;;;;     with it, still dunno why)
;;;;   * The GC scavenging code (and for all I know other GC code too)
;;;;     is not automatically generated from these layouts, but instead
;;;;     was hand-written to correspond to them. The offsets are
;;;;     automatically propagated into the GC scavenging code, but the
;;;;     existence of slots, and whether they should be scavenged, is
;;;;     not automatically propagated. Thus e.g. if you add a
;;;;     SIMPLE-FUN-DEBUG-INFO slot holding a tagged object which needs
;;;;     to be GCed, you need to tweak scav_code_header() and
;;;;     verify_space() in gencgc.c, and the corresponding code in gc.c.
;;;;   * The src/runtime/print.c code (used by LDB) is implemented
;;;;     using hand-written lists of slot names, which aren't automatically
;;;;     generated from the code in this file.
;;;;   * Various code (e.g. STATIC-FSET in genesis.lisp) is hard-wired
;;;;     to know the name of the last slot of the object the code works
;;;;     with, and implicitly to know that the last slot is special (being
;;;;     the beginning of an arbitrary-length sequence of bytes following
;;;;     the fixed-layout slots).
;;;; -- WHN 2001-12-29

;;;; the primitive objects themselves

(define-primitive-object (cons :lowtag list-pointer-lowtag
			       :alloc-trans cons)
  (car :ref-trans car :set-trans sb!c::%rplaca :init :arg)
  (cdr :ref-trans cdr :set-trans sb!c::%rplacd :init :arg))

(define-primitive-object (instance :lowtag instance-pointer-lowtag
				   :widetag instance-header-widetag
				   :alloc-trans %make-instance)
  (slots :rest-p t))

(define-primitive-object (bignum :lowtag other-pointer-lowtag
				 :widetag bignum-widetag
				 :alloc-trans sb!bignum::%allocate-bignum)
  (digits :rest-p t :c-type "long"))

(define-primitive-object (ratio :type ratio
				:lowtag other-pointer-lowtag
				:widetag ratio-widetag
				:alloc-trans %make-ratio)
  (numerator :type integer
	     :ref-known (flushable movable)
	     :ref-trans %numerator
	     :init :arg)
  (denominator :type integer
	       :ref-known (flushable movable)
	       :ref-trans %denominator
	       :init :arg))

(define-primitive-object (single-float :lowtag other-pointer-lowtag
				       :widetag single-float-widetag)
  (value :c-type "float"))

(define-primitive-object (double-float :lowtag other-pointer-lowtag
				       :widetag double-float-widetag)
  #!+#.(cl:if (cl:= 32 sb!vm:n-word-bits) '(and) '(or)) (filler)
  (value :c-type "double"
         :length
         #!+#.(cl:if (cl:= 64 sb!vm:n-word-bits) '(and) '(or)) 1
         #!+#.(cl:if (cl:= 32 sb!vm:n-word-bits) '(and) '(or)) 2))

#!+long-float
(define-primitive-object (long-float :lowtag other-pointer-lowtag
				     :widetag long-float-widetag)
  #!+sparc (filler)
  (value :c-type "long double" :length #!+x86 3 #!+sparc 4))

(define-primitive-object (complex :type complex
				  :lowtag other-pointer-lowtag
				  :widetag complex-widetag
				  :alloc-trans %make-complex)
  (real :type real
	:ref-known (flushable movable)
	:ref-trans %realpart
	:init :arg)
  (imag :type real
	:ref-known (flushable movable)
	:ref-trans %imagpart
	:init :arg))

(define-primitive-object (array :lowtag other-pointer-lowtag
				:widetag t)
  ;; FILL-POINTER of an ARRAY is in the same place as LENGTH of a
  ;; VECTOR -- see SHRINK-VECTOR.
  (fill-pointer :type index
		:ref-trans %array-fill-pointer
		:ref-known (flushable foldable)
		:set-trans (setf %array-fill-pointer)
		:set-known (unsafe))
  (fill-pointer-p :type (member t nil)
		  :ref-trans %array-fill-pointer-p
		  :ref-known (flushable foldable)
		  :set-trans (setf %array-fill-pointer-p)
		  :set-known (unsafe))
  (elements :type index
	    :ref-trans %array-available-elements
	    :ref-known (flushable foldable)
	    :set-trans (setf %array-available-elements)
	    :set-known (unsafe))
  (data :type array
	:ref-trans %array-data-vector
	:ref-known (flushable foldable)
	:set-trans (setf %array-data-vector)
	:set-known (unsafe))
  (displacement :type (or index null)
		:ref-trans %array-displacement
		:ref-known (flushable foldable)
		:set-trans (setf %array-displacement)
		:set-known (unsafe))
  (displaced-p :type (member t nil)
	       :ref-trans %array-displaced-p
	       :ref-known (flushable foldable)
	       :set-trans (setf %array-displaced-p)
	       :set-known (unsafe))
  (dimensions :rest-p t))

(define-primitive-object (vector :type vector
				 :lowtag other-pointer-lowtag
				 :widetag t)
  ;; FILL-POINTER of an ARRAY is in the same place as LENGTH of a
  ;; VECTOR -- see SHRINK-VECTOR.
  (length :ref-trans sb!c::vector-length
	  :type index)
  (data :rest-p t :c-type "unsigned long"))

(define-primitive-object (code :type code-component
			       :lowtag other-pointer-lowtag
			       :widetag t)
  (code-size :type index
	     :ref-known (flushable movable)
	     :ref-trans %code-code-size)
  (entry-points :type (or function null)
		:ref-known (flushable)
		:ref-trans %code-entry-points
		:set-known (unsafe)
		:set-trans (setf %code-entry-points))
  (debug-info :type t
	      :ref-known (flushable)
	      :ref-trans %code-debug-info
	      :set-known (unsafe)
	      :set-trans (setf %code-debug-info))
  (trace-table-offset)
  (constants :rest-p t))

(define-primitive-object (fdefn :type fdefn
				:lowtag other-pointer-lowtag
				:widetag fdefn-widetag)
  (name :ref-trans fdefn-name)
  (fun :type (or function null) :ref-trans fdefn-fun)
  (raw-addr :c-type "char *"))

;;; a simple function (as opposed to hairier things like closures
;;; which are also subtypes of Common Lisp's FUNCTION type)
(define-primitive-object (simple-fun :type function
				     :lowtag fun-pointer-lowtag
				     :widetag simple-fun-header-widetag)
  #!-(or x86 x86-64) (self :ref-trans %simple-fun-self
	       :set-trans (setf %simple-fun-self))
  #!+(or x86 x86-64) (self
	  ;; KLUDGE: There's no :SET-KNOWN, :SET-TRANS, :REF-KNOWN, or
	  ;; :REF-TRANS here in this case. Instead, there's separate
	  ;; DEFKNOWN/DEFINE-VOP/DEFTRANSFORM stuff in
	  ;; compiler/x86/system.lisp to define and declare them by
	  ;; hand. I don't know why this is, but that's (basically)
	  ;; the way it was done in CMU CL, and it works. (It's not
	  ;; exactly the same way it was done in CMU CL in that CMU
	  ;; CL's allows duplicate DEFKNOWNs, blithely overwriting any
	  ;; previous data associated with the previous DEFKNOWN, and
	  ;; that property was used to mask the definitions here. In
	  ;; SBCL as of 0.6.12.64 that's not allowed -- too confusing!
	  ;; -- so we have to explicitly suppress the DEFKNOWNish
	  ;; stuff here in order to allow this old hack to work in the
	  ;; new world. -- WHN 2001-08-82
	  )
  (next :type (or function null)
	:ref-known (flushable)
	:ref-trans %simple-fun-next
	:set-known (unsafe)
	:set-trans (setf %simple-fun-next))
  (name :ref-known (flushable)
	:ref-trans %simple-fun-name
	:set-known (unsafe)
	:set-trans (setf %simple-fun-name))
  (arglist :type list
           :ref-known (flushable)
	   :ref-trans %simple-fun-arglist
	   :set-known (unsafe)
	   :set-trans (setf %simple-fun-arglist))
  (type :ref-known (flushable)
	:ref-trans %simple-fun-type
	:set-known (unsafe)
	:set-trans (setf %simple-fun-type))
  ;; the SB!C::DEBUG-FUN object corresponding to this object, or NIL for none
  #+nil ; FIXME: doesn't work (gotcha, lowly maintenoid!) See notes on bug 137.
  (debug-fun :ref-known (flushable)
             :ref-trans %simple-fun-debug-fun
             :set-known (unsafe)
             :set-trans (setf %simple-fun-debug-fun))
  (code :rest-p t :c-type "unsigned char"))

(define-primitive-object (return-pc :lowtag other-pointer-lowtag :widetag t)
  (return-point :c-type "unsigned char" :rest-p t))

(define-primitive-object (closure :lowtag fun-pointer-lowtag
				  :widetag closure-header-widetag)
  (fun :init :arg :ref-trans %closure-fun)
  (info :rest-p t))

(define-primitive-object (funcallable-instance
			  :lowtag fun-pointer-lowtag
			  :widetag funcallable-instance-header-widetag
			  :alloc-trans %make-funcallable-instance)
  #!-(or x86 x86-64)
  (fun
   :ref-known (flushable) :ref-trans %funcallable-instance-fun
   :set-known (unsafe) :set-trans (setf %funcallable-instance-fun))
  #!+(or x86 x86-64)
  (fun
   :ref-known (flushable) :ref-trans %funcallable-instance-fun
   ;; KLUDGE: There's no :SET-KNOWN or :SET-TRANS in this case.
   ;; Instead, later in compiler/x86/system.lisp there's a separate
   ;; DEFKNOWN for (SETF %FUNCALLABLE-INSTANCE-FUN), and a weird
   ;; unexplained DEFTRANSFORM from (SETF %SIMPLE-FUN-INSTANCE-FUN)
   ;; into (SETF %SIMPLE-FUN-SELF). The #!+X86 wrapped around this case
   ;; is a literal translation of the old CMU CL implementation into
   ;; the new world of sbcl-0.6.12.63, where multiple DEFKNOWNs for
   ;; the same operator cause an error (instead of silently deleting
   ;; all information associated with the old DEFKNOWN, as before).
   ;; It's definitely not very clean, with too many #!+ conditionals and
   ;; too little documentation, but I have more urgent things to
   ;; clean up right now, so I've just left it as a literal
   ;; translation without trying to fix it. -- WHN 2001-08-02
   )
  (lexenv :ref-known (flushable) :ref-trans %funcallable-instance-lexenv
	  :set-known (unsafe) :set-trans (setf %funcallable-instance-lexenv))
  (layout :init :arg
	  :ref-known (flushable) :ref-trans %funcallable-instance-layout
	  :set-known (unsafe) :set-trans (setf %funcallable-instance-layout))
  (info :rest-p t))

(define-primitive-object (value-cell :lowtag other-pointer-lowtag
				     :widetag value-cell-header-widetag
				     :alloc-trans make-value-cell)
  (value :set-trans value-cell-set
	 :set-known (unsafe)
	 :ref-trans value-cell-ref
	 :ref-known (flushable)
	 :init :arg))

(define-primitive-object (sap :lowtag other-pointer-lowtag
			      :widetag sap-widetag)
  (pointer :c-type "char *"))


(define-primitive-object (weak-pointer :type weak-pointer
				       :lowtag other-pointer-lowtag
				       :widetag weak-pointer-widetag
				       :alloc-trans make-weak-pointer)
  (value :ref-trans sb!c::%weak-pointer-value :ref-known (flushable)
	 :init :arg)
  (broken :type (member t nil)
	  :ref-trans sb!c::%weak-pointer-broken :ref-known (flushable)
	  :init :null)
  (next :c-type "struct weak_pointer *"))

;;;; other non-heap data blocks

(define-primitive-object (binding)
  value
  symbol)

(define-primitive-object (unwind-block)
  (current-uwp :c-type "struct unwind_block *")
  (current-cont :c-type "lispobj *")
  #!-(or x86 x86-64) current-code
  entry-pc)

(define-primitive-object (catch-block)
  (current-uwp :c-type "struct unwind_block *")
  (current-cont :c-type "lispobj *")
  #!-(or x86 x86-64) current-code
  entry-pc
  tag
  (previous-catch :c-type "struct catch_block *")
  size)

;;; (For an explanation of this, see the comments at the definition of
;;; KLUDGE-NONDETERMINISTIC-CATCH-BLOCK-SIZE.)
(aver (= kludge-nondeterministic-catch-block-size catch-block-size))

;;;; symbols

(define-primitive-object (symbol :lowtag other-pointer-lowtag
				 :widetag symbol-header-widetag
				 :alloc-trans make-symbol)

  ;; Beware when changing this definition.  NIL-the-symbol is defined
  ;; using this layout, and NIL-the-end-of-list-marker is the cons 
  ;; ( NIL . NIL ), living in the first two slots of NIL-the-symbol
  ;; (conses have no header).  Careful selection of lowtags ensures
  ;; that the same pointer can be used for both purposes:
  ;; OTHER-POINTER-LOWTAG is 7, LIST-POINTER-LOWTAG is 3, so if you
  ;; subtract 3 from (SB-KERNEL:GET-LISP-OBJ-ADDRESS 'NIL) you get the
  ;; first data slot, and if you subtract 7 you get a symbol header.

  ;; also the CAR of NIL-as-end-of-list
  (value :init :unbound :ref-known (flushable) :ref-trans symbol-global-value)
  ;; also the CDR of NIL-as-end-of-list.  Its reffer needs special
  ;; care for this reason, as hash values must be fixnums.
  (hash :set-trans %set-symbol-hash)

  (plist :ref-trans symbol-plist
	 :set-trans %set-symbol-plist
	 :init :null)
  (name :ref-trans symbol-name :init :arg)
  (package :ref-trans symbol-package
	   :set-trans %set-symbol-package
	   :init :null)
  #!+sb-thread (tls-index :ref-known (flushable) :ref-trans symbol-tls-index))

(define-primitive-object (complex-single-float
			  :lowtag other-pointer-lowtag
			  :widetag complex-single-float-widetag)
  (real :c-type "float")
  (imag :c-type "float"))

(define-primitive-object (complex-double-float
			  :lowtag other-pointer-lowtag
			  :widetag complex-double-float-widetag)
  #!+#.(cl:if (cl:= 32 sb!vm:n-word-bits) '(and) '(or)) (filler)
  (real :c-type "double"
        :length
        #!+#.(cl:if (cl:= 64 sb!vm:n-word-bits) '(and) '(or)) 1
        #!+#.(cl:if (cl:= 32 sb!vm:n-word-bits) '(and) '(or)) 2)
  (imag :c-type "double"
        :length
        #!+#.(cl:if (cl:= 64 sb!vm:n-word-bits) '(and) '(or)) 1
        #!+#.(cl:if (cl:= 32 sb!vm:n-word-bits) '(and) '(or)) 2))

;;; this isn't actually a lisp object at all, it's a c structure that lives
;;; in c-land.  However, we need sight of so many parts of it from Lisp that
;;; it makes sense to define it here anyway, so that the GENESIS machinery
;;; can take care of maintaining Lisp and C versions.
;;; Hence the even-fixnum lowtag just so we don't get odd(sic) numbers 
;;; added to the slot offsets
(define-primitive-object (thread :lowtag even-fixnum-lowtag)
  ;; unbound_marker is borrowed very briefly at thread startup to 
  ;; pass the address of initial-function into new_thread_trampoline 
  (unbound-marker :init :unbound) ; tls[0] = UNBOUND_MARKER_WIDETAG 
  (pid :c-type "pid_t")
  (binding-stack-start :c-type "lispobj *")
  (binding-stack-pointer :c-type "lispobj *")
  (control-stack-start :c-type "lispobj *")
  (control-stack-end :c-type "lispobj *")
  (alien-stack-start :c-type "lispobj *")
  (alien-stack-pointer :c-type "lispobj *")
  #!+gencgc (alloc-region :c-type "struct alloc_region" :length 5)
  (tls-cookie)				;  on x86, the LDT index 
  (this :c-type "struct thread *")
  (next :c-type "struct thread *")
  (state)				; running, stopping, stopped, dead
  #!+(or x86 x86-64) (pseudo-atomic-atomic)
  #!+(or x86 x86-64) (pseudo-atomic-interrupted)
  (interrupt-data :c-type "struct interrupt_data *")
  (interrupt-contexts :c-type "os_context_t *" :rest-p t))
