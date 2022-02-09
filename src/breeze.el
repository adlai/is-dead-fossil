;;; package -- breeze integration with emacs

;;; Commentary:
;;
;; Features:
;; - snippets with abbrevs
;; - capture
;; - interactive make-project

;;; Code:


;;; Scratch section
;; (setf debug-on-error t)
;; (setf debug-on-error nil)


;;; Requires
(require 'cl-lib)
(require 'slime)


;;; Variables

(defvar breeze-mode-map
  (make-sparse-keymap)
  "Keymap for breeze-mode")


;;; Integration with lisp listener

(defun breeze-eval (string)
  (slime-eval `(swank:eval-and-grab-output ,string)))

(defun breeze-eval-value-only (string)
  (cl-destructuring-bind (output value)
      (breeze-eval string)
    (message "Breeze: got the value: %S" value)
    value))

;; TODO I should check that it is NOT equal to nil instead
(defun breeze-eval-predicate (string)
  (cl-equalp "t" (breeze-eval-value-only string)))

;; (and
;;  (eq t (breeze-eval-predicate "t"))
;;  (eq t (breeze-eval-predicate "T"))
;;  (eq nil (breeze-eval-predicate "nil"))
;;  (eq nil (breeze-eval-predicate "NIL")))

(defun breeze-eval-list (string)
  ;; TODO check breeze-cl-to-el-list
  (let ((list (car
	       (read-from-string
		(breeze-eval-value-only string)))))
    (if (listp list)
	list
      (message "Breeze: expected a list got: %S" list)
      nil)))

(defun breeze-interactive-eval (string)
  (slime-eval `(swank:interactive-eval ,string)))


;;; Prerequisites checks

(cl-defun breeze/check-if-slime-is-connected (&optional verbosep)
  "Make sure that slime is connected, signals an error otherwise."
  (if (slime-current-connection)
      (progn
	(when verbosep
	  (message "Slime already started."))
	t)
    (progn
      (when verbosep
	(message "Starting slime..."))
      (slime))))

(defun breeze/validate-if-package-exists (package)
  "Returns true if the package PACKAGE exists in the inferior-lisp."
  (breeze-eval-predicate
   (format "(and (or (find-package \"%s\") (find-package \"%s\")) t)"
	   (downcase package) (upcase package))))
;; (breeze/validate-if-package-exists "cl")

(defun breeze/validate-if-breeze-package-exists ()
  "Returns true if the package \"breeze\" exists in the inferior-lisp."
  (breeze/validate-if-package-exists "breeze"))

;; (breeze/validate-if-breeze-package-exists)

(defvar breeze/breeze.el load-file-name
  "Path to \"breeze.el\".")

(defun breeze/system-definition ()
  "Get the path to \"breeze.asd\" based on the (load-time) location
of \"breeze.el\"."
  (expand-file-name
   (concat
    (file-name-directory
     breeze/breeze.el)
    "../breeze.asd")))

(defun breeze/ensure-breeze (&optional verbosep)
  "Make sure that breeze is loaded in swank."
  (unless (breeze/validate-if-breeze-package-exists)
    (when verbosep
      (message "Loading breeze's system..."))
    (breeze-interactive-eval
     (format "(progn (load \"%s\") (require 'breeze)
        (format t \"~&Breeze loaded!~%%\"))"
	     (breeze/system-definition))))
  (when verbosep
    (message "Breeze loaded in inferior-lisp.")))

;; (breeze/ensure-breeze)

;; See slime--setup-contribs, I named this breeze-init so it _could_
;; be added to slime-contrib,
;; I haven't tested it yet though.
(defun breeze-init (&optional verbosep)
  "Ensure that breeze is initialized correctly on swank's side."
  (interactive)
  (breeze/check-if-slime-is-connected)
  (breeze/ensure-breeze verbosep)
  (breeze-interactive-eval "(breeze.user::initialize)")
  (when verbosep
    (message "Breeze initialized.")))


(defmacro breeze/with-slime (&rest body)
  `(progn
     (breeze-init)
     ,@body))

;; (macroexpand-1 '(breeze/with-slime (print 42)))

(defun breeze-cl-to-el-list (list)
  "Convert NIL to nil and T to t.
Common lisp often returns the symbols capitalized, but emacs
lisp's reader doesn't convert them."
  (if (eq list 'NIL)
      nil
    (mapcar #'(lambda (el)
		(case el
		  (NIL nil)
		  (T t)
		  (t el)))
	    list)))


;;; Suggestions

;; TODO This should be a command too
(defun breeze-next ()
  "Ask breeze for suggestions on what to do next."
  (interactive)
  (cl-destructuring-bind (output value)
      (slime-eval `(swank:eval-and-grab-output
		    ;; TODO send more information to "next"
		    ;; What's the current buffer? does it visit a file?
		    ;; What's the current package? is it covered by breeze.user:*current-packages*
		    "(breeze.user:next)"))
    (message "%s" output)))


;;; Prototype: quick scaffolding of defun (and other forms)

(defun breeze-current-paragraph ()
  (string-trim
   (save-mark-and-excursion
     (mark-paragraph)
     (buffer-substring (mark) (point)))))

(defun breeze-delete-paragraph ()
  (save-mark-and-excursion
    (mark-paragraph)
    (delete-region (point) (mark))))

(defun %breeze-expand-to-defuns (paragraph)
  (cl-loop for line in
	   (split-string paragraph "\n")
	   for parts = (split-string line)
	   collect
	   (format "(defun %s %s\n)\n" (car parts) (rest parts))))

(defun %breeze-expand-to-defuns ()
  "Takes a paragraph where each line describes a function, the
first word is the function's name and the rest are the
arguments. Use to quickly scaffold a bunch of functions."
  (interactive)
  (let ((paragraph (breeze-current-paragraph)))
    (breeze-delete-paragraph)
    (loop for form in (%breeze-expand-to-defuns paragraph)
	  do (insert form "\n"))))


;;; Common lisp driven interactive commands

(defun breeze-compute-buffer-args ()
  (apply 'format
	 ":buffer-name %s
          :buffer-file-name %s
          :buffer-string %s
          :point %s
          :point-min %s
          :point-max %s"
	 (mapcar #'prin1-to-string
		 (list
		  (buffer-name)
		  (buffer-file-name)
		  (buffer-substring-no-properties (point-min) (point-max))
		  (point)
		  (point-min)
		  (point-max)))))

(defun breeze-command-start (name)
  (message "Breeze: starting command: %s." name)
  (let ((request
	  (breeze-cl-to-el-list
	   (breeze-eval-list
	    (format "(%s %s)" name (breeze-compute-buffer-args))))))
    (message "Breeze: got the request: %S" request)
    (if request
	request
      (progn (message "Breeze: start-command returned nil")
	     nil))))

(defun breeze-command-cancel ()
  (breeze-eval
   (format "(breeze.command:cancel-command)"))
  (message "Breeze: command canceled."))
;; (breeze-command-cancel)

(defun breeze-command-continue (response send-response-p)
  (let ((request
	  (breeze-cl-to-el-list
	   (breeze-eval-list
	    (if send-response-p
		(format
		 "(breeze.command:continue-command %S)" response)
	      "(breeze.command:continue-command)")))))
    (message "Breeze: request received: %S" request)
    request))

(defun breeze-command-process-request (request)
  (pcase (car request)
    ("choose"
     (completing-read (second request)
		      (third request)))
    ("read-string"
     (apply #'read-string (rest request)))
    ("insert-at"
     (cl-destructuring-bind (_ position string)
	 request
       (when (numberp position) (goto-char position))
       (insert string)))
    ("insert-at-saving-excursion"
     (cl-destructuring-bind (_ position string)
	 request
       (save-excursion
	 (when (numberp position) (goto-char position))
	 (insert string))))
    ("insert"
     (cl-destructuring-bind (_ string) request (insert string)))
    ("replace"	      ; TODO -saving-excursion variant
     (cl-destructuring-bind
	 (point-from point-to replacement-stirng)
	 (cdr request)
       ;; TODO
       ))
    ("backward-char"
     (backward-char (second request))
     ;; Had to do this hack so the cursor is positioned
     ;; correctly... probably because of aggressive-indent
     (funcall indent-line-function))
    (_ (error "Invalid request: %S" request) )))


(defun breeze-run-command (name)
  "Runs a \"breeze command\". TODO Improve this docstring."
  (interactive)
  (condition-case condition
      (cl-loop
       ;; guards against infinite loop
       for i below 1000
       for
       ;; Start the command
       request = (breeze-command-start name)
       ;; Continue the command
       then (breeze-command-continue response send-response-p)
       ;; "Request" might be nil, if it is, we're done
       while (and request
		  (not (string= "done" (car request))))
       ;; Wheter or not we need to send arguments to the next callback.
       for send-response-p = (member (car request)
				     '("choose" "read-string"))
       ;; Process the command's request
       for response = (breeze-command-process-request request)
       ;; Log request and response (for debugging)
       do (message "Breeze: request received: %S response to send %S"
		   request
		   response))
    (t
     (message "Breeze run command: got the condition %s" condition)
     (breeze-command-cancel))))


;;; quickfix (similar to code actions in visual studio code)

(defun breeze-quickfix ()
  "Choose a command from a list of applicable to the current context."
  (interactive)
  (breeze-run-command "breeze.refactor:quickfix"))


;;; code evaluation

(defun breeze-get-recently-evaluated-forms ()
  "Get recently evaluated forms from the server."
  (cl-destructuring-bind (output value)
      (slime-eval `(swank:eval-and-grab-output
		    "(breeze.listener:get-recent-interactively-evaluated-forms)"))
    (split-string output "\n")))

(defun breeze-reevaluate-form ()
  (interactive)
  (let ((form (completing-read  "Choose recently evaluated form: "
				(breeze-get-recently-evaluated-forms))))
    (when form
      (slime-interactive-eval form))))


;;; project scaffolding

(defun breeze-quickproject ()
  "Create a project named using quickproject."
  (interactive)
  (breeze-run-command "breeze.project:scaffold-project"))


;;; capture

(defun breeze-capture ()
  "Create a file ready to code in."
  (interactive)
  (breeze-run-command "breeze.capture:capture"))


;;; managing threads

;; TODO as of 2022-02-08, there's code for that in listener.lisp
;; breeze-kill-worker-thread


;;; mode

(define-minor-mode breeze-mode
  "Breeze mimor mode."
  :lighter " brz"
  :keymap breeze-mode-map)

;; Analoguous to org-insert-structure-template
;; (define-key breeze-mode-map (kbd "C-c C-,") 'breeze-insert)

;; Analoguous to org-goto
(define-key breeze-mode-map (kbd "C-c C-j") #'imenu)

;; Analoguous to Visual Studio Code's "quickfix"
(define-key breeze-mode-map (kbd "C-.") #'breeze-quickfix)

;; eval keymap - because we might want to keep an history
(defvar breeze/eval-map (make-sparse-keymap))
;; eval last expression
(define-key breeze-mode-map (kbd "C-c e") breeze/eval-map)
;; choose an expression from history to evaluate
(define-key breeze/eval-map (kbd "e") 'breeze-reevaluate-form)

(defun enable-breeze-mode ()
  "Enable breeze-mode."
  (interactive)
  (breeze-mode 1))

(defun disable-breeze-mode ()
  "Disable breeze-mode."
  (interactive)
  (breeze-mode -1))

(add-hook 'breeze-mode-hook 'breeze/configure-mode-line)
;; (add-hook 'breeze-mode-hook 'breeze-init)
;; TODO This should be in the users' config
;; (add-hook 'slime-lisp-mode-hook 'breeze-init)
;; TODO This should be in the users' config
(add-hook 'slime-connected-hook 'breeze-init)

(defun breeze ()
  "Start slime and breeze"
  (interactive)
  (breeze-init t))

(provide 'breeze)
;;; breeze.el ends here
