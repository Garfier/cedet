;;; semantic-analyze.el --- Analyze semantic tags against local context

;;; Copyright (C) 2000, 2001, 2002, 2003, 2004, 2005, 2007, 2008 Eric M. Ludlam

;; Author: Eric M. Ludlam <zappo@gnu.org>
;; Keywords: syntax
;; X-RCS: $Id: semantic-analyze.el,v 1.63 2008/02/02 02:44:16 zappo Exp $

;; This file is not part of GNU Emacs.

;; Semantic is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 2, or (at your option)
;; any later version.

;; This software is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs; see the file COPYING.  If not, write to the
;; Free Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
;; Boston, MA 02110-1301, USA.

;;; Commentary:
;;
;; Semantic, as a tool, provides a nice list of searchable tags.
;; That information can provide some very accurate answers if the current
;; context of a position is known.
;;
;; Semantic-ctxt provides ways of analyzing, and manipulating the
;; semantic context of a language in code.
;;
;; This library provides routines for finding intelligent answers to
;; tough problems, such as if an argument to a function has the correct
;; return type, or all possible tags that fit in a given local context.
;;

;;; Vocabulary:
;;
;; Here are some words used to describe different things in the analyzer:
;;
;; tag - A single entity
;; prefix - The beginning of a symbol, usually used to look up something
;;       incomplete.
;; type - The name of a datatype in the langauge.
;; metatype - If a type is named in a declaration like:
;;       struct moose somevariable;
;;       that name "moose" can be turned into a concrete type.
;; tag sequence - In C code, a list of dereferences, such as:
;;       this.that.theother();
;; parent - For a datatype in an OO language, another datatype
;;       inherited from.  This excludes interfaces.
;; scope - A list of tags that can be dereferenced that cannot
;;       be found from the global namespace.
;; scopetypes - A list of tags which are datatype that contain
;;       the scope.  The scopetypes need to have the scope extracted
;;       in a way that honors the type of inheritance.
;; nest/nested - When one tag is contained entirely in another.
;; 
;; context - A semantic datatype representing a point in a buffer.
;;
;; constriant - If a context specifies a specific datatype is needed,
;;       that is a constraint.
;; constants - Some datatypes define elements of themselves as a
;;       constant.  These need to be returned as there would be no
;;       other possible completions.
;;
(require 'inversion)
(eval-and-compile
  (inversion-require 'eieio "1.0"))
(require 'semantic-format)
(require 'semantic-ctxt)
(require 'semantic-sort)
(eval-when-compile (require 'semanticdb)
		   (require 'semanticdb-find))

(require 'semantic-scope)
(require 'semantic-analyze-fcn)

;;; Code:

;;; Analysis Classes
;;
;; These classes represent what a context is.  Different types
;; of contexts provide differing amounts of information to help
;; provide completions.
;;
(defclass semantic-analyze-context ()
  ((bounds :initarg :bounds
	   :type list
	   :documentation "The bounds of this context.
Usually bound to the dimension of a single symbol or command.")
   (prefix :initarg :prefix
	   :type list
	   :documentation "List of tags defining local text.
This can be nil, or a list where the last element can be a string
representing text that may be incomplete.  Preceeding elements
must be semantic tags representing variables or functions
called in a dereference sequence.")
   (prefixclass :initarg :prefixclass
		:type list
		:documentation "Tag classes expected at this context.
These are clases for tags, such as 'function, or 'variable.")
   (prefixtypes :initarg :prefixtypes
	   :type list
	   :documentation "List of tags defining types for :prefix.
This list is one shorter than :prefix.  Each element is a semantic
tag representing a type matching the semantic tag in the same
position in PREFIX.")
   (scope :initarg :scope
	  :type (or null semantic-scope-cache)
	  :documentation "List of tags available in scopetype.
See `semantic-analyze-scoped-tags' for details.")
   (buffer :initarg :buffer
	   :type buffer
	   :documentation "The buffer this context is derived from.")
   )
  "Base analysis data for a any context.")

(defclass semantic-analyze-context-assignment (semantic-analyze-context)
  ((assignee :initarg :assignee
	     :type list
	     :documentation "A sequence of tags for an assignee.
This is a variable into which some value is being placed.  The last
item in the list is the variable accepting the value.  Earlier
tags represent the variables being derefernece to get to the
assignee."))
  "Analysis class for a value in an assignment.")

(defclass semantic-analyze-context-functionarg (semantic-analyze-context)
  ((function :initarg :function
	     :type list
	     :documentation "A sequence of tags for a function.
This is a function being called.  The cursor will be in the position
of an argument.
The last tag in :function is the function being called.  Earlier
tags represent the variables being dereferenced to get to the
function.")
   (index :initarg :index
	  :type integer
	  :documentation "The index of the argument for this context.
If a function takes 4 arguments, this value should be bound to
the values 1 through 4.")
   (argument :initarg :argument
	     :type list
	     :documentation "A sequence of tags for the :index argument.
The argument can accept a value of some type, and this contains the
tag for that definition.  It should be a tag, but might
be just a string in some circumstances.")
   )
  "Analysis class for a value as a function argument.")

(defclass semantic-analyze-context-return (semantic-analyze-context)
  () ; No extra data.
  "Analysis class for return data.
Return data methods identify the requred type by the return value
of the parent function.")

;;; METHODS
;; 
;; Simple methods against the context classes.
;;
(defmethod semantic-analyze-type-constraint
  ((context semantic-analyze-context) &optional desired-type)
  "Return a type constraint for completing :prefix in CONTEXT.
Optional argument DESIRED-TYPE may be a non-type tag to analyze."
  (when (semantic-tag-p desired-type)
    ;; Convert the desired type if needed.
    (if (not (eq (semantic-tag-class desired-type) 'type))
	(setq desired-type (semantic-tag-type desired-type)))
    ;; Protect against plain strings
    (cond ((stringp desired-type)
	   (setq desired-type (list desired-type 'type)))
	  ((and (stringp (car desired-type))
		(not (semantic-tag-p desired-type)))
	   (setq desired-type (list (car desired-type) 'type)))
	  ((semantic-tag-p desired-type)
	   ;; We have a tag of some sort.  Yay!
	   nil)
	  (t (setq desired-type nil))
	  )
    desired-type))

(defmethod semantic-analyze-type-constraint
  ((context semantic-analyze-context-functionarg))
  "Return a type constraint for completing :prefix in CONTEXT."
  (call-next-method context (car (oref context argument))))

(defmethod semantic-analyze-type-constraint
  ((context semantic-analyze-context-assignment))
  "Return a type constraint for completing :prefix in CONTEXT."
  (call-next-method context (car (reverse (oref context assignee)))))

(defmethod semantic-analyze-interesting-tag
  ((context semantic-analyze-context))
  "Return a tag from CONTEXT that would be most interesting to a user."
  (let ((prefix (reverse (oref context :prefix))))
    ;; Go back through the prefix until we find a tag we can return.
    (while (and prefix (not (semantic-tag-p (car prefix))))
      (setq prefix (cdr prefix)))
    ;; Return the found tag, or nil.
    (car prefix)))

(defmethod semantic-analyze-interesting-tag
  ((context semantic-analyze-context-functionarg))
  "Try the base, and if that fails, return what we are assigning into."
  (or (call-next-method) (car-safe (oref context :function))))

(defmethod semantic-analyze-interesting-tag
  ((context semantic-analyze-context-assignment))
  "Try the base, and if that fails, return what we are assigning into."
  (or (call-next-method) (car-safe (oref context :assignee))))

;;; ANALYSIS
;;
;; Start out with routines that will calculate useful parts of
;; the general analyzer function.  These could be used directly
;; by an application that doesn't need to calculate the full
;; context.

(define-overload semantic-analyze-find-tag-sequence (sequence &optional
							      scope typereturn)
  "Attempt to find all tags in SEQUENCE.
Optional argument LOCALVAR is the list of local variables to use when
finding the details on the first element of SEQUENCE in case
it is not found in the global set of tables.
Optional argument SCOPE are additional terminals to search which are currently
scoped.  These are not local variables, but symbols available in a structure
which doesn't need to be dereferneced.
Optional argument TYPERETURN is a symbol in which the types of all found
will be stored.  If nil, that data is thrown away.")

(defun semantic-analyze-find-tag-sequence-default (sequence &optional
							    scope typereturn)
  "Attempt to find all tags in SEQUENCE.
SCOPE are extra tags which are in scope.
TYPERETURN is a symbol in which to place a list of tag classes that
are found in SEQUENCE."
  (let ((s sequence)			; copy of the sequence
	(tmp nil)			; tmp find variable
	(nexttype nil)			; a tag for the type next in sequence
	(tag nil)			; tag return list
	(tagtype nil)			; tag types return list
	)
    ;; For the first entry, it better be a variable, but it might
    ;; be in the local context too.
    ;; NOTE: Don't forget c++ namespace foo::bar.
    (setq tmp (or
	       ;; Is this tag within our scope.  Scopes can sometimes
	       ;; shadow other things, so it goes first.
	       (and scope (semantic-scope-find (car s) nil scope))
	       ;; Find the tag out there... somewhere, but not in scope
	       (semantic-analyze-find-tag (car s))
	       ))

    (if (and (listp tmp) (semantic-tag-p (car tmp)))
	(setq tmp (semantic-analyze-select-best-tag tmp)))
    (if (not (semantic-tag-p tmp))
	(error "Cannot find definition for \"%s\"" (car s)))
    (setq s (cdr s))
    (setq tag (cons tmp tag))

    ;; For the middle entries
    (while s
      ;; Using the tag found in TMP, lets find the tag
      ;; representing the full typeographic information of its
      ;; type, and use that to determine the search context for
      ;; (car s)
      (let ((tmptype
	     ;; In some cases the found TMP is a type,
	     ;; and we can use it directly.
	     (cond ((eq (semantic-tag-class tmp) 'type)
		    tmp)
		   (t
		    (semantic-analyze-tag-type tmp scope))))
	    (slots nil))
	
	;; Get the children
	(setq slots (semantic-analyze-type-parts tmptype))

	;; find (car s) in the list o slots
	(setq tmp (semantic-find-tags-by-name (car s) slots))

	;; If we have lots
	(if (and (listp tmp) (semantic-tag-p (car tmp)))
	    (setq tmp (semantic-analyze-select-best-tag tmp)))

	;; Make sure we have a tag.
	(if (not (semantic-tag-p tmp))
	    (if (cdr s)
		;; In the middle, we need to keep seeking our types out.
		(error "Cannot find definition for \"%s\"" (car s))
	      ;; Else, it's ok to end with a non-tag
	      (setq tmp (car s))))

	(setq tag (cons tmp tag))
	(setq tagtype (cons tmptype tagtype))
	)
      (setq s (cdr s)))

    (if typereturn (set typereturn (nreverse tagtype)))
    ;; Return the mess
    (nreverse tag)))

 (defun semantic-analyze-find-tag (name &optional tagclass scope)
  "Return the first tag found with NAME or nil if not found.
Optional argument TAGCLASS specifies the class of tag to return, such
as 'function or 'variable.
Optional argument SCOPE specifies a scope object which has
additional tags which are in SCOPE and do not need prefixing to
find.

This is a wrapper on top of semanticdb, semanticdb-typecache,
semantic-scope, and semantic search functions.  Almost all
searches use the same arguments."
  (let ((namelst (semantic-analyze-split-name name)))
    (cond
     ;; If the splitter gives us a list, use the sequence finder
     ;; to get the list.  Since this routine is expected to return
     ;; only one tag, return the LAST tag found from the sequence
     ;; which is supposedly the nexted reference.
     ;;
     ;; Of note, the SEQUENCE function below calls this function
     ;; (recursively now) so the names that we get from the above
     ;; fcn better not, in turn, be splittable.
     ((listp namelst)
      (let ((seq (semantic-analyze-find-tag-sequence
		  namelst nil scope)))
	(car (nreverse seq))))
     ;; If NAME is solo, then do our searches for it here.
     ((stringp namelst)
      (let ((retlist (and scope (semantic-scope-find name tagclass scope))))
	(if retlist
	    retlist
	  (cond
	   ((eq tagclass 'type)
	    (semanticdb-typecache-find name)
	    )
	   (t
	    (semantic-analyze-select-best-tag
	     (semanticdb-strip-find-results
	      (semanticdb-find-tags-by-name name))
	     tagclass)
	    )
	   ))))
     )))

;      (let ((retlist
;	     (or (and scope (semantic-scope-find name nil scope))
;		 (if (and (fboundp 'semanticdb-minor-mode-p)
;			  (semanticdb-minor-mode-p))
;		     ;; Search the database
;		     (semanticdb-strip-find-results
;		      (semanticdb-find-tags-by-name name)
;		      ;; This T means to find files for matching symbols
;		      t)
;		   ;; Search just this file
;		   (semantic-find-tags-by-name
;		    name (current-buffer))))))
;
;	(semantic-analyze-select-best-tag retlist tagclass))))))


;;; MAIN ANALYSIS
;;
;; Create a full-up context analysis.
;;
;;;###autoload
(define-overload semantic-analyze-current-context (&optional position)
  "Analyze the current context at optional POSITION.
If called interactively, display interesting information about POSITION
in a separate buffer.
Returns an object based on symbol `semantic-analyze-context'.

This function can be overriden with the symbol `analyze-context'.
When overriding this function, your override will be called while
cursor is at POSITION.  In addition, your function will not be called
if a cached copy of the return object is found."
  (interactive "d")
  (if (not position) (setq position (point)))
  (save-excursion
    (goto-char position)
    (let* ((answer (semantic-get-cache-data 'current-context)))
      (with-syntax-table semantic-lex-syntax-table
	(when (not answer)
	  (setq answer (:override))
	  (when (and answer (oref answer bounds))
	    (with-slots (bounds) answer
	      (semantic-cache-data-to-buffer (current-buffer)
					     (car bounds)
					     (cdr bounds)
					     answer
					     'current-context
					     'exit-cache-zone))
	    ;; Check for interactivity
	    (if (interactive-p)
		(semantic-analyze-pop-to-context answer))))
      
	answer))))

(defun semantic-analyze-current-context-default (position)
  "Analyze the current context at POSITION.
Returns an object based on symbol `semantic-analyze-context'."
  (let* ((context-return nil)
	 (startpoint (point))
	 (prefixandbounds (semantic-ctxt-current-symbol-and-bounds (or position (point))))
	 (prefix (car prefixandbounds))
	 (endsym (nth 1 prefixandbounds))
	 (bounds (nth 2 prefixandbounds))
	 ;; @todo - vv too early to really know this answer! vv
	 (prefixclass (semantic-ctxt-current-class-list))
	 (prefixtypes nil)
	 (scope (semantic-calculate-scope position))
	 (function nil)
	 (fntag nil)
	 arg fntagend argtag
	 )

    ;; @todo: below check not good for case like this:
    ;;        myfunc(a,-!-
    ;;        where there are no bounds, but we might be able
    ;;        to provide some "context" to the local area.
    (when bounds
      ;; Don't do the work if there are no bounds.


      ;; Pattern for Analysis:
      ;;
      ;; Step 1: Calculate DataTypes in Scope:
      ;;
      ;;  a) Calculate the scope (above)
      ;;
      ;; Step 2: Parse context
      ;;
      ;; a) Identify function being called, or variable assignment,
      ;;    and find source tags for those references
      ;; b) Identify the prefix (text cursor is on) and find the source
      ;;    tags for those references.
      ;;
      ;; Step 3: Assemble an object
      ;;

      ;; Step 2:
      (condition-case nil
	  ;; If we are on lame stuff, it won't be found!
	  (setq prefix (semantic-analyze-find-tag-sequence
			prefix scope 'prefixtypes))
	(error nil))


      (setq function (semantic-ctxt-current-function))
      (when function
	;; If we have a function, then we can get the argument
	(setq arg (semantic-ctxt-current-argument))

	(condition-case nil
	    (setq fntag
		  (semantic-analyze-find-tag-sequence function scope))
	  (error nil))

	;; fntag can have the last entry as just a string, meaning we
	;; could not find the core datatype.  In this case, the searches
	;; below will not work.
	(when (stringp (last (car fntag)))
	    ;; Take a wild guess!
          (setcar (last fntag) (semantic-tag (car (last fntag)) 'function))
	  )

	(when fntag
	  (let ((fcn (semantic-find-tags-by-class 'function fntag)))
	    (when (not fcn)
	      (let ((ty (semantic-find-tags-by-class 'type fntag)))
		(when ty
		  ;; We might have a constructor with the same name as
		  ;; the found datatype.
		  (setq fcn (semantic-find-tags-by-name
			     (semantic-tag-name (car ty))
			     (semantic-tag-type-members (car ty))))
		  (if fcn
		    (let ((con nil)
			  (lp fcn))
		      (while lp
			(when (semantic-tag-get-attribute (car lp)
							  :constructor)
			  (setq fcn (cons (car lp) fcn)))
			(setq lp (cdr lp))))
		    ;; Give up, go old school
		    (setq fcn fntag))
		  )))
	    (setq fntagend (car (reverse fcn))
		  argtag
		  (when (semantic-tag-p fntagend)
		    (nth (1- arg) (semantic-tag-function-arguments fntagend)))
		  fntag fcn))))

      ;; Step 3:

      (if fntag
	  ;; If we found a tag for our function, we can go into
	  ;; functional context analysis mode, meaning we have a type
	  ;; for the argument.
	  (setq context-return
		(semantic-analyze-context-functionarg
		 "functionargument"
		 :buffer (current-buffer)
		 :function fntag
		 :index arg
		 :argument (list argtag)
		 :scope scope
		 :prefix prefix
		 :prefixclass prefixclass
		 :bounds bounds
		 :prefixtypes prefixtypes))

	;; No function, try assignment
	(let ((assign (semantic-ctxt-current-assignment))
	      (asstag nil))
	  (if assign
	      ;; We have an assignment
	      (condition-case nil
		  (setq asstag (semantic-analyze-find-tag-sequence
				assign scope))
		(error nil)))
	  
	  (if asstag
	      (setq context-return
		    (semantic-analyze-context-assignment
		     "assignment"
		     :buffer (current-buffer)
		     :assignee asstag
		     :scope scope
		     :bounds bounds
		     :prefix prefix
		     :prefixclass prefixclass
		     :prefixtypes prefixtypes))
	  
	    ;; TODO: Identify return value condition.

	    ;; Nothing in particular
	    (setq context-return
		  (semantic-analyze-context
		   "context"
		   :buffer (current-buffer)
		   :scope scope
		   :bounds bounds
		   :prefix prefix
		   :prefixclass prefixclass
		   :prefixtypes prefixtypes)))))

      ;; Return our context.
      context-return)))


;;; DEBUG OUTPUT 
;;
;; Friendly output of a context analysis.
;;
(defcustom semantic-analyze-summary-function 'semantic-format-tag-prototype
  "*Function to use when creating items in Imenu.
Some useful functions are found in `semantic-format-tag-functions'."
  :group 'semantic
  :type semantic-format-tag-custom-list)

(defun semantic-analyze-princ-sequence (sequence &optional prefix buff)
  "Send the tag SEQUENCE to standard out.
Use PREFIX as a label.
Use BUFF as a source of override methods."
  (while sequence
      (princ prefix)
      (cond
       ((semantic-tag-p (car sequence))
	(princ (funcall semantic-analyze-summary-function
			(car sequence))))
       ((stringp (car sequence))
	(princ "\"")
	(princ (semantic--format-colorize-text (car sequence) 'variable))
	(princ "\""))
       (t
	(princ (format "'%S" (car sequence)))))
      (princ "\n")
      (setq sequence (cdr sequence))
      (setq prefix (make-string (length prefix) ? ))
      ))

(defmethod semantic-analyze-show ((context semantic-analyze-context))
  "Insert CONTEXT into the current buffer in a nice way."
  (semantic-analyze-princ-sequence (oref context prefix) "Prefix: " )
  (semantic-analyze-princ-sequence (oref context prefixclass) "Prefix Classes: ")
  (semantic-analyze-princ-sequence (oref context prefixtypes) "Prefix Types: ")
  (princ "--------\n")
  ;(semantic-analyze-princ-sequence (oref context scopetypes) "Scope Types: ")
  ;(semantic-analyze-princ-sequence (oref context scope) "Scope: ")
  ;(semantic-analyze-princ-sequence (oref context localvariables) "LocalVars: ")
  (when (oref context scope)
    (semantic-analyze-show (oref context scope)))
  )

(defmethod semantic-analyze-show ((context semantic-analyze-context-assignment))
  "Insert CONTEXT into the current buffer in a nice way."
  (semantic-analyze-princ-sequence (oref context assignee) "Assignee: ")
  (call-next-method))

(defmethod semantic-analyze-show ((context semantic-analyze-context-functionarg))
  "Insert CONTEXT into the current buffer in a nice way."
  (semantic-analyze-princ-sequence (oref context function) "Function: ")
  (princ "Argument Index: ")
  (princ (oref context index))
  (princ "\n")
  (semantic-analyze-princ-sequence (oref context argument) "Argument: ")
  (call-next-method))

(defun semantic-analyze-pop-to-context (context)
  "Display CONTEXT in a temporary buffer.
CONTEXT's content is described in `semantic-analyze-current-context'."
  (with-output-to-temp-buffer "*Semantic Context Analysis*"
    (princ "Context Type: ")
    (princ (object-name context))
    (princ "\n")
    (princ "Bounds: ")
    (princ (oref context bounds))
    (princ "\n")
    (semantic-analyze-show context)
    )
  (shrink-window-if-larger-than-buffer
   (get-buffer-window "*Semantic Context Analysis*"))
  )

(provide 'semantic-analyze)

;;; semantic-analyze.el ends here
