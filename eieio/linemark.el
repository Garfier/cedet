;;; linemark.el --- Manage groups of lines with marks.
;;
;; Author: Eric M. Ludlam <eludlam@mathworks.com>
;; Maintainer: Eric M. Ludlam <eludlam@mathworks.com>
;; Created: Dec 1999
;; Keywords: lisp
;;
;; Copyright (C) 1999, 2001, 2002 Eric M. Ludlam
;;
;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 2, or (at your option)
;; any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs; see the file COPYING.  If not, write to
;; the Free Software Foundation, 675 Mass Ave, Cambridge, MA 02139, USA.
;;
;;; Commentary:
;;
;; This is a library of routines which help Lisp programmers manage
;; groups of marked lines.  Common uses for marked lines are debugger
;; breakpoints and watchpoints, or temporary line highlighting.  It
;; could also be used to select elements from a list.
;;
;; The reason this tool is useful is because cross-emacs overlay
;; management can be a pain, and overlays are certainly needed for use
;; with font-lock.

(require 'eieio)

;;; Code:
(eval-and-compile
  ;; These faces need to exist to show up as valid default
  ;; entries in the classes defined below.

(defface linemark-stop-face '((((class color) (background light))
			       (:background "red4"))
			      (((class color) (background dark))
			       (:background "red3")))
  "*Face used to indicate a STOP type line.")

(defface linemark-caution-face '((((class color) (background light))
				  (:background "yellow3"))
				 (((class color) (background dark))
				  (:background "yellow" :foreground "black")))
  "*Face used to indicate a CAUTION type line.")
				  
(defface linemark-go-face '((((class color) (background light))
			     (:background "green4"))
			    (((class color) (background dark))
			     (:background "green4")))
  "*Face used to indicate a GO, or OK type line.")

(defface linemark-funny-face '((((class color) (background light))
				(:background "cyan"))
			       (((class color) (background dark))
				(:background "blue")))
  "*Face used to indicate a GO, or OK type line.")

)

(defclass linemark-entry ()
  ((filename :initarg :filename
	     :type string
	     :documentation "File name for this mark.")
   (line     :initarg :line
	     :type number
	     :documentation "Line number where the mark is.")
   (face     :initarg :face
	     :type face
	     :initarg linemark-caution-face
	     :documentation "The face to use for display.")
   (parent   :documentation "The parent `linemark-group' containing this."
	     :type linemark-group)
   (overlay  :documentation "Overlay created to show this mark."
	     :type (or overlay null)
	     :initform nil
	     :protection protected))
  "Track a file/line associations with overlays used for display.")

(defclass linemark-group ()
  ((marks :initarg :marks
	  :type list
	  :initform nil
	  :documentation "List of `linemark-entries'.")
   (face :initarg :face
	 :initform linemark-funny-face
	 :type (or null face)
	 :documentation "Default face used to create new `linemark-entries'.")
   (active :initarg :active
	   :type boolean
	   :initform t
	   :documentation "Track if these marks are active or not."))
  "Track a common group of `linemark-entries'.")

;; Compatibility
(if (featurep 'xemacs)
    (progn
      (defalias 'linemark-overlay-live-p 'extent-live-p)
      (defalias 'linemark-make-overlay 'make-extent)
      (defalias 'linemark-overlay-put 'set-extent-property)
      (defalias 'linemark-overlay-get 'extent-property)
      (defalias 'linemark-delete-overlay 'delete-extent)
      (defalias 'linemark-overlays-at
        (lambda (pos) (extent-list nil pos pos)))
      (defalias 'linemark-overlays-in 
	(lambda (beg end) (extent-list nil beg end)))
      (defalias 'linemark-overlay-buffer 'extent-buffer)
      (defalias 'linemark-overlay-start 'extent-start-position)
      (defalias 'linemark-overlay-end 'extent-end-position)
      (defalias 'linemark-next-overlay-change 'next-extent-change)
      (defalias 'linemark-previous-overlay-change 'previous-extent-change)
      (defalias 'linemark-overlay-lists
	(lambda () (list (extent-list))))
      (defalias 'linemark-overlay-p 'extentp)
      )
  (defalias 'linemark-overlay-live-p 'overlay-buffer)
  (defalias 'linemark-make-overlay 'make-overlay)
  (defalias 'linemark-overlay-put 'overlay-put)
  (defalias 'linemark-overlay-get 'overlay-get)
  (defalias 'linemark-delete-overlay 'delete-overlay)
  (defalias 'linemark-overlays-at 'overlays-at)
  (defalias 'linemark-overlays-in 'overlays-in)
  (defalias 'linemark-overlay-buffer 'overlay-buffer)
  (defalias 'linemark-overlay-start 'overlay-start)
  (defalias 'linemark-overlay-end 'overlay-end)
  (defalias 'linemark-next-overlay-change 'next-overlay-change)
  (defalias 'linemark-previous-overlay-change 'previous-overlay-change)
  (defalias 'linemark-overlay-lists 'overlay-lists)
  (defalias 'linemark-overlay-p 'overlayp)
  )

;;; Functions
;;
(defvar linemark-groups nil
  "List of groups we need to track.")

(defun linemark-create-group (name &optional defaultface)
  "Create a group object for tracking linemark entries.
Do not permit multiple groups with the same name."
  (let ((newgroup (if (facep defaultface)
		      (linemark-group name :face defaultface)
		    (linemark-group name)))
	(foundgroup nil)
	(lmg linemark-groups))
    (while (and (not foundgroup) lmg)
      (if (string= name (object-name-string (car lmg)))
	  (setq foundgroup (car lmg)))
      (setq lmg (cdr lmg)))
    (if foundgroup
	(setq newgroup foundgroup)
      (setq linemark-groups (cons newgroup linemark-groups))
      newgroup)))

(defun linemark-at-point (&optional pos group)
  "Return the current variable `linemark-entry' at point.
Optional POS is the position to check which defaults to point.
If GROUP, then make sure it also belongs to GROUP."
  (if (not pos) (setq pos (point)))
  (let ((o (linemark-overlays-at pos))
	(found nil))
    (while (and o (not found))
      (let ((og (linemark-overlay-get (car o) 'obj)))
	(if (and og (linemark-entry-child-p og))
	    (progn
	      (setq found og)
	      (if group
		  (if (not (eq group (oref found parent)))
		      (setq found nil)))))
	(setq o (cdr o))))
    found))

(defun linemark-next-in-buffer (group &optional arg wrap)
  "Return the next mark in this buffer belonging to GROUP.
If ARG, then find that manu marks forward or backward.
Optional WRAP argument indicates that we should wrap around the end of
the buffer."
  (if (not arg) (setq arg 1)) ;; default is one forward
  (let ((entry nil)
	(nc (point))
	(oll nil)
	(dir (if (< 0 arg) 1 -1))
	(ofun (if (> 0 arg)
		  'linemark-previous-overlay-change
		'linemark-next-overlay-change))
	(bounds (if (< 0 arg) (point-min) (point-max)))
	)
    (catch 'moose
      (while (and (not entry) (/= arg 0))
	(setq nc (funcall ofun nc))
	(setq entry (linemark-at-point nc group))
	(if (not entry)
	    (if (or (= nc (point-min)) (= nc (point-max)))
		(if (not wrap)
		    (throw 'moose t)
		  (setq wrap nil ;; only wrap once
			nc bounds))))
	;; Ok, now decrement arg, and keep going.
	(if entry (setq arg (- arg dir)))))
    entry))

;;; Methods that make things go
;;
(defmethod linemark-add-entry ((g linemark-group) &optional file line face)
  "Add a `linemark-entry' to G.
It will be at location FILE and LINE, and use optional FACE.
Call the new entrie's activate method."
  (if (not file) (setq file (buffer-file-name)))
  (if (not file) (error "You can only add marks to files."))
  (setq file (expand-file-name file))
  (when (not line)
    (setq line (count-lines (point-min) (point)))
    (if (bolp) (setq line (1+ line))))
  (let ((new-entry (linemark-new-entry g
				       :filename file
				       :line line)))
    (oset new-entry parent g)
    (oset new-entry face  (if face face (oref g face)))
    (oset g marks (cons new-entry (oref g marks)))
    (if (oref g active)
	(linemark-display new-entry t))))

(defmethod linemark-new-entry ((g linemark-group) &optional args)
  "Create a new entry for G using init ARGS."
  (let ((f (plist-get args :file))
	(l (plist-get args :line)))
    (apply 'linemark-entry (format "%s %d" f l)
	   args)))

(defmethod linemark-display ((g linemark-group) active-p)
  "Set object G to be active or inactive."
  (mapcar (lambda (g) (linemark-display g active-p)) (oref g marks))
  (oset g active active-p))

(defmethod linemark-display ((e linemark-entry) active-p)
  "Set object E to be active or inactive."
  (if active-p
      (with-slots ((file filename)) e
	(if (oref e overlay)
	    ;; Already active
	    nil
	  (if (get-file-buffer file)
	      (save-excursion
		(set-buffer (get-file-buffer file))
		(goto-line (oref e line))
		(beginning-of-line)
		(oset e overlay
		      (linemark-make-overlay (point)
					     (save-excursion
					       (end-of-line) (point))
					     (current-buffer)))
		(with-slots (overlay) e
		  (linemark-overlay-put overlay 'face (oref e face))
		  (linemark-overlay-put overlay 'obj e)
		  (linemark-overlay-put overlay 'tag 'linemark))))))
    ;; Not active
    (with-slots (overlay) e
      (if overlay
	  (progn
	    (linemark-delete-overlay overlay)
	    (oset e overlay nil))))))

(defmethod linemark-delete ((g linemark-group))
  "Remove group G from linemark tracking."
  (mapcar 'linemark-delete (oref g marks))
  (setq linemark-groups (delete g linemark-groups)))

(defmethod linemark-delete ((e linemark-entry))
  "Remove entry E from it's parent group."
  (with-slots (parent) e
    (oset parent marks (delq e (oref parent marks)))
    (linemark-display e nil)))

;;; Trans buffer tracking
;;
;; This section sets up a find-file-hook and a kill-buffer-hook
;; so that marks that aren't displayed (because the buffer doesn't
;; exist) are displayed when said buffer appears, and that overlays
;; are removed when the buffer buffer goes away.

(defun linemark-find-file-hook ()
  "Activate all marks which can benifit from this new buffer."
  (mapcar (lambda (g) (linemark-display g t)) linemark-groups))

(defun linemark-kill-buffer-hook ()
  "Deactivate all entries in the current buffer."
  (let ((o (linemark-overlays-in (point-min) (point-max)))
	(to nil))
    (while o
      (setq to (linemark-overlay-get (car o) 'obj))
      (if (and to (linemark-entry-child-p to))
	  (linemark-display to nil))
      (setq o (cdr o)))))

(add-hook 'find-file-hooks 'linemark-find-file-hook)
(add-hook 'kill-buffer-hook 'linemark-kill-buffer-hook)

;;; Demo mark tool: Emulate MS Visual Studio bookmarks
;;
(defvar viss-bookmark-group (linemark-create-group "viss")
  "The VISS bookmark group object.")

(defun viss-bookmark-toggle ()
  "Toggle a bookmark on the current line."
  (interactive)
  (let ((ce (linemark-at-point (point) viss-bookmark-group)))
    (if ce
	(linemark-delete ce)
      (linemark-add-entry viss-bookmark-group))))

(defun viss-bookmark-next-buffer ()
  "Move to the next bookmark in this buffer."
  (interactive)
  (let ((n (linemark-next-in-buffer viss-bookmark-group 1 t)))
    (if n (goto-line (oref n line)) (ding))))

(defun viss-bookmark-prev-buffer ()
  "Move to the next bookmark in this buffer."
  (interactive)
  (let ((n (linemark-next-in-buffer viss-bookmark-group -1 t)))
    (if n (goto-line (oref n line)) (ding))))

(defun viss-bookmark-clear-all-buffer ()
  "Clear all bookmarks in this buffer."
  (interactive)
  (mapcar (lambda (e)
	    (if (string= (oref e filename) (buffer-file-name))
		(linemark-delete e)))
	  (oref viss-bookmark-group marks)))

;; These functions only sort of worked and were not really useful to me.
;;
;;(defun viss-bookmark-next ()
;;  "Move to the next bookmark."
;;  (interactive)
;;  (let ((c (linemark-at-point (point) viss-bookmark-group))
;;	  (n nil))
;;    (if c
;;	  (let ((n (member c (oref viss-bookmark-group marks))))
;;	    (if n (setq n (car (cdr n)))
;;	      (setq n (car (oref viss-bookmark-group marks))))
;;	    (if n (goto-line (oref n line)) (ding)))
;;	;; if no current mark, then just find a local one.
;;	(viss-bookmark-next-buffer))))
;;
;;(defun viss-bookmark-prev ()
;;  "Move to the next bookmark."
;;  (interactive)
;;  (let ((c (linemark-at-point (point) viss-bookmark-group))
;;	  (n nil))
;;    (if c
;;	  (let* ((marks (oref viss-bookmark-group marks))
;;		 (n (member c marks)))
;;	    (if n
;;		(setq n (- (- (length marks) (length n)) 1))
;;	      (setq n (car marks)))
;;	    (if n (goto-line (oref n line)) (ding)))
;;	;; if no current mark, then just find a local one.
;;	(viss-bookmark-prev-buffer))))
;;
;;(defun viss-bookmark-clear-all ()
;;  "Clear all viss bookmarks."
;;  (interactive)
;;  (mapcar (lambda (e) (linemark-delete e))
;;	    (oref viss-bookmark-group marks)))
;;

(defun enable-visual-studio-bookmarks ()
  "Bind the viss bookmark functions to F2 related keys.
\\<global-map>
\\[viss-bookmark-toggle]     - Toggle a bookmark on this line.
\\[viss-bookmark-next]   - Move to the next bookmark.
\\[viss-bookmark-prev]   - Move to the previous bookmark.
\\[viss-bookmark-clear-all] - Clear all bookmarks."
  (interactive)
  (define-key global-map [(f2)] 'viss-bookmark-toggle)
  (define-key global-map [(shift f2)] 'viss-bookmark-prev-buffer)
  (define-key global-map [(control f2)] 'viss-bookmark-next-buffer)
  (define-key global-map [(control shift f2)] 'viss-bookmark-clear-all-buffer)
)

(provide 'linemark)

;;; linemark.el ends here
