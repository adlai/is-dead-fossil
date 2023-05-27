
(cl:in-package #:cl-user)

(defpackage #:breeze.test.lossless-reader
  (:documentation "Test package for #:breeze.lossless-reader")
  (:use #:cl #:breeze.lossless-reader)
  (:import-from #:breeze.lossless-reader
                #:make-state
                #:node
                #:tree
                #:not-terminatingp
                #:parens
                #:parse
                #:parse*
                #:unparse
                #:pos
                #:punctuation
                #:read-block-comment
                #:read-char*
                #:read-line-comment
                #:read-parens
                #:read-punctuation
                #:read-quoted-string
                #:read-string
                #:read-string*
                #:read-token
                #:read-whitespaces
                #:source
                #:token
                #:valid-position-p
                #:whitespace
                ;; Symbols used in the returns
                #:quote ; this ones from cl actually
                #:quasiquote
                #:dot
                #:at
                #:comma
                #:sharp)
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

(defmacro with-state ((string) &body body)
  `(let ((state (make-state (register-test-string ,string))))
     ;; Wraps #'is-equal to use the state's source as input
     ;; remainder: the input is only used (unless (equalp got expected))
     ;; the input is used to give
     (labels ((test* (got &optional (expected nil expectedp))
                (if expectedp
                    (is-equalp (source state) got expected)
                    (is-equalp (source state) got))))
       (declare (ignorable (function test*)))
       ,@body)))

(defmacro %with-state* ((string) &body body)
  (alexandria:once-only (string)
    `(list
      ,@(loop :for form :in body
              :collect `(with-state (,string) ,form)))))

(defmacro with-state* (&body body)
  `(append
    ,@(loop :for form :in body
            :collect `(%with-state* (,(car form)) ,@(rest form))))  )


;;; Reader position (in the source string)

(define-test+run valid-position-p
  (with-state*
    (""
     (test* (valid-position-p state -1) nil)
     (test* (valid-position-p state 0) nil)
     (test* (valid-position-p state 1) nil))
    (" "
     (test* (valid-position-p state -1) nil)
     (test* (valid-position-p state 0) t)
     (test* (valid-position-p state 1) nil))))

(define-test+run donep
  :depends-on (valid-position-p)
  (with-state*
    ("" (test* (donep state) t))
    (" " (test* (donep state) nil))
    ("  " (test* (donep state) nil))))


;;; Getting and comparing characters

(define-test+run at
  :depends-on (valid-position-p)
  (with-state*
    (""
     (test* (at state -1) nil)
     (test* (at state 0) nil)
     (test* (at state 1) nil)
     (test* (at state -1 #\a) nil)
     (test* (at state 0 #\b) nil)
     (test* (at state 1 #\c) nil))
    ("c"
     (test* (at state -1) nil)
     (test* (at state 0) #\c)
     (test* (at state 1) nil)
     (test* (at state -1 #\c) nil)
     (test* (at state 0 #\c) #\c)
     (test* (at state 0 #\a) nil)
     (test* (at state 1 #\c) nil))))

;; TODO test "current-char"
(define-test+run current-char)

;; TODO test "next-char"
(define-test+run next-char)



;;; Low-level parsing helpers

(define-test+run read-char*
  :depends-on (current-char)
  (with-state*
    (""
     (test* (list (read-char* state) (pos state)) '(nil 0))
     (test* (list (read-char* state #\a) (pos state)) '(nil 0)))
    ("c"
     (test* (list (read-char* state) (pos state)) '(#\c 1))
     (test* (list (read-char* state #\d) (pos state)) '(nil 0)))))

(define-test+run read-string*
  :depends-on (valid-position-p)
  (with-state*
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
  (is-equalp (list 'find-all needle string)
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

(define-test+run read-line-comment
  (test-read-line-comment "" nil)
  (test-read-line-comment ";" +end+)
  (test-read-line-comment "; asdf~%" 7))

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
  (test-parse "\"" (node 'string 0 +end+)))

(defun test-parse* (input &rest expected)
  (register-test-string input)
  (if expected
      (is-equalp input (parse* input) expected)
      (is-equalp input (parse* input))))

(define-test+run "parse"
  :depends-on (read-parens)
  (eq (parse "") nil)
  (test-parse* "  " (whitespace 0 2))
  (test-parse* "#|" (block-comment 0 +end+))
  (test-parse* " #| "
              (whitespace 0 1)
              (block-comment 1 +end+)
              #++
              (whitespace 3 4))
  (test-parse* "#||#" (block-comment 0 4))
  (test-parse* "#|#||#" (block-comment 0 +end+))
  (test-parse* "#| #||# |#" (block-comment 0 10))
  (test-parse* "'" (punctuation 'quote 0))
  (test-parse* "`" (punctuation 'quasiquote 0))
  (test-parse* "#" (punctuation 'sharp 0))
  (test-parse* "," (punctuation 'comma 0))
  (test-parse* "+-*/" (token 0 4))
  (test-parse* "123" (token 0 3))
  (test-parse* "asdf#" (token 0 5))
  (test-parse* "| asdf |" (token 0 8))
  (test-parse* "arg| asdf | " (token 0 11) (whitespace 11 12))
  (test-parse* "arg| asdf |more" (token 0 15))
  (test-parse* "arg| asdf |more|" (token 0 +end+))
  (test-parse* ";" (line-comment 0 +end+))
  (test-parse* "(12" (parens 0 +end+ (token 1 3)))
  (test-parse* "\"" (node 'string 0 +end+)))


#|


(list
 (parse "#<>")
 (parse "#+"))

http://www.lispworks.com/documentation/HyperSpec/Body/02_dh.htm

(list of reader macros
 "\\'(*:boxrcasp=+-<")


#) and #<any whitespace> are **invalid**

|#

#++
(multiple-value-bind (tree state)
    (parse "(foo)")
  (format nil "(~a ~a)"
          "ignore-errors"
          (node-content state (car tree))))


;; Slightly cursed syntax:
;; "#+#."



;;; Unparse

(defun test-round-trip (input)
  (register-test-string input)
  (let* ((state (parse input))
         (result (unparse state nil)))
    (is-equalp input result input)))

(time
 (progn
   (define-test unparse
     (test-round-trip "#' () () ()")
     (test-round-trip " (")
     (loop :for string :being :the :hash-key :of *test-strings*
           :do (test-round-trip string)))
   (parachute:test 'unparse :report 'parachute:quiet)))