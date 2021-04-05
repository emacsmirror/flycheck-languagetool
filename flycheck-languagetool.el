;;; flycheck-languagetool.el --- Flycheck support for LanguageTool  -*- lexical-binding: t; -*-

;; Copyright (C) 2021  Shen, Jen-Chieh
;; Created date 2021-04-02 23:22:44

;; Author: Shen, Jen-Chieh <jcs090218@gmail.com>
;; Description: Flycheck support for LanguageTool.
;; Keyword: grammar check
;; Version: 0.1.0
;; Package-Requires: ((emacs "25.1") (flycheck "0.14"))
;; URL: https://github.com/emacs-languagetool/flycheck-languagetool

;; This file is NOT part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:
;;
;; Flycheck support for LanguageTool.
;;

;;; Code:

(require 'flycheck)

(defgroup flycheck-languagetool nil
  "Flycheck support for LanguageTool."
  :prefix "flycheck-languagetool-"
  :group 'flycheck
  :link '(url-link :tag "Github" "https://github.com/emacs-languagetool/flycheck-languagetool"))

(defcustom flycheck-languagetool-active-modes
  '(text-mode latex-mode org-mode markdown-mode)
  "List of major mode that work with LanguageTool."
  :type 'list
  :group 'flycheck-languagetool)

(defcustom flycheck-languagetool-commandline-jar ""
  "The path of languagetool-commandline.jar."
  :type '(file :must-match t)
  :group 'flycheck-languagetool)

(defcustom flycheck-languagetool-language "en-US"
  "The language code of the text to check."
  :type '(string :tag "Language")
  :safe #'stringp
  :group 'flycheck-languagetool)
(make-variable-buffer-local 'flycheck-languagetool-language)

(defcustom flycheck-languagetool-args ""
  "Extra argument pass in to command line tool."
  :type 'string
  :group 'flycheck-languagetool)

(defcustom flycheck-languagetool-check-time 0.8
  "How long do we call process after we done typing."
  :type 'float
  :group 'flycheck-languagetool)

(defvar-local flycheck-languagetool--done-checking t
  "If non-nil then we are currnetly in the checking process.")

(defvar-local flycheck-languagetool--timer nil
  "Timer that will tell to do the request.")

(defvar-local flycheck-languagetool--output nil
  "Copy of the JSON output.")

(defvar-local flycheck-languagetool--source-buffer nil
  "Current buffer we are currently using for grammar check.")

;;
;; (@* "Util" )
;;

(defun flycheck-languagetool--column-at-pos (&optional pt)
  "Return column at PT."
  (unless pt (setq pt (point)))
  (save-excursion (goto-char pt) (current-column)))

(defmacro flycheck-languagetool--with-source-buffer (&rest body)
  "Execute BODY inside currnet source buffer."
  (declare (indent 0) (debug t))
  `(if flycheck-languagetool--source-buffer
       (with-current-buffer flycheck-languagetool--source-buffer (progn ,@body))
     (user-error "Invalid source buffer: %s" flycheck-languagetool--source-buffer)))

(defun flycheck-languagetool--async-shell-command-to-string (callback cmd &rest args)
  "Asnyc version of function `shell-command-to-string'.

Argument CALLBACK is called after command is done executing.
Argument CMD is the name of the command executable.
Rest argument ARGS is the rest of the argument for CMD."
  (lexical-let
      ((output-buffer (generate-new-buffer " *temp*"))
       (callback-fun callback))
    (set-process-sentinel
     (start-process "Shell" output-buffer shell-file-name shell-command-switch
                    (concat cmd " " (mapconcat #'shell-quote-argument args " ")))
     (lambda (process signal)
       (when (memq (process-status process) '(exit signal))
         (with-current-buffer output-buffer
           (let ((output-string (buffer-substring-no-properties (point-min) (point-max))))
             (funcall callback-fun output-string)))
         (kill-buffer output-buffer))))
    output-buffer))

;;
;; (@* "Core" )
;;

(defun flycheck-languagetool--dos-coding-p ()
  "Return non-nil if coding system is DOS, using \r\n."
  (string-match-p "dos" (symbol-name buffer-file-coding-system)))

(defun flycheck-languagetool--check-all ()
  "Check grammar for buffer document."
  (let ((matches (cdr (assoc 'matches flycheck-languagetool--output)))
        check-list)
    (dolist (match matches)
      (let* ((pt-beg (1+ (cdr (assoc 'offset match))))
             ;; TODO: The calculation is cause by LanguageTool,
             ;; see https://github.com/languagetool-org/languagetool/issues/991
             ;; for more information.
             (pt-beg (if (flycheck-languagetool--dos-coding-p)
                         (- pt-beg (1- (line-number-at-pos pt-beg)))
                       pt-beg))
             (len (cdr (assoc 'length match)))
             (pt-end (+ pt-beg len))
             (ln (line-number-at-pos pt-beg))
             (type 'warning)
             (desc (cdr (assoc 'message match)))
             (col-start (flycheck-languagetool--column-at-pos pt-beg))
             (col-end (flycheck-languagetool--column-at-pos pt-end)))
        (push (list ln col-start type desc :end-column col-end)
              check-list)))
    check-list))

(defun flycheck-languagetool--cache-parse-result (output)
  "Refressh cache buffer from OUTPUT."
  (setq flycheck-languagetool--output (car (flycheck-parse-json output))
        flycheck-languagetool--done-checking t)
  (flycheck-buffer-automatically))

(defun flycheck-languagetool--send-process ()
  "Send process to LanguageTool commandline-jar."
  (if (not (file-exists-p flycheck-languagetool-commandline-jar))
      (user-error "Invalid commandline path: %s" flycheck-languagetool-commandline-jar)
    (when flycheck-languagetool--done-checking
      (setq flycheck-languagetool--done-checking nil)  ; start flag
      (flycheck-languagetool--with-source-buffer
        (let ((source (current-buffer)))
          (flycheck-languagetool--async-shell-command-to-string
           (lambda (output)
             (with-current-buffer source
               (flycheck-languagetool--cache-parse-result output)))
           (format "java -jar %s %s --json %s %s"
                   flycheck-languagetool-commandline-jar
                   (if (stringp flycheck-languagetool-language)
                       (concat "-l " flycheck-languagetool-language)
                     "-adl")
                   (buffer-file-name)
                   (if (stringp flycheck-languagetool-args) flycheck-languagetool-args ""))))))))

(defun flycheck-languagetool--start-timer ()
  "Start the timer for grammar check."
  (setq flycheck-languagetool--source-buffer (current-buffer))
  (when (timerp flycheck-languagetool--timer) (cancel-timer flycheck-languagetool--timer))
  (setq flycheck-languagetool--timer
        (run-with-idle-timer flycheck-languagetool-check-time nil
                             #'flycheck-languagetool--send-process)))

(defun flycheck-languagetool--start (checker callback)
  "Flycheck start function for CHECKER, invoking CALLBACK."
  (flycheck-languagetool--start-timer)
  (funcall
   callback 'finished
   (flycheck-increment-error-columns
    (mapcar
     (lambda (x)
       (apply #'flycheck-error-new-at `(,@x :checker ,checker)))
     (condition-case err
         (if flycheck-languagetool--done-checking
             (flycheck-languagetool--check-all)
           (flycheck-stop))
       (error (funcall callback 'errored (error-message-string err))
              (signal (car err) (cdr err))))))))

(flycheck-define-generic-checker 'languagetool
  "LanguageTool flycheck definition."
  :start #'flycheck-languagetool--start
  :modes flycheck-languagetool-active-modes)

(add-to-list 'flycheck-checkers 'languagetool)

(provide 'flycheck-languagetool)
;;; flycheck-languagetool.el ends here
