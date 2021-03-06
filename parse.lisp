
;; Copyright (c) Marijn Haverbeke, marijnh@gmail.com

;; This software is provided 'as-is', without any express or implied
;; warranty. In no event will the authors be held liable for any
;; damages arising from the use of this software.

;; Permission is granted to anyone to use this software for any
;; purpose, including commercial applications, and to alter it and
;; redistribute it freely, subject to the following restrictions:

;; 1. The origin of this software must not be misrepresented; you must
;;    not claim that you wrote the original software. If you use this
;;    software in a product, an acknowledgment in the product
;;    documentation would be appreciated but is not required.

;; 2. Altered source versions must be plainly marked as such, and must
;;    not be misrepresented as being the original software.

;; 3. This notice may not be removed or altered from any source
;;    distribution.

;; ## Important Note

;; Cheat-JS includes a modified version of
;; [`parse-js`](http://marijnhaverbeke.nl/parse-js/), written by Marijn
;; Haverbeke. This is necessary because I (Miron Brezuleanu) needed to
;; modify `parse-js` a little. The license of `parse-js` is in the
;; `LICENSE-parse-js.txt` file. The modified files from `parse-js`
;; included in Cheat-JS are `parse.lisp`, `tokenize.lisp` and
;; `util.lisp`. The modifications were permitted by the `parse-js`
;; license. This is not an official copy of `parse-js` and is not
;; supported by Marijn Haverbeke. If the modified parsing code in
;; Cheat-JS breaks, it's exclusively my fault - I messed up the code.

(in-package #:parse-js)

(defparameter *unary-prefix* '(:typeof :void :delete :-- :++ :! :~ :- :+))
(defparameter *unary-postfix* '(:-- :++))
(defparameter *assignment*
  (let ((assign (make-hash-table)))
    (dolist (op '(:+= :-= :/= :*= :%= :>>= :<<= :>>>= :|\|=| :^= :&=))
      (setf (gethash op assign) (intern (subseq (string op) 0 (1- (length (string op)))) :keyword)))
    (setf (gethash := assign) t)
    assign))

(defparameter *precedence*
  (let ((precs (make-hash-table)))
    (loop :for ops :in '((:|\|\||) (:&&) (:|\||) (:^) (:&) (:== :=== :!= :!==)
                         (:< :> :<= :>= :in :instanceof) (:>> :<< :>>>) (:+ :-) (:* :/ :%))
       :for n :from 1
       :do (dolist (op ops) (setf (gethash op precs) n)))
    precs))

(defparameter *in-function* nil)
(defparameter *label-scope* nil)
(defmacro with-label-scope (type label &body body)
  `(let ((*label-scope* (cons (cons ,type ,label) *label-scope*))) ,@body))

(defun parse-js (input &key strict-semicolons (ecma-version 3) reserved-words)
  (check-type ecma-version (member 3 5))
  (let ((*ecma-version* ecma-version)
        (*check-for-reserved-words* reserved-words)
        (*line* 0)
        (*char* 0)
        (*position* 0))
    (if (stringp input)
        (with-input-from-string (in input) (parse-js* in strict-semicolons))
        (parse-js* input strict-semicolons))))

(defvar *macro-hook* nil)

(defun/defs parse-js* (stream &optional strict-semicolons)
  (def input (if (functionp stream) stream (lex-js stream)))
  (def token (funcall input))
  (def peeked nil)

  (def peek ()
    (or peeked (setf peeked (funcall input))))
  (def next ()
    (if peeked
        (setf token peeked peeked nil)
        (setf token (funcall input)))
    token)
  (def skip (n)
    (dotimes (i n) (next)))

  (def token-error (token control &rest args)
    (let ((*line* (token-line token)) (*char* (token-char token)))
      (apply #'js-parse-error control args)))
  (def error* (control &rest args)
    (apply #'token-error token control args))
  (def unexpected (token)
    (token-error token "Unexpected token '~a'." (token-id token)))

  (def expect-token (type val)
    (if (tokenp token type val)
        (next)
        (error* "Unexpected token '~a', expected '~a'." (token-id token) val)))
  (def expect (punc)
    (expect-token :punc punc))
  (def expect-key (keyword)
    (expect-token :keyword keyword))
  (def can-insert-semicolon ()
    (and (not strict-semicolons)
         (or (token-newline-before token)
             (token-type-p token :eof)
             (tokenp token :punc #\})
             (tokenp token :punc #\)))))
  (def semicolonp () (tokenp token :punc #\;))
  (def semicolon ()
    (cond ((semicolonp) (next))
          ((not (can-insert-semicolon)) (unexpected token))))

  (def as (type &rest args)
    (cons type args))

  (def parenthesised ()
    (expect #\() (prog1 (expression) (expect #\))))

  (def statement (&optional label)
    ;; if expecting a statement and found a slash as operator,
    ;; it must be a literal regexp.
    (when (and (eq (token-type token) :operator)
               (eq (token-value token) :/))
      (setf peeked nil
            token (funcall input t)))
    (case (token-type token)
      ((:num :string :regexp :operator :atom) (simple-statement))
      (:name (if (tokenp (peek) :punc #\:)
                 (let ((label (prog1 (token-value token) (skip 2))))
                   (as :label label (with-label-scope :label label (statement label))))
                 (simple-statement)))
      (:punc (case (token-value token)
               (#\{ (next) (block*))
               ((#\[ #\() (simple-statement))
               (#\; (next) (as :block ()))
               (t (unexpected token))))
      (:keyword
       (case (prog1 (token-value token) (next))
         (:break (break/cont :break))
         (:continue (break/cont :continue))
         (:debugger (semicolon) (as :debugger))
         (:do (let ((body (with-label-scope :loop label (statement))))
                (expect-key :while)
                (as :do (parenthesised) body)))
         (:for (for* label))
         (:function (function* t))
         (:if (if*))
         (:return (unless *in-function* (error* "'return' outside of function."))
                  (as :return
                      (cond ((semicolonp) (next) nil)
                            ((can-insert-semicolon) nil)
                            (t (prog1 (expression) (semicolon))))))
         (:switch (let ((val (parenthesised))
                        (cases nil))
                    (with-label-scope :switch label
                      (expect #\{)
                      (loop :until (tokenp token :punc #\}) :do
                         (case (token-value token)
                           (:case (next)
                             (push (cons (prog1 (expression) (expect #\:)) nil) cases))
                           (:default (next) (expect #\:) (push (cons nil nil) cases))
                           (t (unless cases (unexpected token))
                              (push (statement) (cdr (car cases))))))
                      (next)
                      (as :switch val (loop :for case :in (nreverse cases) :collect
                                         (cons (car case) (nreverse (cdr case))))))))
         (:throw (let ((ex (expression))) (semicolon) (as :throw ex)))
         (:try (try*))
         (:var (prog1 (var*) (semicolon)))
         (:while (as :while (parenthesised) (with-label-scope :loop label (statement))))
         (:with (as :with (parenthesised) (statement)))
         (t (unexpected token))))
      (t (unexpected token))))

  (def simple-statement ()
    (let ((exp (expression)))
      (semicolon)
      (as :stat exp)))

  (def break/cont (type)
    (as type (cond ((or (and (semicolonp) (next)) (can-insert-semicolon))
                    (unless (loop :for (ltype) :in *label-scope* :do
                               (when (or (eq ltype :loop) (and (eq type :break) (eq ltype :switch)))
                                 (return t)))
                      (error* "'~a' not inside a loop or switch." type))
                    nil)
                   ((token-type-p token :name)
                    (let ((name (token-value token)))
                      (ecase type
                        (:break (unless (some (lambda (lb) (equal (cdr lb) name)) *label-scope*)
                                  (error* "Labeled 'break' without matching labeled statement.")))
                        (:continue (unless (find (cons :loop name) *label-scope* :test #'equal)
                                     (error* "Labeled 'continue' without matching labeled loop."))))
                      (next) (semicolon)
                      name)))))

  (def block* ()
    (prog1 (as :block (loop :until (tokenp token :punc #\})
                         :collect (statement)))
      (next)))

  (def for-in (label init lhs)
    (let ((obj (progn (next) (expression))))
      (expect #\))
      (as :for-in init lhs obj (with-label-scope :loop label (statement)))))

  (def regular-for (label init)
    (expect #\;)
    (let ((test (prog1 (unless (semicolonp) (expression)) (expect #\;)))
          (step (if (tokenp token :punc #\)) nil (expression))))
      (expect #\))
      (as :for init test step (with-label-scope :loop label (statement)))))

  (def for* (label)
    (expect #\()
    (cond ((semicolonp) (regular-for label nil))
          ((tokenp token :keyword :var)
           (let* ((var (progn (next) (var* t)))
                  (defs (second var)))
             (if (and (not (cdr defs)) (tokenp token :operator :in))
                 (for-in label var (as :name (caar defs)))
                 (regular-for label var))))
          (t (let ((init (expression t t)))
               (if (tokenp token :operator :in)
                   (for-in label nil init)
                   (regular-for label init))))))

  (def function* (statement)
    (with-defs
      (def name (and (token-type-p token :name)
                     (prog1 (token-value token) (next))))
      (when (and statement (not name)) (unexpected token))
      (expect #\()
      (def argnames (loop :for first := t :then nil
                       :until (tokenp token :punc #\))
                       :unless first :do (expect #\,)
                       :unless (token-type-p token :name) :do (unexpected token)
                       :collect (prog1 (token-value token) (next))))
      (next)
      (expect #\{)
      (def body (let ((*in-function* t) (*label-scope* ()))
                  (loop :until (tokenp token :punc #\}) :collect (statement))))
      (next)
      (as (if statement :defun :function) name argnames body)))

  (def if* ()
    (let ((condition (parenthesised))
          (body (statement))
          else)
      (when (tokenp token :keyword :else)
        (next)
        (setf else (statement)))
      (as :if condition body else)))

  (def ensure-block ()
    (expect #\{)
    (block*))

  (def try* ()
    (let ((body (ensure-block)) catch finally)
      (when (tokenp token :keyword :catch)
        (next) (expect #\()
        (unless (token-type-p token :name) (error* "Name expected."))
        (let ((name (token-value token)))
          (next) (expect #\))
          (setf catch (cons name (ensure-block)))))
      (when (tokenp token :keyword :finally)
        (next)
        (setf finally (ensure-block)))
      (as :try body catch finally)))

  (def vardefs (no-in)
    (unless (token-type-p token :name) (unexpected token))
    (let ((name (token-value token)) val)
      (next)
      (when (tokenp token :operator :=)
        (next) (setf val (expression nil no-in)))
      (if (tokenp token :punc #\,)
          (progn (next) (cons (cons name val) (vardefs no-in)))
          (list (cons name val)))))

  (def var* (&optional no-in)
    (as :var (vardefs no-in)))

  (def new* ()
    (let ((newexp (expr-atom nil)))
      (let ((args nil))
        (when (tokenp token :punc #\()
          (next) (setf args (expr-list #\))))
        (subscripts (as :new newexp args) t))))

  (def macro-body ()
    (let ((*in-function* t))
      (let ((body (loop
                     until (and (eq :punc (token-type token))
                                (char= #\) (token-value token)))
                     collect (statement))))
        (unless (and (eq :punc (token-type token))
                     (char= #\) (token-value token)))
          (token-error token "Expected ')', but read token '~a'."
                       (token-id token)))
        (next) ;; The close paren.
        body)))

  (def macro-vars (closing-char &optional alternate-closing-char)
    (let ((args (loop
                   until (and (eq :punc (token-type token))
                              (or (char= closing-char (token-value token))
                                  (and alternate-closing-char
                                       (char= alternate-closing-char
                                              (token-value token)))))
                   collect (expression nil)
                   when (and (eq :punc (token-type token))
                             (char= #\, (token-value token)))
                   do (next))))
      (let ((actual-closing-char (token-value token)))
        (unless (and (eq :punc (token-type token))
                     (or (char= closing-char (token-value token))
                         (and alternate-closing-char
                              (char= alternate-closing-char
                                     (token-value token)))))
          (if alternate-closing-char
              (token-error token "Expected '~a' or '~a', but read token '~a'."
                           closing-char alternate-closing-char
                           (token-id token))
              (token-error token "Expected '~a', but read token '~a'."
                           closing-char
                           (token-id token))))
        (next)
        ;; The semicolon between args and body (or the closing paren).
        (values args actual-closing-char))))

  (def macro-custom-parse ()
    (when (and (eq (token-type token) :name)
               *macro-hook*)
      (ecase (funcall *macro-hook* (token-value token))
        ((:not-a-macro))
        ((:body)
         (let ((name-token token))
           (next) ;; The name.
           (next) ;; The open paren.
           (let ((body (macro-body)))
             (list :macro-call
                   (list (token-type name-token)
                         (token-value name-token))
                   (list* :body body)))))
        ((:args-and-body)
         (let ((name-token token))
           (next) ;; The name.
           (next) ;; The open paren.
           (multiple-value-bind (vars actual-closing-char)
               (macro-vars #\; #\))
             (let ((body (if (char= #\; actual-closing-char)
                             (macro-body))))
               (list :macro-call
                     (list (token-type name-token)
                           (token-value name-token))
                     (list (list* :args vars)
                           (list* :body body)))))))
        ((:args)
         (let ((name-token token))
           (next) ;; The name.
           (next) ;; The open paren.
           (let ((vars (macro-vars #\))))
             (list :macro-call
                   (list (token-type name-token)
                         (token-value name-token))
                   (list* :args vars))))))))

  (def expr-atom (allow-calls)
    (cond ((tokenp token :operator :new) (next) (new*))
          ((token-type-p token :punc)
           (case (token-value token)
             (#\( (next) (subscripts (prog1 (expression) (expect #\))) allow-calls))
             (#\[ (next) (subscripts (array*) allow-calls))
             (#\{ (next) (subscripts (object*) allow-calls))
             (t (unexpected token))))
          ((tokenp token :keyword :function)
           (next)
           (subscripts (function* nil) allow-calls))
          ((member (token-type token) '(:atom :num :string :regexp :name))
           (or (macro-custom-parse)
               (let ((atom (if (eq (token-type token) :regexp)
                               (as :regexp (car (token-value token)) (cdr (token-value token)))
                               (as (token-type token) (token-value token)))))
                 (subscripts (prog1 atom (next)) allow-calls))))
          (t (unexpected token))))

  (def expr-list (closing &optional allow-trailing-comma allow-empty)
    (let ((elts ()))
      (loop :for first := t :then nil :until (tokenp token :punc closing) :do
         (unless first (expect #\,))
         (when (and allow-trailing-comma (tokenp token :punc closing)) (return))
         (push (unless (and allow-empty (tokenp token :punc #\,)) (expression nil)) elts))
      (next)
      (nreverse elts)))

  (def array* ()
    (as :array (expr-list #\] t t)))

  (def object* ()
    (as :object (loop :for first := t :then nil
                   :until (tokenp token :punc #\})
                   :unless first :do (expect #\,)
                   :until (tokenp token :punc #\}) :collect
                   (let ((name (as-property-name)))
                     (cond ((tokenp token :punc #\:)
                            (next) (cons name (expression nil)))
                           ((and (eql *ecma-version* 5) (or (equal name "get") (equal name "set")))
                            (let ((name1 (as-property-name))
                                  (body (progn (unless (tokenp token :punc #\() (unexpected token))
                                               (function* nil))))
                              (list* name1 (if (equal name "get") :get :set) body)))
                           (t (unexpected token))))
                   :finally (next))))

  (def as-property-name ()
    (if (member (token-type token) '(:num :string))
        (prog1 (token-value token) (next))
        (as-name)))

  (def as-name ()
    (case (token-type token)
      (:name (prog1 (token-value token) (next)))
      ((:operator :keyword :atom) (prog1 (string-downcase (symbol-name (token-value token))) (next)))
      (t (unexpected token))))

  (def subscripts (expr allow-calls)
    (cond ((tokenp token :punc #\.)
           (next)
           (subscripts (as :dot expr (as-name)) allow-calls))
          ((tokenp token :punc #\[)
           (next)
           (let ((sub (expression)))
             (expect #\])
             (subscripts (as :sub expr sub) allow-calls)))
          ((and (tokenp token :punc #\() allow-calls)
           (next)
           (let ((args (expr-list #\))))
             (subscripts (as :call expr args) t)))
          (t expr)))

  (def maybe-unary (allow-calls)
    (if (and (token-type-p token :operator) (member (token-value token) *unary-prefix*))
        (as :unary-prefix (prog1 (token-value token) (next)) (maybe-unary allow-calls))
        (let ((val (expr-atom allow-calls)))
          (loop :while (and (token-type-p token :operator)
                            (member (token-value token) *unary-postfix*)
                            (not (token-newline-before token))) :do
             (setf val (as :unary-postfix (token-value token) val))
             (next))
          val)))

  (def expr-op (left min-prec no-in)
    (let* ((op (and (token-type-p token :operator) (or (not no-in) (not (eq (token-value token) :in)))
                    (token-value token)))
           (prec (and op (gethash op *precedence*))))
      (if (and prec (> prec min-prec))
          (let ((right (progn (next) (expr-op (maybe-unary t) prec no-in))))
            (expr-op (as :binary op left right) min-prec no-in))
          left)))

  (def expr-ops (no-in)
    (expr-op (maybe-unary t) 0 no-in))

  (def maybe-conditional (no-in)
    (let ((expr (expr-ops no-in)))
      (if (tokenp token :operator :?)
          (let ((yes (progn (next) (expression nil))))
            (expect #\:)
            (as :conditional expr yes (expression nil no-in)))
          expr)))

  (def maybe-assign (no-in)
    (let ((left (maybe-conditional no-in)))
      (if (and (token-type-p token :operator) (gethash (token-value token) *assignment*))
          (as :assign (gethash (token-value token) *assignment*) left (progn (next) (maybe-assign no-in)))
          left)))

  (def expression (&optional (commas t) (no-in nil))
    (let ((expr (maybe-assign no-in)))
      (if (and commas (tokenp token :punc #\,))
          (as :seq expr (progn (next) (expression)))
          expr)))

  (as :toplevel (loop :until (token-type-p token :eof)
                   :collect (statement))))

(defun parse-js-string (&rest args)
  (apply 'parse-js args))
