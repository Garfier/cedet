;;; ede-ede-grammar.el --- EDE support for Semantic Grammar Files

;;;  Copyright (C) 2003  Eric M. Ludlam

;; Author: Eric M. Ludlam <zappo@gnu.org>
;; Keywords: project, make
;; RCS: $Id: semantic-ede-grammar.el,v 1.1 2003/08/17 02:48:05 zappo Exp $

;; This software is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 2, or (at your option)
;; any later version.

;; This software is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs; see the file COPYING.  If not, write to the
;; Free Software Foundation, Inc., 59 Temple Place - Suite 330,
;; Boston, MA 02111-1307, USA.

;;; Commentary:
;;
;; Handle .by or .wy files.

(require 'ede-proj)
(require 'ede-pmake)
(require 'ede-pconf)
(require 'ede-proj-elisp)
(require 'semantic-grammar)

;;; Code:
(defclass semantic-ede-proj-target-grammar (ede-proj-target-makefile)
  ((menu :initform nil)
   (keybindings :initform nil)
   (phony :initform t)
   (sourcetype :initform (semantic-ede-source-grammar))
   (availablecompilers :initform (semantic-ede-grammar-compiler))
   )
  "This target consists of a group of grammar files.
A grammar target consists of grammar files that build Emacs Lisp programs for
parsing different languages.")

(defvar semantic-ede-source-grammar
  (ede-sourcecode "semantic-ede-grammar-source"
		  :name "Semantic Grammar"
		  :sourcepattern "\\.wy$"
		  )
  "Semantic Grammar source code definition.")

(defclass semantic-ede-grammar-compiler-class (ede-compiler)
  nil
  "Specialized compiler for semamtic grammars.")

(defvar semantic-ede-grammar-compiler
  (semantic-ede-grammar-compiler-class
   "ede-emacs-wisent-compiler"
   :name "emacs"
   :variables '(("EMACS" . "emacs"))
   :commands
   '("@")
   ;; :autoconf '("AM_PATH_LISPDIR")
   :sourcetype '(semantic-ede-source-grammar)
   :objectextention "-wy.elc"
   :rules (list (ede-makefile-rule
		 "wisent-inference-rule"
		 :target "%-wy.el"
		 :dependencies "%.wy"
		 :rules
		 '(
		   "@echo \"(add-to-list 'load-path nil)\" > grammar-make-script"
		   "@for loadpath in . ${LOADPATH}; do \\"
		   "   echo \"(add-to-list 'load-path \\\"$$loadpath\\\")\" >> grammar-make-script; \\"
		   "done;"
		   "@echo \"(require 'semantic-load)\" >> grammar-make-script"
		   "@echo \"(require 'semantic-grammar)\" >> grammar-make-script"
		   "@echo \"(setq debug-on-error t)\" >> grammar-make-script"
		   "${EMACS} -batch -q -l wisent-make-script $< -f semantic-grammar-create-package -f save-buffer"
		   )
		 )
		(ede-makefile-rule
		 "wisent-inference-emacslisp-rule"
		 :target "%-wy.elc"
		 :dependencies "%-wy.el"
		 :rules
		 '(
		   "@echo \"(add-to-list 'load-path nil)\" > $@-compile-script"
		   "@for loadpath in . ${LOADPATH}; do \\"
		   "   echo \"(add-to-list 'load-path \\\"$$loadpath\\\")\" >> $@-compile-script; \\"
		   "done;"
		   "@echo \"(setq debug-on-error t)\" >> $@-compile-script"
		   "$(EMACS) -batch -l $@-compile-script -f batch-byte-compile $^"
		   )
		 )
		)
   )
  "Compile Emacs Lisp programs.")

;;; Specialized compiler options
(defmethod ede-compiler-intermediate-objects-p
  ((this semantic-ede-grammar-compiler-class))
  "We have intermediate files for this class of target."
  t)

(defmethod ede-compiler-intermediate-object-variable ((this semantic-ede-grammar-compiler-class)
						      targetname)
  "Return a string based on THIS representing a make object variable.
TARGETNAME is the name of the target that these objects belong to."
  (concat targetname "_SEMANTIC_GRAMMAR_ELC"))

;;; Target options.
(defmethod project-compile-target ((obj semantic-ede-proj-target-grammar))
  "Compile all sources in a Lisp target OBJ."
  (let ((cb (current-buffer)))
    (mapcar (lambda (src)
	      (save-excursion
		(set-buffer (find-file-noselect src))
		(let ((cf (concat (semantic-grammar-package) ".el")))
		  (if (or (not (file-exists-p cf))
			  (file-newer-than-file-p src cf))
		      (byte-compile-file cf)))))
	    (oref obj source)))
  (message "All Semantic Grammar sources are up to date in %s" (object-name obj)))

;;; Makefile generation functions
;;
(defmethod ede-proj-makefile-sourcevar ((this semantic-ede-proj-target-grammar))
  "Return the variable name for THIS's sources."
  (cond ((ede-proj-automake-p)
	 (error "No Automake support for Semantic Grammars"))
	(t (concat (ede-pmake-varname this) "_SEMANTIC_GRAMMAR"))))

(defmethod ede-proj-makefile-insert-variables :AFTER ((this semantic-ede-proj-target-grammar))
  "Insert variables needed by target THIS."
  (ede-pmake-insert-variable-shared "LOADPATH"
    (insert (mapconcat 'identity
		       (ede-proj-elisp-packages-to-loadpath
			(list "eieio" "semantic" "inversion"))
		       " "))
    )
  (ede-pmake-insert-variable-shared
      (concat (ede-pmake-varname this) "_SAMENATIC_GRAMMAR_ELC")
    (insert
     (mapconcat (lambda (src)
		  (save-excursion
		    (set-buffer (find-file-noselect src))
		    (concat (semantic-grammar-package) ".elc")))
		(oref this source)
		" ")))
  )

(defmethod ede-proj-makefile-insert-rules ((this semantic-ede-proj-target-grammar))
  "Insert rules needed by THIS target."
  ;; Add in some dependencies.
  (mapc (lambda (src)
	  (let ((nm (file-name-sans-extension src)))
	    (insert nm "-wy.el: " src "\n"
		    nm "-wy.elc: " nm "-wy.el\n\n")
	    ))
	(oref this source))
  ;; Call the normal insertion of rules.
  (call-next-method)
  )

;;;###autoload
(autoload 'ede-proj-target-elisp "semantic-ede-proj-target-grammar"
  "Target class for Emacs/Semantic grammar files." nil nil)

;;;###autoload
(eval-after-load "ede-proj"
    (quote
     (ede-proj-register-target "semantic grammar"
			       semantic-ede-proj-target-grammar)
     ))

(provide 'ede-proj-elisp)

;;; ede-proj-elisp.el ends here
