;;; semantic-complete.el --- Routines for performing tag completion

;;; Copyright (C) 2003 Eric M. Ludlam

;; Author: Eric M. Ludlam <zappo@gnu.org>
;; Keywords: syntax
;; X-RCS: $Id: semantic-complete.el,v 1.19 2003/12/13 02:21:25 zappo Exp $

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
;; Free Software Foundation, Inc., 59 Temple Place - Suite 330,
;; Boston, MA 02111-1307, USA.

;;; Commentary:
;;
;; Completion of tags by name using tables of semantic generated tags.
;;
;; While it would be a simple matter of flattening all tag known
;; tables to perform completion across them using `all-completions',
;; or `try-completion', that process would be slow.  In particular,
;; when a system database is included in the mix, the potential for a
;; ludicrous number of options becomes apparent.
;;
;; As such, dynamically searching across tables using a prefix,
;; regular expression, or other feature is needed to help find symbols
;; quickly without resorting to "show me every possible option now".
;;
;; In addition, some symbol names will appear in multiple locations.
;; If it is important to distiguish, then a way to provide a choice
;; over these locations is important as well.
;;
;; Beyond brute force offers for completion of plain strings,
;; using the smarts of semantic-analyze to provide reduced lists of
;; symbols, or fancy tabbing to zoom into files to show multiple hits
;; of the same name can be provided.
;;
;;; How it works:
;;
;; There are several parts of any completion engine.  They are:
;;
;; A.  Collection of possible hits
;; B.  Typing or selecting an option
;; C.  Displaying possible unique completions
;; D.  Using the result
;;
;; Here, we will treat each section separately (excluding D)
;; They can then be strung together in user-visible commands to
;; fullfill specific needs.
;;
;; COLLECTORS:
;;
;; A collector is an object which represents the means by which tokens
;; to complete on are collected.  It's first job is to find all the
;; tokens which are to be completed against.  It can also rename
;; some tokens if needed so long as `semantic-tag-clone' is used.
;;
;; Some collectors will gather all tags to complete against first
;; (for in buffer queries, or other small list situations).  It may
;; choose to do a broad search on each completion request.  Built in
;; functionality automatically focuses the cache in as the user types.
;;
;; A collector choosing to create and rename tags could choose a
;; plain name format, a postfix name such as method:class, or a
;; prefix name such as class.method.
;;
;; DISPLAYORS
;;
;; A displayor is in charge if showing the user interesting things
;; about available completions, and can optionally provide a focus.
;; The simplest display just lists all available names in a separate
;; window.  It may even choose to show short names when there are
;; many to choose from, or long names when there are fewer.
;;
;; A complex displayor could opt to help the user 'foucs' on some
;; range.  For example, if 4 tags all have the same name, subsequent
;; calls to the displayor may opt to show each tag one at a time in
;; the buffer.  When the user likes one, selection would cause the
;; 'focus' item to be selected.
;;
;; CACHE FORMAT
;;
;; The format of the tag lists used to perform the completions are in
;; semanticdb "find" format, like this:
;;
;; ( ( DBTABLE1 TAG1 TAG2 ...)
;;   ( DBTABLE2 TAG1 TAG2 ...)
;;   ... )
;;
;; For buffer local searches, assume that DBTABLE can be nil, and buffer
;; location information is in the TAGs overlay.

(require 'eieio)
(require 'semantic-tag)
(require 'semantic-find)
(require 'semantic-analyze)
(require 'semantic-format)
(require 'semantic-ctxt)
;; Keep semanticdb optional.
(eval-when-compile (require 'semanticdb))

(eval-when-compile
  (require 'avoid)
  (condition-case nil
      ;; Tooltip not available in older emacsen.
      (require 'tooltip)
    (error nil))
  )
  
;;; Code:

;;; Compatibility
;;
(if (fboundp 'minibuffer-contents)
    (defalias 'semantic-minibuffer-contents 'minibuffer-contents)
  (defalias 'semantic-minibuffer-contents 'buffer-string))
(if (fboundp 'delete-minibuffer-contents)
    (defalias 'semantic-delete-minibuffer-contents 'delete-minibuffer-contents)
  (defalias 'semantic-delete-minibuffer-contents 'erase-buffer))

;;; ------------------------------------------------------------
;;; Option Selection harnesses
;;
(defvar semantic-completion-collector-engine nil
  "The tag collector for the current completion operation.
Value should be an object of a subclass of
`semantic-completion-engine-abstract'.")

(defvar semantic-completion-display-engine nil
  "The tag display engine for the current completion operation.
Value should be a ... what?")

(defvar semantic-complete-key-map
  (let ((km (make-sparse-keymap)))
    (define-key km " " 'semantic-complete-complete-space)
    (define-key km "\t" 'semantic-complete-complete-tab)
    (define-key km "\C-m" 'semantic-complete-done)
    (define-key km "\C-g" 'abort-recursive-edit)
    (define-key km "\M-n" 'next-history-element)
    (define-key km "\M-p" 'previous-history-element)
    (define-key km "\C-n" 'next-history-element)
    (define-key km "\C-p" 'previous-history-element)
    ;; Add history navigation
    km)
  "Keymap used while completing across a list of tags.")

(defvar semantic-completion-default-history nil
  "Default history variable for any unhistoried prompt.
Keeps STRINGS only in the history.")


;;;###autoload
(defun semantic-complete-read-tag-engine (collector displayor prompt
						    default-tag initial-input
						    history)
  "Read a semantic tag, and return a tag for the selection.
Argument COLLECTOR is a function which can be used to to return
a list of possible hits.  See `semantic-completion-collector-engine'
for details on COLLECTOR.
Argumeng DISPLAYOR is a function used to display a list of possible
completions for a given prefix.  See`semantic-completion-display-engine'
for details on DISPLAYOR.
PROMPT is a string to prompt with.
DEFAULT-TAG is a semantic tag or string to use as the default value.
If INITIAL-INPUT is non-nil, insert it in the minibuffer initially.
HISTORY is a symbol representing a variable to story the history in."
  (let* ((semantic-completion-collector-engine collector)
	 (semantic-completion-display-engine displayor)
	 (semantic-complete-active-default nil)
	 (semantic-complete-current-matched-tag nil)
	 (ans nil)
	 (tag nil)
	 (default-as-tag (semantic-complete-default-to-tag default-tag))
	 (default-as-string (when (semantic-tag-p default-as-tag)
			      (semantic-tag-name default-as-tag)))
	 )

    (when default-as-string
      ;; Add this to the prompt.
      ;;
      ;; I really want to add a lookup of the symbol in those
      ;; tags available to the collector and only add it if it
      ;; is available as a possibility, but I'm too lazy right
      ;; now.
      ;;
      (if (string-match ":" prompt)
	  (setq prompt (concat
			(substring prompt 0 (match-beginning 0))
			" (" default-as-string ")"
			(substring prompt (match-beginning 0))))
	(setq prompt (concat prompt " (" default-as-string "): "))))
    ;;
    ;; Perform the Completion
    ;;
    (setq ans
	  (read-from-minibuffer prompt
				initial-input
				semantic-complete-key-map
				nil
				(or history
				    'semantic-completion-default-history)
				default-tag))
    ;;
    ;; Extract the tag from the completion machinery.
    ;;
    semantic-complete-current-matched-tag
    ))


;;; Util for basic completion prompts
;;
(defun semantic-completion-message (fmt &rest args)
  "Display the string FMT formatted with ARGS at the end of the minibuffer."
  (message (concat (buffer-string) (apply 'format fmt args))))

(defvar semantic-complete-active-default nil
  "The current default tag calculated for this prompt.")

(defun semantic-complete-default-to-tag (default)
  "Convert a calculated or passed in DEFAULT into a tag."
  (if (semantic-tag-p default)
      ;; Just return what was passed in.
      (setq semantic-complete-active-default default)
    ;; If none was passed in, guess.
    (if (null default)
	(setq default (semantic-ctxt-current-thing)))
    (if (null default)
	;; Do nothing
	nil
      ;; Turn default into something useful.
      (let ((str
	     (cond
	      ;; Semantic-ctxt-current-symbol will return a list of
	      ;; strings.  Technically, we should use the analyzer to
	      ;; fully extract what we need, but for now, just grab the
	      ;; first string
	      ((and (listp default) (stringp (car default)))
	       (car default))
	      ((stringp default)
	       default)
	      ((symbolp default)
	       (symbol-name default))
	      (t
	       (signal 'wrong-type-argument
		       (list default 'semantic-tag-p)))))
	    (tag nil))
	;; Now that we have that symbol string, look it up using the active
	;; collector.  If we get a match, use it.
	(semantic-collector-calculate-completions
	 semantic-completion-collector-engine
	 str nil)
	;; Do we have the perfect match???
	(let ((ml (semantic-collector-current-exact-match
		   semantic-completion-collector-engine)))
	  (when ml
	    ;; We don't care about uniqueness.  Just guess for convenience
	    (setq tag (semanticdb-find-result-nth ml 0))))
	;; save it
	(setq semantic-complete-active-default tag)
	;; Return it.. .whatever it may be
	tag))))


;;; Prompt Return Value
;;
;; Getting a return value out of this completion prompt is a bit
;; challenging.  The read command returns the string typed in.
;; We need to convert this into a valid tag.  We can exit the minibuffer
;; for different reasons.  If we purposely exit, we must make sure
;; the focused tag is calculated... preferably once.
(defvar semantic-complete-current-matched-tag nil
  "Variable used to pass the tags being matched to the prompt.")

(defun semantic-complete-current-match ()
  "Calculate a match from the current completion environment.
Save this in our completion variable.  Make sure that variable
is cleared if any other keypress is made.
Return value can be:
  tag - a single tag that has been matched.
  string - a message to show in the minibuffer."
  ;; Query the environment for an active completion.
  (let ((collector semantic-completion-collector-engine)
	(displayor semantic-completion-display-engine)
	(contents (semantic-minibuffer-contents))
	match
	matchlist
	answer)
    (if (string= contents "")
	;; The user wants the defaults!
	(setq answer semantic-complete-active-default)
      ;; This forces a full calculation of completion on CR.
      (semantic-collector-calculate-completions collector contents nil)
      (semantic-complete-try-completion)
      (cond
       ;; Input match displayor focus entry
       ((setq answer (semantic-displayor-current-focus displayor))
	;; We have answer, continue
	)
       ;; One match from the collector
       ((setq matchlist (semantic-collector-current-exact-match collector))
	(if (= (semanticdb-find-result-length matchlist) 1)
	    (setq answer (semanticdb-find-result-nth-in-buffer matchlist 0))
	  (if (semantic-displayor-focus-abstract-child-p displayor)
	      ;; For focusing displayors, we can claim this is
	      ;; not unique.  Multiple focuses can choose the correct
	      ;; one.
	      (setq answer "Not Unique")
	    ;; If we don't have a focusing displayor, we need to do something
	    ;; graceful.  First, see if all the matches have the same name.
	    (let ((allsame t)
		  (firstname (semantic-tag-name
			      (car
			       (semanticdb-find-result-nth matchlist 0)))
			     )
		  (cnt 1)
		  (max (semanticdb-find-result-length matchlist)))
	      (while (and allsame (< cnt max))
		(if (not (string=
			  firstname
			  (semantic-tag-name
			   (car
			    (semanticdb-find-result-nth matchlist cnt)))))
		    (setq allsame nil))
		(setq cnt (1+ cnt))
		)
	      ;; Now we know if they are all the same.  If they are, just
	      ;; accept the first, otherwise complain.
	      (if allsame
		  (setq answer (semanticdb-find-result-nth-in-buffer
				matchlist 0))
		(setq answer "Not Unique"))
	      ))))
       ;; No match
       (t
	(setq answer "No Match")))
      )
    ;; Set it into our completion target.
    (when (semantic-tag-p answer)
      (setq semantic-complete-current-matched-tag answer)
      ;; Make sure it is up to date by clearing it if the user dares
      ;; to touch the keyboard.
      (add-hook 'pre-command-hook
		(lambda () (setq semantic-complete-current-matched-tag nil)))
      )
    ;; Return it
    answer
    ))


;;; Keybindings
;;
;; Keys are bound to to perform completion using our mechanisms.
;; Do that work here.
(defun semantic-complete-done ()
  "Accept the current input."
  (interactive)
  (let ((ans (semantic-complete-current-match)))
    (if (stringp ans)
	(semantic-completion-message (concat " [" ans "]"))
      (exit-minibuffer)))
  )

(defun semantic-complete-complete-space ()
  "Complete the partial input in the minibuffer."
  (interactive)
  (semantic-complete-do-completion t))

(defun semantic-complete-complete-tab ()
  "Complete the partial input in the minibuffer as far as possible."
  (interactive)
  (semantic-complete-do-completion))

;;; Completion Functions
;;
;; Thees routines are functional entry points to performing completion.
;;
(defun semantic-complete-hack-word-boundaries (original new)
  "Return a string to use for completion.
ORIGINAL is the text in the minibuffer.
NEW is the new text to insert into the minibuffer.
Within the difference bounds of ORIGINAL and NEW, shorten NEW
to the nearest word boundary, and return that."
  (save-match-data
    (let* ((diff (substring new (length original)))
	   (end (string-match "\\>" diff))
	   (start (string-match "\\<" diff)))
      (cond
       ((and start (> start 0))
	;; If start is greater than 0, include only the new
	;; white-space stuff
	(concat original (substring diff 0 start)))
       (end
	(concat original (substring diff 0 end)))
       (t new)))))

(defun semantic-complete-try-completion (&optional partial)
  "Try a completion for the current minibuffer.
If PARTIAL, do partial completion stopping at spaces."
  (let ((comp (semantic-collector-try-completion
               semantic-completion-collector-engine
	       (semantic-minibuffer-contents))))
    (cond
     ((null comp)
      (semantic-completion-message " [No Match]")
      (ding)
      )
     ((stringp comp)
      (if (string= (semantic-minibuffer-contents) comp)
	  (when partial
	    ;; Minibuffer isn't changing AND the text is not unique.
	    ;; Test for partial completion over a word separator character.
	    ;; If there is one available, use that so that SPC can
	    ;; act like a SPC insert key.
	    (let ((newcomp (semantic-collector-current-whitespace-completion
			    semantic-completion-collector-engine)))
	      (when newcomp
		(semantic-delete-minibuffer-contents)
		(insert newcomp))
	      ))
	(when partial
	  (let ((orig (semantic-minibuffer-contents)))
	    ;; For partial completion, we stop and step over
	    ;; word boundaries.  Use this nifty function to do
	    ;; that calculation for us.
	    (setq comp
		  (semantic-complete-hack-word-boundaries orig comp))))
	;; Do the replacement.
	(semantic-delete-minibuffer-contents)
        (insert comp))
      )
     ((and (listp comp) (semantic-tag-p (car comp)))
      (unless (string= (buffer-string) (semantic-tag-name (car comp)))
        ;; A fully unique completion was available.
        (semantic-delete-minibuffer-contents)
        (insert (semantic-tag-name (car comp))))
      ;; The match is complete
      (if (= (length comp) 1)
          (semantic-completion-message " [Complete]")
        (semantic-completion-message " [Complete, but not unique]"))
      )
     (t nil))))

(defun semantic-complete-do-completion (&optional partial)
  "Do a completion for the current minibuffer.
If PARTIAL, do partial completion stopping at spaces."
  (let ((contents (semantic-minibuffer-contents))
	(collector semantic-completion-collector-engine)
	(displayor semantic-completion-display-engine))

    (semantic-collector-calculate-completions collector contents partial)
    (let* ((na (semantic-complete-next-action partial)))
      (cond
       ;; We're all done, but only from a very specific
       ;; area of completion.
       ((eq na 'done)
	(semantic-completion-message " [Complete]"))
       ;; Perform completion
       ((or (eq na 'complete)
	    (eq na 'complete-whitespace))
	(semantic-complete-try-completion partial)
	)
       ;; We need to display the completions.
       ;; Set the completions into the display engine
       ((eq na 'display)
	(semantic-displayor-set-completions
	 displayor
	 (semantic-collector-all-completions collector contents)
	 contents)
	;; Ask the displayor to display them.
	(semantic-displayor-show-request displayor)
	)
       ((eq na 'scroll)
	(semantic-displayor-scroll-request displayor)
	)
       ((eq na 'focus)
	(semantic-displayor-focus-request displayor)
	)
       ((eq na 'empty)
	(semantic-completion-message " [No Match]"))
       (t nil)))))

;;; ------------------------------------------------------------
;;; Interactions between collection and displaying
;;
;; Functional routines used to help collectors communicate with
;; the current displayor, or for the previous section.

(defun semantic-complete-next-action (partial)
  "Determine what the next completion action should be.
PARTIAL is non-nil if we are doing partial completion.
First, the collector can determine if we should perform a completion or not.
If there is nothing to complete, then the displayor determines if we are
to show a completion list, scroll, or perhaps do a focus (if it is capable.)
Expected return values are:
  done -> We have a singular match
  empty -> There are no matches to the current text
  complete -> Perform a completion action
  complete-whitespace -> Complete next whitespace type character.
  display -> Show the list of completions
  scroll -> The completions have been shown, and the user keeps hitting
            the complete button.  If possible, scroll the completions
  focus -> The displayor knows how to shift focus among possible completions.
           Let it do that."
  (let ((ans nil))
    (setq ans (semantic-collector-next-action
	       semantic-completion-collector-engine
	       partial))
    (unless ans
      (setq ans (semantic-displayor-next-action
		 semantic-completion-display-engine)))
    ans))


;;; ------------------------------------------------------------
;;; Collection Engines
;;
;; Collection engines can scan tags from the current environment and
;; provide lists of possible completions.
;;
;; General features of the abstract collector:
;; * Cache completion lists between uses
;; * Cache itself per buffer.  Handle reparse hooks
;;
;; Key Interface Functions to implement:
;; * semantic-collector-next-action
;; * semantic-collector-calculate-completions
;; * semantic-collector-try-completion
;; * semantic-collector-all-completions

(defvar semantic-collector-per-buffer-list nil
  "List of collectors active in this buffer.")
(make-variable-buffer-local 'semantic-collector-per-buffer-list)

(defvar semantic-collector-list nil
  "List of global collectors active this session.")

(defclass semantic-collector-abstract ()
  ((buffer :initarg :buffer
	   :type buffer
	   :documentation "Originating buffer for this collector.
Some collectors use a given buffer as a starting place while looking up
tags.")
   (cache :initform nil
	  :type (or null semanticdb-find-result-with-nil)
	  :documentation "Cache of tags.
These tags are re-used during a completion session.
Sometimes these tags are cached between completion sessions.")
   (last-all-completions :initarg nil
			 :type semanticdb-find-results
			 :documentation "Last result of `all-completions'.
This result can be used for refined completions as `last-prefix' gets
closer to a specific result.")
   (last-prefix :type string
		:protection :protected
		:documentation "The last queried prefix.
This prefix can be used to cache intermediate completion offers.
making the action of homing in on a token faster.")
   (last-completion :type (or null string)
		    :documentation "The last calculated completion.
This completion is calculated and saved for future use.")
   (last-whitespace-completion :type (or null string)
			       :documentation "The last whitespace completion.
For partial completion, SPC will disabiguate over whitespace type
characters.  This is the last calculated version.")
   (current-exact-match :type list
			:protection :protected
			:documentation "The list of matched tags.
When tokens are matched, they are added to this list.")
   )
  "Root class for completion engines."
  :abstract t)

(defmethod semantic-collector-next-action
  ((obj semantic-collector-abstract) partial)
  "What should we do next?  OBJ can predict a next good action.
PARTIAL indicates if we are doing a partial completion."
  (if (and (slot-boundp obj 'last-completion)
	   (string= (semantic-minibuffer-contents) (oref obj last-completion)))
      (let* ((cem (semantic-collector-current-exact-match obj))
	     (cemlen (semanticdb-find-result-length cem)))
	(cond ((and cem (= cemlen 1))
	       'done)
	      ((and (not cem) 
		    (not (semantic-collector-all-completions 
			  obj (semantic-minibuffer-contents))))
	       'empty)
	      ((and partial (semantic-collector-try-completion-whitespace 
			     obj (semantic-minibuffer-contents)))
	       'complete-whitespace)))
    'complete))

(defmethod semantic-collector-last-prefix= ((obj semantic-collector-abstract)
					    last-prefix)
  "Return non-nil if OBJ's prefix matches PREFIX."
  (and (slot-boundp obj 'last-prefix)
       (string= (oref obj last-prefix) last-prefix)))

(defmethod semantic-collector-get-cache ((obj semantic-collector-abstract))
  "Get the raw cache of tags for completion.
Calculate the cache if there isn't one."
  (or (oref obj cache)
      (semantic-collector-calculate-cache obj)))

(defmethod semantic-collector-calculate-completions-raw
  ((obj semantic-collector-abstract) prefix completionlist)
  "Calculate the completions for prefix from completionlist.
Output must be in semanticdb Find result format."
  ;; Must output in semanticdb format
  (list
   (cons (save-excursion
	   (set-buffer (oref obj buffer))
	   semanticdb-current-table)
	 (semantic-find-tags-for-completion
	  prefix
	  ;; To do this kind of search with a pre-built completion
	  ;; list, we need to strip it first.
	  (semanticdb-strip-find-results completionlist)))))

(defmethod semantic-collector-calculate-completions
  ((obj semantic-collector-abstract) prefix partial)
  "Calculate completions for prefix as setup for other queries."
  (let* ((case-fold-search semantic-case-fold)
	 (same-prefix-p (semantic-collector-last-prefix= obj prefix))
	 (completionlist
	  (if (or same-prefix-p
		  (and (slot-boundp obj 'last-prefix)
		       (eq (compare-strings (oref obj last-prefix) 0 nil
					    prefix 0 (length prefix))
			   t)))
	      ;; New prefix is subset of old prefix
	      (oref obj last-all-completions)
	    (semantic-collector-get-cache obj)))
	 ;; Get the result
	 (answer (if same-prefix-p
		     completionlist
		   (semantic-collector-calculate-completions-raw
		    obj prefix completionlist))
		 )
	 (completion nil)
	 (complete-not-uniq nil)
	 )
    (when (not same-prefix-p)
      ;; Save results if it is interesting and beneficial
      (oset obj last-prefix prefix)
      (oset obj last-all-completions answer))
    ;; Now calculate the completion.
    (setq completion (try-completion
		      prefix
		      (semanticdb-strip-find-results answer)))
    (oset obj last-whitespace-completion nil)
    (oset obj current-exact-match nil)
    (oset obj last-completion
	  (cond
	   ;; Unique match in AC.  Last completion is a match.
	   ;; Also set the current-exact-match.
	   ((eq completion t)
	    (oset obj current-exact-match answer)
	    prefix)
	   ;; It may be complete (a symbol) but still not unique.
	   ;; We can capture a match
	   ((setq complete-not-uniq
		  (semanticdb-find-tags-by-name
		   prefix
		   (semanticdb-strip-find-results answer)))
	    (oset obj current-exact-match 
		  complete-not-uniq)
	    prefix
	    )
	   ;; Non unique match, return the string that handles
	   ;; completion
	   (t (or completion prefix))
	   ))
    ))

(defmethod semantic-collector-try-completion-whitespace
  ((obj semantic-collector-abstract) prefix)
  "For OBJ, do whatepsace completion based on PREFIX.
This implies that if there are two completions, one matching
the test \"preifx\\>\", and one not, the one matching the full
word version of PREFIX will be chosen, and that text returned.
This function requires that `semantic-collector-calculate-completions'
has been run first."
  (let* ((ac (semantic-collector-all-completions obj prefix))
	 (matchme (concat "^" prefix "\\>"))
	 (compare (semanticdb-find-tags-by-name-regexp matchme ac))
	 (numtag (semanticdb-find-result-length compare))
	 )
    (if compare
	(let* ((idx 0)
	       (cutlen (1+ (length prefix)))
	       (twws (semanticdb-find-result-nth compare idx)))
	  ;; Is our tag with whitespace a match that has whitespace
	  ;; after it, or just an already complete symbol?
	  (while (and (< idx numtag)
		      (< (length (semantic-tag-name (car twws))) cutlen))
	    (setq idx (1+ idx)
		  twws (semanticdb-find-result-nth compare idx)))
	  ;; If COMPARE has succeeded, then we should take the very
	  ;; first match, and extend prefix by one character.
	  (oset obj last-whitespace-completion
		(substring (semantic-tag-name (car twws))
			   0 cutlen)))
      )))


(defmethod semantic-collector-current-exact-match ((obj semantic-collector-abstract))
  "Return the active valid MATCH from the semantic collector.
For now, just return the first element from our list of available
matches.  For semanticdb based results, make sure the file is loaded
into a buffer."
  (when (slot-boundp obj 'current-exact-match)
    (oref obj current-exact-match)))

(defmethod semantic-collector-current-whitespace-completion ((obj semantic-collector-abstract))
  "Return the active whitespace completion value."
  (when (slot-boundp obj 'last-whitespace-completion)
    (oref obj last-whitespace-completion)))

(defmethod semantic-collector-get-match ((obj semantic-collector-abstract))
  "Return the active valid MATCH from the semantic collector.
For now, just return the first element from our list of available
matches.  For semanticdb based results, make sure the file is loaded
into a buffer."
  (when (slot-boundp obj 'current-exact-match)
    (semanticdb-find-result-nth-in-buffer (oref obj current-exact-match) 0)))

(defmethod semantic-collector-all-completions
  ((obj semantic-collector-abstract) prefix)
  "For OBJ, retrieve all completions matching PREFIX.
The returned list consists of all the tags currently
matching PREFIX."
  (when (slot-boundp obj 'last-all-completions)
    (oref obj last-all-completions)))

(defmethod semantic-collector-try-completion
  ((obj semantic-collector-abstract) prefix)
  "For OBJ, attempt to match PREFIX.
See `try-completion' for details on how this works.
Return nil for no match.
Return a string for a partial match.
For a unique match of PREFIX, return the list of all tags
with that name."
  (if (slot-boundp obj 'last-completion)
      (oref obj last-completion)))

(defmethod semantic-collector-calculate-cache
  ((obj semantic-collector-abstract))
  "Calculate the completion cache for OBJ."
  nil
  )

(defmethod semantic-collector-flush ((this semantic-collector-abstract))
  "Flush THIS collector object, clearing any caches and prefix."
  (oset this cache nil)
  (slot-makeunbound this 'last-prefix)
  (slot-makeunbound this 'last-completion)
  (slot-makeunbound this 'last-all-completions)
  (slot-makeunbound this 'current-exact-match)
  )

;;; PER BUFFER
;;
(defclass semantic-collector-buffer-abstract (semantic-collector-abstract)
  ()
  "Root class for per-buffer completion engines.
These collectors track themselves on a per-buffer basis "
  :abstract t)

(defmethod constructor :STATIC ((this semantic-collector-buffer-abstract)
				newname &rest fields)
  "Reuse previously created objects of this type in buffer."
  (let ((old nil)
	(bl semantic-collector-per-buffer-list))
    (while (and bl (null old))
      (if (eq (object-class (car bl)) this)
	  (setq old (car bl))))
    (unless old
      (let ((new (call-next-method)))
	(add-to-list 'semantic-collector-per-buffer-list new)
	(setq old new)))
    (slot-makeunbound old 'last-completion)
    (slot-makeunbound old 'last-prefix)
    (slot-makeunbound old 'current-exact-match)
    old))

;; Buffer specific collectors should flush themselves
(defun semantic-collector-buffer-flush (newcache)
  "Flush all buffer collector objects.
NEWCACHE is the new tag table, but we ignore it."
  (condition-case nil
      (let ((l semantic-collector-per-buffer-list))
	(while l
	  (if (car l) (semantic-collector-flush (car l)))
	  (setq l (cdr l))))
    (error nil)))

(add-hook 'semantic-after-toplevel-cache-change-hook
	  'semantic-collector-buffer-flush)

;;; DEEP BUFFER SPECIFIC COMPLETION
;;
(defclass semantic-collector-buffer-deep
  (semantic-collector-buffer-abstract)
  ()
  "Completion engine for tags in the current buffer.
Provides deep searches through types.")

(defmethod semantic-collector-calculate-cache
  ((obj semantic-collector-buffer-deep))
  "Calculate the completion cache for OBJ.
Uses `semantic-flatten-tags-table'"
  (oset obj cache
	;; Must create it in SEMANTICDB find format.
	;; ( ( DBTABLE TAG TAG ... ) ... )
	(list
	 (cons semanticdb-current-table
	       (semantic-flatten-tags-table (oref obj buffer))))))

;;; PROJECT SPECIFIC COMPLETION
;;
(defclass semantic-collector-project-abstract (semantic-collector-abstract)
  ((path :initarg :path
	 :initform nil
	 :documentation "List of database tables to search.
At creation time, it can be anything accepted by
`semanticdb-find-translate-path' as a PATH argument.")
   )
  "Root class for project wide completion engines."
  :abstract t)

;;; Project Search
(defclass semantic-collector-project (semantic-collector-project-abstract)
  ()
  "Completion engine for tags in a project.")


(defmethod semantic-collector-calculate-completions-raw
  ((obj semantic-collector-project) prefix completionlist)
  "Calculate the completions for prefix from completionlist."
  (semanticdb-find-tags-for-completion prefix (oref obj path)))

;;; Brutish Project search
(defclass semantic-collector-project-brutish (semantic-collector-project-abstract)
  ()
  "Completion engine for tags in a project.")

(defmethod semantic-collector-calculate-completions-raw
  ((obj semantic-collector-project-brutish) prefix completionlist)
  "Calculate the completions for prefix from completionlist."
  (semanticdb-brute-deep-find-tags-for-completion prefix (oref obj path)))


;;; ------------------------------------------------------------
;;; Tag List Display Engines
;;
;; A typical displayor accepts a pre-determined list of completions
;; generated by a collector.  This format is in semanticdb search
;; form.  This vaguely standard form is a bit challenging to navigate
;; because the tags do not contain buffer info, but the file assocated
;; with the tags preceed the tag in the list.
;;
;; Basic displayors don't care, and can strip the results.
;; Advanced highlighting displayors need to know when they need
;; to load a file so that the tag in question can be highlighted.
;;
;; Key interface methods to a displayor are:
;; * semantic-displayor-next-action
;; * semantic-displayor-set-completions
;; * semantic-displayor-current-focus
;; * semantic-displayor-show-request
;; * semantic-displayor-scroll-request
;; * semantic-displayor-focus-request

(defclass semantic-displayor-abstract ()
  ((table :type (or null semanticdb-find-result-with-nil)
	  :initform nil
	  :protection :protected
	  :documentation "List of tags this displayor is showing.")
   (last-prefix :type string
		:protection :protected
		:documentation "Prefix associated with slot `table'")
   )
  "Manages the display of some number of tags."
  :abstract t)

(defmethod semantic-displayor-next-action ((obj semantic-displayor-abstract))
  "The next action to take on the minibuffer related to display."
  (if (and (slot-boundp obj 'last-prefix)
	   (string= (oref obj last-prefix) (semantic-minibuffer-contents))
	   (eq last-command this-command))
      'scroll
    'display))

(defmethod semantic-displayor-set-completions ((obj semantic-displayor-abstract)
					       table prefix)
  "Set the list of tags to be completed over to TABLE."
  (oset obj table table)
  (oset obj last-prefix prefix))

(defmethod semantic-displayor-show-request ((obj semantic-displayor-abstract))
  "A request to show the current tags table."
  (ding))

(defmethod semantic-displayor-focus-request ((obj semantic-displayor-abstract))
  "A request to for the displayor to focus on some tag option."
  (ding))

(defmethod semantic-displayor-scroll-request ((obj semantic-displayor-abstract))
  "A request to for the displayor to scroll the completion list (if needed)."
  (scroll-other-window))

(defmethod semantic-displayor-current-focus ((obj semantic-displayor-abstract))
  "Return a single tag currently in focus.
This object type doesn't do focus, so will never have a focus object."
  nil)

;; Traditional displayor
(defcustom semantic-completion-displayor-format-tag-function
  #'semantic-format-tag-name
  "*A Tag format function to use when showing completions."
  :group 'semantic
  :type semantic-format-tag-custom-list)

(defclass semantic-displayor-traditional (semantic-displayor-abstract)
  ()
  "Traditional display mechanism for a list of possible completions.")

(defmethod semantic-displayor-show-request ((obj semantic-displayor-abstract))
  "A request to show the current tags table."
  (with-output-to-temp-buffer "*Completions*"
    (display-completion-list
     (mapcar semantic-completion-displayor-format-tag-function
	     (semanticdb-strip-find-results (oref obj table))))
    )
  )

;;; Abstract baseclass for any displayor which supports focus
(defclass semantic-displayor-focus-abstract (semantic-displayor-abstract)
  ((focus :type number
	  :protection :protected
	  :documentation "A tag index from `table' which has focus.
Multiple calls to the display function can choose to focus on a
given tag, by highlighting its location.")
   (find-file-focus
    :allocation :class
    :initform nil
    :documentation
    "Non-nil if focusing requires a tag's buffer be in memory.")
   )
  "A displayor which has the ability to focus in on one tag.
Focusing is a way of differentiationg between multiple tags
which have the same name."
  :abstract t)

(defmethod semantic-displayor-next-action ((obj semantic-displayor-focus-abstract))
  "The next action to take on the minibuffer related to display."
  (if (and (slot-boundp obj 'last-prefix)
	   (string= (oref obj last-prefix) (semantic-minibuffer-contents))
	   (eq last-command this-command))
      'focus
    'display))

(defmethod semantic-displayor-set-completions ((obj semantic-displayor-focus-abstract)
					       table prefix)
  "Set the list of tags to be completed over to TABLE."
  (call-next-method)
  (slot-makeunbound obj 'focus))

(defmethod semantic-displayor-focus-next-tag ((obj semantic-displayor-focus-abstract))
  "Return the next tag OBJ should focus on."
  (when (and (slot-boundp obj 'table) (oref obj table))
    (with-slots (table) obj
      (if (not (slot-boundp obj 'focus))
	  (oset obj focus 0)
	(oset obj focus (1+ (oref obj focus)))
	)
      (if (<= (semanticdb-find-result-length table) (oref obj focus))
	  (oset obj focus 0))
      (semanticdb-find-result-nth table (oref obj focus)))))

(defmethod semantic-displayor-current-focus ((obj semantic-displayor-focus-abstract))
  "Return the tag currently in focus, or call parent method."
  (if (and (slot-boundp obj 'focus)
	   (slot-boundp obj 'table)
	   ;; Only return the current focus IFF the minibuffer reflects
	   ;; the list this focus was derived from.
	   (slot-boundp obj 'last-prefix)
	   (string= (semantic-minibuffer-contents) (oref obj last-prefix))
	   )
      ;; We need to focus
      (if (oref obj find-file-focus)
	  (semanticdb-find-result-nth-in-buffer (oref obj table) (oref obj focus))
	(semanticdb-find-result-nth (oref obj table) (oref obj focus)))
    ;; Do whatever
    (call-next-method)))

;;; Simple displayor which performs traditional display completion,
;; and also focuses with highlighting.
(defclass semantic-displayor-traditional-with-focus-highlight
  (semantic-displayor-traditional semantic-displayor-focus-abstract)
  ((find-file-focus :initform t))
  "A traditional displayor which can focus on a tag by showing it.")

(defmethod semantic-displayor-focus-request
  ((obj semantic-displayor-traditional-with-focus-highlight))
  "Focus in on possible tag completions.
Focus is performed by cycling through the tags and highlighting
one in the source buffer."
  (let* ((tablelength (semanticdb-find-result-length (oref obj table)))
	 (focus (semantic-displayor-focus-next-tag obj))
	 (tag (car focus))
	 (table (cdr focus))
	)
    (let ((buf (or (semantic-tag-buffer tag)
		   (and table (semanticdb-get-buffer table)))))
      ;; If no buffer is provided, then we can make up a summary buffer.
      (when (not buf)
	(save-excursion
	  (set-buffer (get-buffer-create "*Completion Focus*"))
	  (erase-buffer)
	  (insert "Focus on tag: \n")
	  (insert (semantic-format-tag-summarize tag nil t) "\n\n")
	  (when table
	    (insert "From table: \n")
	    (insert (object-name table) "\n\n"))
	  (when buf
	    (insert "In buffer: \n\n")
	    (insert (format "%S" buf)))
	  (setq buf (current-buffer))))
      ;; Show the tag in the buffer.
      (if (get-buffer-window buf)
	  (select-window (get-buffer-window buf))
	(switch-to-buffer-other-window buf t)
	(select-window (get-buffer-window buf)))
      ;; Now do some positioning
      (unwind-protect
	  (if (semantic-tag-with-position-p tag)
	      ;; Full tag positional information available
	      (progn
		(goto-char (semantic-tag-start tag))
		;; This avoids a dangerous problem if we just loaded a tag
		;; from a file, but the original position was not updated
		;; in the TAG variable we are currently using.
		(semantic-momentary-highlight-tag (semantic-current-tag))
		))
	(select-window (minibuffer-window)))
      ;; Calculate text difference between contents and the focus item.
      (let* ((mbc (semantic-minibuffer-contents))
	     (ftn (semantic-tag-name tag))
	     (diff (substring ftn (length mbc))))
	(semantic-completion-message 
	 (format "%s [%d of %d matches]" diff (oref obj focus) tablelength)))
      )))

;;; Tooltip completion lister
;; 
;; Written and contributed by Masatake YAMATO <jet@gyve.org>
;;
(defclass semantic-displayor-tooltip (semantic-displayor-abstract)
  ((max-tags     :type integer
		 :initarg :max-tags
		 :initform 10
		 :custom integer
		 :documentation
		 "Max number of tags displayed on tooltip at once.
If `force-show' is 1,  this value is ignored with typing tab or space twice continuously.
if `force-show' is 0, this value is always ignored.")
   (force-show   :type integer
		 :initarg :force-show
	         :initform 1
		 :custom (choice (const
				  :tag "Show when double typing"
				  1)
				 (const
				  :tag "Show always"
				  0)
				 (const
				  :tag "Show if the number of tags is less than `max-tags'."
				  -1))
	         :documentation
		 "Control the behavior of the number of tags is greater than `max-tags'.
-1 means tags are never shown.
0 means the tags are always shown.
1 means tags are shown if space or tab is typed twice continuously.")
   (typing-count :type integer
		 :initform 0
		 :documentation
		 "Counter holding how many times the user types space or tab continuously before showing tags.")
   (shown        :type boolean
		 :initform nil
		 :documentation
		 "Flag representing whether tags is shown once or not.")
   )
  "Display mechanism using tooltip for a list of possible completions.")

(defmethod semantic-displayor-show-request ((obj semantic-displayor-tooltip))
  "A request to show the current tags table."
  (let* ((l (mapcar semantic-completion-displayor-format-tag-function
		    (oref obj table)))
	 (ll (length l))
	 (typing-count (oref obj typing-count))
	 (force-show (oref obj force-show))
	 msg)
    (if (or (oref obj shown)
	    (< ll (oref obj max-tags))
	    (and (<= 0 force-show)
		 (< (1- force-show) typing-count)))
	(progn
	  (oset obj typing-count 0)
	  (oset obj shown t)
	  (if (eq 1 ll)
	      (setq msg "SOLE COMPLETION")
	    (setq msg (mapconcat 'identity l "\n"))
	    (if (eq 0 (length msg))
		(setq msg "NO MORE COMPLETIONS")))
	  (semantic-displayor-tooltip-show msg))
      (oset obj typing-count (1+ typing-count))
      (cond
       ((= force-show -1)
	(semantic-displayor-tooltip-show "TOO MANY"))
       ((= force-show 1)
	(semantic-displayor-tooltip-show
	 "TOO MANY (Type TAB or SPACE again to show force)"))))))

(defun semantic-displayor-tooltip-show (text)
  "Display a tooltip with TEXT near cursor."
  (require 'tooltip)
  (require 'avoid)
  (let* ((P (mouse-avoidance-point-position))
	 (frame (car P))
	 (x (cadr P))
	 (y (cddr P))
	 (oP (mouse-position))
	 (oframe (car oP))
	 (ox     (cadr oP))
	 (oy     (cddr oP)))
    (set-mouse-position frame x y)
    (tooltip-show text)
    (set-mouse-position frame (1+ x) y)))

;; End code contributed by Masatake YAMATO <jet@gyve.org>


;;; ------------------------------------------------------------
;;; Specific queries
;;
(defun semantic-complete-read-tag-buffer-deep (prompt &optional
						      default-tag
						      initial-input
						      history)
  "Ask for a tag by name from the current buffer.
Available tags are from the current buffer, at any level.
Completion options are presented in a traditional way, with highlighting
to resolve same-name collisions.
PROMPT is a string to prompt with.
DEFAULT-TAG is a semantic tag or string to use as the default value.
If INITIAL-INPUT is non-nil, insert it in the minibuffer initially.
HISTORY is a symbol representing a variable to story the history in."
  (semantic-complete-read-tag-engine
   (semantic-collector-buffer-deep prompt :buffer (current-buffer))
   (semantic-displayor-traditional-with-focus-highlight "simple")
   ;;(semantic-displayor-tooltip "simple")
   prompt
   default-tag
   initial-input
   history)
  )

(defun semantic-complete-read-tag-project (prompt &optional
						  default-tag
						  initial-input
						  history)
  "Ask for a tag by name from the current project.
Available tags are from the current project, at the top level.
Completion options are presented in a traditional way, with highlighting
to resolve same-name collisions.
PROMPT is a string to prompt with.
DEFAULT-TAG is a semantic tag or string to use as the default value.
If INITIAL-INPUT is non-nil, insert it in the minibuffer initially.
HISTORY is a symbol representing a variable to story the history in."
  (semantic-complete-read-tag-engine
   (semantic-collector-project-brutish prompt
				       :buffer (current-buffer)
				       :path (current-buffer)
				       )
   (semantic-displayor-traditional-with-focus-highlight "simple")
   prompt
   default-tag
   initial-input
   history)
  )


;;; ------------------------------------------------------------
;;; Testing
;;
(defun semantic-complete-test ()
  "Test completion mechanisms."
  (interactive)
  (message "%S"
   (semantic-format-tag-prototype
    (semantic-complete-read-tag-project "Symbol: ")
    )))

;;;###autoload
(defun semantic-complete-jump-local ()
  "Jump to a semantic symbol."
  (interactive)
  (let ((tag (semantic-complete-read-tag-buffer-deep "Symbol: ")))
    (when (semantic-tag-p tag)
      (push-mark)
      (goto-char (semantic-tag-start tag))
      (semantic-momentary-highlight-tag tag)
      (working-message "%S: %s "
                       (semantic-tag-class tag)
                       (semantic-tag-name  tag)))))

;;;###autoload
(defun semantic-complete-jump ()
  "Jump to a semantic symbol."
  (interactive)
  (let* ((semanticdb-search-system-databases nil)
	 (tag (semantic-complete-read-tag-project "Symbol: ")))
    (when (semantic-tag-p tag)
      (push-mark)
      (semantic-go-to-tag tag)
      (switch-to-buffer (current-buffer))
      (semantic-momentary-highlight-tag tag)
      (working-message "%S: %s "
                       (semantic-tag-class tag)
                       (semantic-tag-name  tag)))))


;; End
(provide 'semantic-complete)

;;; semantic-complete.el ends here
