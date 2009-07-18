;;; makefile-edit.el --- Makefile editing/scanning commands.
;;
;; Copyright (C) 2009 Eric M. Ludlam
;;
;; Author: Eric M. Ludlam <eric@siege-engine.com>
;; X-RCS: $Id: makefile-edit.el,v 1.1 2009/07/18 16:59:14 zappo Exp $
;;
;; This program is free software; you can redistribute it and/or
;; modify it under the terms of the GNU General Public License as
;; published by the Free Software Foundation; either version 2, or (at
;; your option) any later version.

;; This program is distributed in the hope that it will be useful, but
;; WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;; General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program; see the file COPYING.  If not, write to
;; the Free Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
;; Boston, MA 02110-1301, USA.

;;; Commentary:
;;
;; Utilities for editing a Makefile for EDE Makefile management commands.
;;
;; Derived from project-am.el.
;;
;; Makefile editing and scanning commands
;;
;; Formatting of a makefile
;;
;; 1) Creating an automakefile, stick in a top level comment about
;;    being created by emacs
;; 2) Leave order of variable contents alone, except for SOURCE
;;    SOURCE always keep in the order of .c, .h, the other stuff.

;;; Things to do
;; makefile-fill-paragraph -- refill a macro w/ backslashes
;; makefile-insert-macro -- insert "foo = "


;;; Code:

(defun makefile-beginning-of-command ()
  "Move the the beginning of the current command."
  (interactive)
  (if (save-excursion
	(forward-line -1)
	(makefile-line-continued-p))
      (forward-line -1))
  (beginning-of-line)
  (if (not (makefile-line-continued-p))
      nil
    (while (and (makefile-line-continued-p)
		(not (bobp)))
      (forward-line -1))
    (forward-line 1)))

(defun makefile-end-of-command ()
  "Move the the beginning of the current command."
  (interactive)
  (end-of-line)
  (while (and (makefile-line-continued-p)
	      (not (eobp)))
    (forward-line 1)
    (end-of-line)))

(defun makefile-line-continued-p ()
  "Return non-nil if the current line ends in continuation."
  (save-excursion
    (end-of-line)
    (= (preceding-char) ?\\)))

;;; Programatic editing of a Makefile
;;
(defun makefile-move-to-macro (macro &optional next)
  "Move to the definition of MACRO.  Return t if found.
If NEXT is non-nil, move to the next occurance of MACRO."
  (let ((oldpt (point)))
    (when (not next) (goto-char (point-min)))
    (if (re-search-forward (concat "^\\s-*" macro "\\s-*[+:?]?=") nil t)
	t
      (goto-char oldpt)
      nil)))

(defun makefile-navigate-macro (stop-before)
  "In a list of files, move forward until STOP-BEFORE is reached.
STOP-BEFORE is a regular expression matching a file name."
  (save-excursion
    (makefile-beginning-of-command)
    (let ((e (save-excursion
	       (makefile-end-of-command)
	       (point))))
      (if (re-search-forward stop-before nil t)
	  (goto-char (match-beginning 0))
	(goto-char e)))))

(defun makefile-macro-file-list (macro)
  "Return a list of all files in MACRO."
  (save-excursion
    (goto-char (point-min))
    (let ((lst nil))
      (while (makefile-move-to-macro macro t)
	(let ((e (save-excursion
		   (makefile-end-of-command)
		   (point))))
	  (while (re-search-forward "\\s-**\\([-a-zA-Z0-9./_@$%()]+\\)\\s-*" e t)
	    (let ((var nil)(varexp nil)
		  (match (buffer-substring-no-properties
			  (match-beginning 1)
			  (match-end 1))))
	      (if (not (setq var (project-am-extract-varname match)))
		  (setq lst (cons match lst))
		(setq varexp (makefile-macro-file-list var))
		(dolist (V varexp)
		  (setq lst (cons V lst))))))))
      (nreverse lst))))

(provide 'makefile-edit)
;;; makefile-edit.el ends here
