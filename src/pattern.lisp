;;;; Trying to design a DSL for small refactors

(defpackage #:breeze.pattern
  (:documentation "Pattern matching")
  (:use #:cl)
  (:export #:compile-pattern)
  (:export #:defpattern
           #:match
           #:ref
           #:term
           #:maybe
           #:*match-skip*)
  (:export #:iterate
           #:iterator-done-p
           #:iterator-value)
  (:export #:normalize-bindings))

(in-package #:breeze.pattern)

(defvar *patterns* (make-hash-table :test 'equal)
  "Stores all the patterns.")


;;; Refs and Terms

;; TODO Think about (defstruct hole ...)

;; Used to reference another pattern by name.
(defstruct (ref
            (:constructor ref (name))
            :constructor
            (:predicate refp))
  (name nil :type symbol :read-only t))

(defun ref= (a b)
  (and (refp a)
       (refp b)
       (eq (ref-name a)
           (ref-name b))))

;; Decision: I chose "term" and not "variable" to avoid clashes with
;; cl:variable
(defstruct (term
            (:constructor term (name))
            :constructor
            (:predicate termp))
  (name nil :type symbol :read-only t))

(defun term= (a b)
  (and (termp a)
       (termp b)
       (eq (term-name a)
           (term-name b))))

(defstruct (typed-term
            (:constructor typed-term (type name))
            :constructor
            :predicate
            (:include term))
  (type nil :read-only t))

(defmethod typed-term= (a b) nil)

(defmethod typed-term= ((a term) (b term))
  (term= a b))

(defmethod typed-term= ((a typed-term) (b typed-term))
  (and (eq (typed-term-name a)
           (typed-term-name b))
       (equal (typed-term-type a)
              (typed-term-type b))))



;; TODO Maybe generalize "maybe" and "zero-or-more" into "repetition"

(defstruct (maybe
            (:constructor maybe (pattern &optional name))
            :constructor
            (:predicate maybep)
            (:include term))
  (pattern nil :read-only t))

(defun maybe= (a b)
  (and (maybep a)
       (maybep b)
       (pattern= (maybe-pattern a)
                 (maybe-pattern b))
       (or (null (maybe-name a))
           (null (maybe-name b))
           (eq (maybe-name a)
               (maybe-name b)))))

(defstruct (zero-or-more
            (:constructor zero-or-more (pattern))
            :constructor
            :predicate)
  (pattern nil :read-only t))

(defun zero-or-more= (a b)
  (and (zero-or-more-p a)
       (zero-or-more-p b)
       (pattern= (zero-or-more-pattern a)
                 (zero-or-more-pattern b))))

(defstruct (alternation
            (:constructor alternation (pattern))
            :constructor
            (:predicate alternationp))
  (pattern nil :read-only t))

(defun alternation= (a b)
  (and (alternationp a)
       (alternationp b)
       (pattern= (alternation-pattern a)
                 (alternation-pattern b))))

(defmethod pattern= (a b)
  (equal a b))

(defmethod pattern= ((a vector) (b vector))
  (or (eq a b)
      (and (= (length a) (length b))
           (loop :for x :across a
                 :for y :across b
                 :always (pattern= x y)))))

(macrolet ((def (name)
             `(progn
                (defmethod pattern= ((a ,name) (b ,name))
                  (,(alexandria:symbolicate name '=) a b))
                (defmethod make-load-form ((s ,name) &optional environment)
                  (make-load-form-saving-slots s :environment environment)))))
  (def ref)
  (def term)
  (def typed-term)
  (def maybe)
  (def zero-or-more)
  (def alternation))


;;; Pattern compilation from lists and symbols to vectors and structs

(defun symbol-starts-with (symbol char)
  (and (symbolp symbol)
       (char= char (char (symbol-name symbol) 0))))

(defun term-symbol-p (x)
  (symbol-starts-with x #\?))

;; Default: leave as-is
(defmethod compile-pattern (pattern) pattern)

;; Compile symbols
(defmethod compile-pattern ((pattern symbol))
  (cond
    ((term-symbol-p pattern) (term pattern))
    (t pattern)))

;; Compile lists
(defmethod compile-pattern ((pattern cons))
  ;; Dispatch to another method that is eql-specialized on the firt
  ;; element of the list.
  (compile-compound-pattern (first pattern) pattern))

;; Default list compilation: recurse and convert to vector.
(defmethod compile-compound-pattern (token pattern)
  (map 'vector #'compile-pattern pattern))

;; Compile (:the ...)
(defmethod compile-compound-pattern ((token (eql :the)) pattern)
  ;; TODO Check length of "pattern"
  ;; TODO check if type is nil, that's very likely that's an error.
  (apply #'typed-term (rest pattern)))

;; Compile (:ref ...)
(defmethod compile-compound-pattern ((token (eql :ref)) pattern)
  ;; TODO Check length of "rest"
  (ref (second pattern)))

;; Compile (:maybe ...)
(defmethod compile-compound-pattern ((token (eql :maybe)) pattern)
  ;; TODO check the length of "pattern"
  (maybe (compile-pattern (second pattern)) (third pattern)))

;; Compile (:zero-or-more ...)
(defmethod compile-compound-pattern ((token (eql :zero-or-more)) pattern)
  (zero-or-more (compile-pattern (rest pattern))))

;; Compile (:alternation ...)
(defmethod compile-compound-pattern ((token (eql :alternation)) patterns)
  (alternation (compile-pattern (rest patterns))))


;;; Re-usable, named patterns

(defmacro defpattern (name &body body)
  `(setf (gethash ',name *patterns*)
         ',(compile-pattern
            (if (breeze.utils:length>1? body)
                body
                (first body)))))

(defun ref-pattern (pattern)
  (check-type pattern ref)
  (or (gethash (ref-name pattern) *patterns*)
      (error "Failed to find the pattern ~S." (ref-name pattern))))


;;; Iterator:
;;;  - takes care of "recursing" into referenced patterns
;;;  - conditionally skips inputs
;;;  - works on vectors only, for my sanity
;;;  - I want to make it possible to iterate backward, hence the "step"

;; Will I regret implemeting this?

(defstruct iterator
  ;; The vector being iterated on
  vector
  ;; The current position in the vector
  (position 0)
  ;; How much to advance the position per iteration
  (step 1)
  ;; The iterator to return when the current one is done
  parent)

(defun iterator-done-p (iterator)
  "Check if there's any values left to iterator over."
  (check-type iterator iterator)
  ;; Simply check if "position" is out of bound.
  (not (< -1
          (iterator-position iterator)
          (length (iterator-vector iterator)))))

(defun iterator-push (iterator vector)
  "Create a new iterator on VECTOR, with ITERATOR as parent. Returns the
new iterator."
  (check-type iterator iterator)
  (check-type vector vector)
  (make-iterator :vector vector :parent iterator))

(defun iterator-maybe-push (iterator)
  "If ITERATOR is not done and the current value is a reference, \"push\"
a new iterator."
  (if (iterator-done-p iterator)
      iterator
      (let ((value (iterator-value iterator)))
        (if (refp value)
            (iterator-maybe-push (iterator-push iterator (ref-pattern value)))
            iterator))))

(defun iterator-maybe-pop (iterator)
  "If ITERATOR is done and has a parent, return the next parent."
  (check-type iterator iterator)
  (if (and (iterator-done-p iterator)
           (iterator-parent iterator))
      (let ((parent (iterator-parent iterator)))
        ;; Advance the position
        (incf (iterator-position parent)
              (iterator-step parent))
        ;; return the parent
        (iterator-maybe-pop parent))
      iterator))

(defun iterate (vector &key (step 1))
  "Create a new iterator."
  (check-type vector vector)
  (let ((iterator
          (iterator-maybe-push
           (make-iterator :vector vector :step step))))
    (if (iterator-skip-p iterator)
        (iterator-next iterator)
        iterator)))

(defvar *match-skip* nil
  "Controls wheter to skip a value when iterating.")

(defun iterator-skip-p (iterator &optional (match-skip *match-skip*))
  (when (and match-skip (not (iterator-done-p iterator)))
    (funcall match-skip (iterator-value iterator))))

(defun %iterator-next (iterator)
  "Advance the iterator exactly once. Might return a whole new iterator."
  (check-type iterator iterator)
  ;; Advance the position
  (incf (iterator-position iterator)
        (iterator-step iterator))
  (iterator-maybe-push (iterator-maybe-pop iterator)))

(defun iterator-next (iterator)
  "Advance the iterator, conditionally skipping some values. Might return
a whole new iterator."
  (check-type iterator iterator)
  (loop :for new-iterator = (%iterator-next iterator)
          :then (%iterator-next new-iterator)
        :while (iterator-skip-p new-iterator)
        :finally (return new-iterator)))

(defun iterator-value (iterator)
  "Get the value at the current ITERATOR's position."
  (check-type iterator iterator)
  (when (iterator-done-p iterator)
    (error "No more values in this iterator."))
  (aref (iterator-vector iterator)
        (iterator-position iterator)))


;;; Bindings (e.g. the result of a successful match

(defun make-empty-bindings () t)

(defun make-binding (term input)
  (list term input))

(defun merge-bindings (bindings1 bindings2)
  (cond
    ((eq t bindings1) bindings2)
    ((eq t bindings2) bindings1)
    ((or (eq nil bindings1) (eq nil bindings2)) nil)
    (t (append bindings1 bindings2))))

(defun normalize-bindings (bindings)
  (or (eq t bindings)
      (alexandria:alist-plist
       (sort (loop :for (key value) :on bindings :by #'cddr
                   :collect (cons (if (termp key)
                                      (term-name key)
                                      key)
                                  value))
             #'string<
             :key #'car))))


;;; Matching atoms

;; Basic "equal" matching
(defmethod match (pattern input)
  (equal pattern input))

;; Match a term (create a binding)
(defmethod match ((pattern term) input)
  (make-binding pattern input))

;; Match a typed term (creates a binding)
(defmethod match ((pattern typed-term) input)
  (when (typep input (typed-term-type pattern))
    (make-binding pattern input)))

;; Recurse into a referenced pattern
(defmethod match ((pattern ref) input)
  (match (ref-pattern pattern) input))

;; Match a string literal
(defmethod match ((pattern string) (input string))
  (string= pattern input))

;; "nil" must match "nil"
(defmethod match ((pattern null) (input null))
  t)

;; "nil" must not match any other symbols
(defmethod match ((pattern null) (input symbol))
  nil)


;;; Matching sequences

(defmethod match ((pattern iterator) (input iterator))
  (loop
    :with bindings = (make-empty-bindings)
    ;; Iterate over the pattern
    :for pattern-iterator := pattern
      :then (iterator-next pattern-iterator)
    ;; Iterate over the input
    :for input-iterator := input
      :then (iterator-next input-iterator)
    :until (or (iterator-done-p pattern-iterator)
               (iterator-done-p input-iterator))
    :for new-bindings = (match
                            (iterator-value pattern-iterator)
                          (iterator-value input-iterator))
    :if new-bindings
      ;; collect all the bindings
      :do (setf bindings (merge-bindings bindings new-bindings))
    :else
      ;; failed to match, bail out of the whole function
      :do (return nil)
    :finally
       ;; We advance the input iterator to see if there are still
       ;; values left that would not be skipped.
       (when (and (not (iterator-done-p input-iterator))
                  (iterator-skip-p input-iterator))
         (setf input-iterator (iterator-next input-iterator)))
       (return
         ;; We want to match the whole pattern, but wheter we
         ;; want to match the whole input is up to the caller.
         (when (iterator-done-p pattern-iterator)
           (values (or bindings t)
                   (if (iterator-done-p input-iterator)
                       nil
                       input-iterator))))))

(defmethod match ((pattern term) (input iterator))
  (multiple-value-bind (bindings input-remaining-p)
      (match (iterate (vector pattern)) input)
    (unless input-remaining-p
      bindings)))

(defmethod match ((pattern vector) (input vector))
  (multiple-value-bind (bindings input-remaining-p)
      (match (iterate pattern) (iterate input))
    (unless input-remaining-p
      bindings)))


;;; Matching alternations

(defmethod match ((pattern alternation) input)
  (some (lambda (pat) (match pat input))
        (alternation-pattern pattern)))


;;; Matching repetitions

(defmethod match ((pattern maybe) input)
  (or (alexandria:when-let ((bindings (match (maybe-pattern pattern) input)))
        (if (maybe-name pattern)
            (merge-bindings bindings (make-binding pattern input))
            bindings))
      (not input)))

(defmethod match ((pattern zero-or-more) (input null))
  t)

(defmethod match ((pattern zero-or-more) (input vector))
  (loop
    :with bindings = (make-empty-bindings)
    :with pat = (zero-or-more-pattern pattern)
    :with input-iterator := (iterate input)
    :do (multiple-value-bind (new-bindings new-input-iterator)
            (match (iterate pat) input-iterator)
          ;; (break)
          (if new-bindings
              ;; collect all the bindings (setf bindings
              ;; (merge-bindings bindings new-bindings))
              (setf bindings (merge-bindings bindings new-bindings))
              ;; No match
              (return nil))
          (if new-input-iterator
              (setf input-iterator new-input-iterator)
              ;; No more input left
              (return bindings)))))


;;; Convenience automatic coercions

(defmethod match ((pattern vector) (input iterator))
  (match (iterate pattern) input))

(defmethod match ((pattern vector) (input sequence))
  (match pattern (coerce input 'vector)))

(defmethod match ((pattern zero-or-more) (input sequence))
  (match pattern (coerce input 'vector)))
