
(cl:in-package #:cl-user)

(defpackage #:breeze.test.lossless-reader
  (:documentation "Test package for #:breeze.lossless-reader")
  (:use #:cl #:breeze.lossless-reader)
  (:import-from #:breeze.lossless-reader
                ;; state
                #:state
                #:source
                #:pos
                #:tree
                #:make-state
                ;; nodes
                #:+end+
                #:node
                #:valid-node-p
                #:at
                #:at=
                #:current-char
                #:current-char=
                #:next-char
                #:next-char=
                ;; node constructors
                #:block-comment
                #:parens
                #:sharpsign
                #:punctuation
                #:token
                #:whitespace
                #:line-comment
                ;; Symbols used in the returns
                #:quote                 ; this ones from cl actually
                #:quasiquote
                #:dot
                #:comma
                #:sharp
                #:sharp-char
                #:sharp-function
                #:sharp-vector
                #:sharp-bitvector
                #:sharp-uninterned
                #:sharp-eval
                #:sharp-binary
                #:sharp-octal
                #:sharp-hexa
                #:sharp-complex
                #:sharp-structure
                #:sharp-pathname
                #:sharp-feature
                #:sharp-feature-not
                #:sharp-radix
                #:sharp-array
                #:sharp-label
                #:sharp-reference
                #:sharp-unknown
                ;; state utilities
                #:at
                #:donep
                #:valid-position-p
                #:*state-control-string*
                #:state-context
                ;; parsing utilities
                #:read-char*
                #:find-all
                #:not-terminatingp
                #:read-string*
                #:read-while
                ;; sub parser
                #:read-line-comment
                #:read-parens
                #:read-sharpsign-dispatching-reader-macro
                #:read-punctuation
                #:read-quoted-string
                #:read-string
                #:read-token
                #:read-whitespaces
                #:read-block-comment
                ;; top-level parsing/unparsing
                #:parse
                #:parse*
                #:unparse)
  (:import-from #:parachute
                #:define-test
                #:define-test+run
                #:is
                #:true
                #:false
                #:of-type)
  (:import-from #:breeze.kite
                #:is-equalp))

(in-package #:breeze.test.lossless-reader)

#|

Testing strategies
- generate random strings
- ddmin to reduce
- enable infinite loop guards
- detect when guards are "triggered"
- compare with cl:read
- compare with eclector:read
- test each read-* functions individually
- none should signal errors
- make a generic function validate-node to assert that they make
sense (e.g. a line comment should start with a ; and end with a
newline or +end+)

|#


;;; Reader state

#++
(progn
  (node 'boo 1 2)
  #s(node :type boo :start 1 :end 2)
  (list #s(node :type boo :start 1 :end 2))
  (list '#s(node :type boo :start 1 :end 2)))


;;; testing helpers

(defvar *test-strings* (make-hash-table :test 'equal))

(defun register-test-string (string)
  (setf (gethash string *test-strings*) t)
  string)

(defmacro with-state ((string &optional more-labels) &body body)
  (alexandria:once-only (string)
    `(let ((state (make-state (register-test-string ,string))))
       ;; Wraps #'is-equal to use the state's source as input
       ;; remainder: the input is only used (unless (equalp got expected))
       ;; the input is used to give
       (labels ((test* (got &optional expected)
                  (is-equalp ,string got expected
                             *state-control-string*
                             (state-context state)))
                ,@more-labels)
         (declare (ignorable (function test*)))
         ,@ (loop :for (label . _) :in more-labels
                  :collect `(declare (ignorable (function ,label))))
         ,@body))))

(defmacro %with-state* ((string &optional more-labels) &body body)
  (alexandria:once-only (string)
    `(list
      ,@(loop :for form :in body
              :collect `(with-state (,string ,more-labels) ,form)))))

(defmacro with-state* ((&rest more-labels) &body body)
  `(append
    ,@(loop :for form :in body
            :collect `(%with-state*
                          (,(car form) ,more-labels)
                        ,@(rest form)))))

;; TODO better name
(defmacro with-state*+predicates ((&key test-form extra-args more-labels)
                                  &body body)
  `(with-state*
       ((yes (,@extra-args) (test* ,test-form t))
        (no (,@extra-args) (test* ,test-form nil))
        ,@more-labels)
     ,@body))


;;; Reader position (in the source string)

(define-test+run valid-position-p
  (with-state*+predicates (:test-form (valid-position-p state pos)
                           :extra-args (pos))
    (""  (no -1) (no 0)  (no 1))
    (" " (no -1) (yes 0) (no 1))))

(define-test+run donep
  :depends-on (valid-position-p)
  (with-state*+predicates (:test-form (progn (setf (pos state) pos)
                                             (donep state))
                           :extra-args (pos))
    (""  (yes -1) (yes 0) (yes 1))
    (" " (yes -1) (no 0) (yes 1))
    ("  " (yes -1) (no 0) (no 1) (yes 2))))


;;; Getting and comparing characters

(define-test+run at
  :depends-on (valid-position-p)
  (with-state* ()
    (""
     (test* (at state -1) nil)
     (test* (at state 0) nil)
     (test* (at state 1) nil))
    ("c"
     (test* (at state -1) nil)
     (test* (at state 0) #\c)
     (test* (at state 1) nil))))

(define-test+run at=
  :depends-on (at)
  (with-state* ()
    (""
     (test* (at= state -1 #\a) nil)
     (test* (at= state 0 #\b) nil)
     (test* (at= state 1 #\c) nil))
    ("c"
     (test* (at= state -1 #\c) nil)
     (test* (at= state 0 #\c) #\c)
     (test* (at= state 0 #\a) nil)
     (test* (at= state 1 #\c) nil))))

;; TODO test "current-char"
(define-test+run current-char)

;; TODO test "current-char="
(define-test+run current-char=)

;; TODO test "next-char"
(define-test+run next-char)

;; TODO test "next-char="
(define-test+run next-char=)



;;; Low-level parsing helpers

(define-test+run read-char*
  :depends-on (current-char)
  (with-state* ()
    (""
     (test* (list (read-char* state) (pos state)) '(nil 0))
     (test* (list (read-char* state #\a) (pos state)) '(nil 0)))
    ("c"
     (test* (list (read-char* state) (pos state)) '(#\c 1))
     (test* (list (read-char* state #\d) (pos state)) '(nil 0)))))

(define-test+run read-string*
  :depends-on (valid-position-p)
  (with-state* ()
    (""
     (test*
      (list
       (read-string* state "")
       (pos state))
      '(nil 0))
     (test*
      (list
       (read-string* state "#")
       (pos state))
      '(nil 0)))
    (";"
     (test*
      (list
       (read-string* state ";;")
       (pos state))
      '(nil 0)))
    (";;"
     (test*
      (list
       (read-string* state ";;")
       (pos state))
      '((0 2) 2)))))

;; TODO test read-while
(define-test+run read-while)

(defun test-find-all (needle string expected)
  (register-test-string string)
  (register-test-string needle)
  (is-equalp
   (list 'find-all needle string)
   (find-all needle string)
   expected))

(define-test+run find-all
  (test-find-all "" "" nil)
  (test-find-all "a" "" nil)
  (test-find-all "" "a" nil)
  (test-find-all "a" "aaa" '(0 1 2))
  (test-find-all "b" "aaa" nil))


;;; Actual reader

(defun test-read-whitespaces (input expected-end)
  (with-state (input)
    (test* (read-whitespaces state)
           (when expected-end
             (whitespace 0 expected-end)))))

(define-test+run read-whitespaces
  ;; :depends-on (whitespacep)
  (test-read-whitespaces "" nil)
  (test-read-whitespaces "a" nil)
  (test-read-whitespaces " " 1)
  (test-read-whitespaces "  " 2))

(defun test-read-block-comment (input expected-end)
  (with-state (input)
    (is-equalp input (read-block-comment state)
          (when expected-end
            (block-comment 0 expected-end)))))

(define-test+run read-block-comment
  :depends-on (read-string*)
  (test-read-block-comment "" nil)
  (test-read-block-comment "#|" +end+)
  (test-read-block-comment "#| " +end+)
  (test-read-block-comment "#||#" 4)
  (test-read-block-comment "#|#" +end+)
  (test-read-block-comment "#|#|#" +end+)
  (test-read-block-comment "#|#||##" +end+)
  (test-read-block-comment "#|#|#|#" +end+)
  (test-read-block-comment "#|#|#||##" +end+)
  (test-read-block-comment "#|#||#|## "
                           ;; There's 9 characters, the last # is not
                           ;; part of any comments
                           8))

(defun test-read-line-comment (input expected-end)
  (with-state ((format nil input))
    (test* (read-line-comment state)
           (when expected-end
             (line-comment 0 expected-end)))))

(define-test read-line-comment
  (test-read-line-comment "" nil)
  (test-read-line-comment ";" +end+)
  (test-read-line-comment "; asdf~%" 7))

(defun test-read-sharpsign (input expected-type expected-end
                            &optional (expected-pos expected-end))
  (with-state (input)
    (let ((got (is-equalp input
                          (read-sharpsign-dispatching-reader-macro state)
                          (sharpsign expected-type 0 expected-end))))
      (when got
        (is-equalp input
                   expected-pos
                   (pos state))))))

(define-test+run read-sharpsign-dispatching-reader-macro
  (test-read-sharpsign "#\\" 'sharp-char 2)
  (test-read-sharpsign "#\\Space" 'sharp-char 2)
  (test-read-sharpsign "#'" 'sharp-function 2)
  (test-read-sharpsign "#'car" 'sharp-function 2)
  (test-read-sharpsign "#(" 'sharp-vector 1 1)
  (test-read-sharpsign "#(asdf)" 'sharp-vector 1 1)
  (test-read-sharpsign "#42(asdf)" 'sharp-vector 3 3)
  (test-read-sharpsign "#*" 'sharp-bitvector 2)
  (test-read-sharpsign "#*110" 'sharp-bitvector 2)
  (test-read-sharpsign "#4*" 'sharp-bitvector 3)
  (test-read-sharpsign "#4*10" 'sharp-bitvector 3)
  (test-read-sharpsign "#:" 'sharp-uninterned 2)
  (test-read-sharpsign "#:asdf" 'sharp-uninterned 2)
  (test-read-sharpsign "#." 'sharp-eval 2)
  (test-read-sharpsign "#.(+ 1 1)" 'sharp-eval 2)
  (test-read-sharpsign "#b" 'sharp-binary 2)
  (test-read-sharpsign "#b101" 'sharp-binary 2)
  (test-read-sharpsign "#B" 'sharp-binary 2)
  (test-read-sharpsign "#B101" 'sharp-binary 2)
  (test-read-sharpsign "#o" 'sharp-octal 2)
  (test-read-sharpsign "#o666" 'sharp-octal 2)
  (test-read-sharpsign "#O" 'sharp-octal 2)
  (test-read-sharpsign "#O666" 'sharp-octal 2)
  (test-read-sharpsign "#x" 'sharp-hexa 2)
  (test-read-sharpsign "#xbeef" 'sharp-hexa 2)
  (test-read-sharpsign "#X" 'sharp-hexa 2)
  (test-read-sharpsign "#Xbeef" 'sharp-hexa 2)
  (test-read-sharpsign "#5r" 'sharp-radix 3)
  (test-read-sharpsign "#5r32" 'sharp-radix 3)
  (test-read-sharpsign "#3R" 'sharp-radix 3)
  (test-read-sharpsign "#3R32" 'sharp-radix 3)
  (test-read-sharpsign "#c" 'sharp-complex 2)
  (test-read-sharpsign "#c(1 2)" 'sharp-complex 2)
  (test-read-sharpsign "#C" 'sharp-complex 2)
  (test-read-sharpsign "#C(1 2)" 'sharp-complex 2)
  (test-read-sharpsign "#42a" 'sharp-array 4)
  (test-read-sharpsign "#42a()" 'sharp-array 4)
  (test-read-sharpsign "#41A" 'sharp-array 4)
  (test-read-sharpsign "#41A()" 'sharp-array 4)
  (test-read-sharpsign "#s" 'sharp-structure 2)
  (test-read-sharpsign "#s(node)" 'sharp-structure 2)
  (test-read-sharpsign "#S" 'sharp-structure 2)
  (test-read-sharpsign "#S(node)" 'sharp-structure 2)
  (test-read-sharpsign "#p" 'sharp-pathname 2)
  (test-read-sharpsign "#p\"./\"" 'sharp-pathname 2)
  (test-read-sharpsign "#P" 'sharp-pathname 2)
  (test-read-sharpsign "#P\"./\"" 'sharp-pathname 2)
  (test-read-sharpsign "#0=x" 'sharp-label 3)
  (test-read-sharpsign "#0=" 'sharp-label 3)
  (test-read-sharpsign "#0#" 'sharp-reference 3)
  (test-read-sharpsign "#+" 'sharp-feature 2)
  (test-read-sharpsign "#+ (and)" 'sharp-feature 2)
  (test-read-sharpsign "#-" 'sharp-feature-not 2)
  (test-read-sharpsign "#- (or)" 'sharp-feature-not 2)
  ;; #| ... |# is handled elsewhere
  )

(defun test-read-punctuation (input expected-type)
  (with-state (input)
    (is-equalp input
               (read-punctuation state)
               (when expected-type
                 (punctuation expected-type 0)))))

(define-test+run read-punctuation
  :depends-on (current-char)
  (test-read-punctuation "" nil)
  (test-read-punctuation " " nil)
  (test-read-punctuation "'" 'quote)
  (test-read-punctuation "`" 'quasiquote)
  (test-read-punctuation "." 'dot)
  (test-read-punctuation "@" 'at)
  (test-read-punctuation "," 'comma)
  (test-read-punctuation "#" 'sharp)
  ;; anything else should return nil
  )


;; TODO Add tests with VALIDP
(define-test+run read-quoted-string
  :depends-on (at)
  (with-state ("")
    (test* (read-quoted-string state #\| #\/) nil))
  (with-state ("|")
    (test* (read-quoted-string state #\| #\/) (list 0  +end+)))
  (with-state ("||")
    (test* (read-quoted-string state #\| #\/) '(0 2)))
  (with-state ("| |")
    (test* (read-quoted-string state #\| #\/) '(0 3)))
  (with-state ("|/||")
    (test* (read-quoted-string state #\| #\/) '(0 4)))
  (with-state ("|/|")
    (test* (read-quoted-string state #\| #\/) (list 0 +end+))))

(defun test-read-string (input expected-end)
  (with-state (input)
    (test* (read-string state)
           (when expected-end
             (node 'string 0 expected-end)))))

(define-test+run read-string
  :depends-on (read-quoted-string)
  (test-read-string "" nil)
  (test-read-string "\"" +end+)
  (test-read-string "\"\"" 2)
  (test-read-string "\" \"" 3))

(define-test+run not-terminatingp
  (mapcar #'(lambda (char)
              (false (not-terminatingp char)
                     "~c is supposed to be a terminating character." char))
          '(#\; #\" #\' #\( #\) #\, #\`)))

(defun test-read-token (input expected-end)
  (with-state (input)
    (test* (read-token state)
           (when expected-end
             (token 0 expected-end)))))

;; TODO Fix read-token
(define-test+run read-token
  :depends-on (current-char
               not-terminatingp
               read-quoted-string
               read-while)
  (test-read-token "" nil)
  (test-read-token " " nil)
  (test-read-token "+-*/" 4)
  (test-read-token "123" 3)
  (test-read-token "| asdf |" 8)
  (test-read-token "| a\\|sdf |" 10)
  (test-read-token "| asdf |qwer#" 13)
  (test-read-token "arg| asdf | " 11)
  (test-read-token "arg| asdf |more" 15)
  (test-read-token "arg| asdf |more|" +end+)
  (test-read-token "arg| asdf |more|mmoooore|done" 29)
  (test-read-token "arg| asdf |no  |mmoooore|done" 13)
  (test-read-token "look|another\\| case\\| didn't think of| " 38))


;; TODO read-extraneous-closing-parens

(defun test-read-parens (input expected-end &rest children)
  (with-state (input)
    (test* (read-parens state)
           (when expected-end
             (parens 0 expected-end children)))))

(define-test+run read-parens
  :depends-on (read-char*)
  (test-read-parens ")" nil)
  (test-read-parens "(" +end+)
  (test-read-parens "()" 2)
  (test-read-parens "(x)" 3 (token 1 2))
  (test-read-parens "(.)" 3 (punctuation 'dot 1))
  (test-read-parens "( () )" 6
                    (whitespace 1 2)
                    (parens 2 4)
                    (whitespace 4 5)))

;; TODO read-any
(define-test read-any)



;;; Putting it all toghether

;; TODO parse
(defun test-parse (input &rest expected)
  (register-test-string input)
  (let* ((state (parse input))
         (tree (tree state)))
    (if expected
        (is-equalp input tree expected)
        (is-equalp input tree))))

(define-test+run "parse"
  :depends-on (read-parens)
  (eq (parse "") nil)
  (test-parse " (" (whitespace 0 1) (parens 1 +end+))
  (test-parse "  " (whitespace 0 2))
  (test-parse "#|" (block-comment 0 +end+))
  (test-parse " #| "
              (whitespace 0 1)
              (block-comment 1 +end+)
              #++
              (whitespace 3 4))
  (test-parse "#||#" (block-comment 0 4))
  (test-parse "#|#||#" (block-comment 0 +end+))
  (test-parse "#| #||# |#" (block-comment 0 10))
  (test-parse "'" (punctuation 'quote 0))
  (test-parse "`" (punctuation 'quasiquote 0))
  (test-parse "#" (punctuation 'sharp 0))
  (test-parse "," (punctuation 'comma 0))
  (test-parse "+-*/" (token 0 4))
  (test-parse "123" (token 0 3))
  (test-parse "asdf#" (token 0 5))
  (test-parse "| asdf |" (token 0 8))
  (test-parse "arg| asdf | " (token 0 11) (whitespace 11 12))
  (test-parse "arg| asdf |more" (token 0 15))
  (test-parse "arg| asdf |more|" (token 0 +end+))
  (test-parse "arg| asdf " (token 0 +end+))
  (test-parse ";" (line-comment 0 +end+))
  (test-parse "(12" (parens 0 +end+ (token 1 3)))
  (test-parse "\"" (node 'string 0 +end+))
  (test-parse "#:asdf"
              (node 'sharp-uninterned 0 2)
              (node 'token 2 6))
  (test-parse "#2()"
              (node 'sharp-vector 0 2)
              (node 'parens 2 4))
  (test-parse "#<>" (node 'sharp-unknown 0 +end+))
  (test-parse "#+" (node 'sharp-feature 0 2)))

(defun test-parse* (input &rest expected)
  (register-test-string input)
  (if expected
      (is-equalp input (parse* input) expected)
      (is-equalp input (parse* input))))

;; Slightly cursed syntax:
;; "#+#."
;; e.g. "#+ #.(cl:quote x) 2" == "#+ x 2"


;;; Unparse

(defun test-round-trip (string &key context check-for-error)
  (register-test-string string)
  (let* ((state (parse string))
         (result (unparse state nil))
         (success (equalp string result)))
    (is-equalp (or context string) result string)
    (when (and success check-for-error)
      ;; Would be nice to (signal ...), not error, just signal, when
      ;; there's a parsing failure, because right now it's pretty hard
      ;; to pinpoint where something went wrong.
      (let ((bad-node (find-if-not #'valid-node-p (tree state))))
        (setf success
              (true (null bad-node)
                    "Failed to parse correctly ~S~%~?"
                    context
                    *state-control-string*
                    (list
                     (state-context state))))))
    success))

(define-test+run unparse
  (test-round-trip "#' () () ()")
  (test-round-trip " (")
  (loop :for string :being :the :hash-key :of *test-strings*
        :do (test-round-trip string)))

(define-test+run round-trip-breeze
  (loop :for file :in (breeze.asdf:system-files 'breeze)
        :for content = (alexandria:read-file-into-string file)
        :do (test-round-trip content
                             :context file
                             ;; :check-for-error t
                             )))
