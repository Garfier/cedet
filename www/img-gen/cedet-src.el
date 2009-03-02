;;; cedet-src.el --- Create HTML sources from data structures.
;;
;; Copyright (C) 2009 Eric M. Ludlam
;;
;; Author: Eric M. Ludlam <eric@siege-engine.com>
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
;; Generate some HTML for some of the more complex parts of the web site.
;;

;;; Code:
(defvar csrc-web (let* ((cdir (file-name-directory (locate-library "cedet.el")))
			(rdir (file-name-directory (directory-file-name cdir)))
			(web (expand-file-name "www" rdir))
			)
		   web)
  "The path the to web space.")


(defun csrc-build-sb ()
  "Build the Speedbar lookalike nav bar."
  (interactive)
  (find-file-other-window (expand-file-name "rightcol.php" csrc-web))
  (erase-buffer)
  (insert "<!-- -*- html -*- -->
<tt>
<table align=right cellspacing=0 cellpadding=0 class=SPEEDBAR><tr><td>
<table bgcolor=white cellspacing=0 cellpadding=1 width=210>

<tr><td align=center>&nbsp<a href=\"/\"><b><font size=+1>CEDET</font></b></a>&nbsp</td></tr>
")
  (mapc (lambda (i) (csrc-insert-sb-item i 0)) csrc-sb-structure)
  (insert "<tr><td >&nbsp</td></tr>

<tr><td class=BAR>

<table cellspacing=0 cellpadding=1 width=100%><tr><td align=left>&lt;&lt;</td>
<td align=center><a href=ftpgate.shtml>Files</a></td>
<td align=right>&gt;&gt;</td>
</tr></table>

</td></tr>
</table>
</td></tr></table>
</tt>
"))

(defvar csrc-sb-structure
  '(
    ( "Tools"
      ( "Simple Setup" . "setup.shtml" )
      ( "Project Management" . "projects.shtml" )
      ( "Smart Completion" . "intellisense.shtml" )
      ( "Find References" . "symref.shtml" )
      ( "Code Generation" . "codegen.shtml" )
      ( "UML Graphs" . "uml.shtml" )
      ;( "Vis Bookmarks" . "visbookmark.shtml" )
      )
    ( "Developer Tools"
      ( "EDE" . "ede.shtml" )
      ( "Semantic" . "semantic.shtml" )
      ( "SRecode" . "srecode.shtml" )
      ( "Cogre" . "cogre.shtml" )
      ( "Speedbar" . "speedbar.shtml" )
      ( "EIEIO" . "eieio.shtml" )
      ( "Misc Tools" . "misc.shtml" )
      )
    ( "Releases"
      "http://sourceforge.net/project/showfiles.php?group_id=17886"
      ( "1.0pre6" . [ release "664893" ] )
      ( "1.0pre4" . [ release "513873" ] )
      )
    ( "Source Forge"
      "http://www.sourceforge.net"
      ( "Project" . "http://www.sourceforge.net/projects/cedet")
      ( "Mailing Lists"
	"http://sourceforge.net/mail/?group_id=17886"
	( "cedet-devel" . [ mail "cedet-devel" ] )
	( "cedet-semantic" . [ mail "cedet-semantic" ] )
	( "cedet-eieio" . [ mail "cedet-eieio" ] )
	)
      ( "Donate" . "http://sourceforge.net/donate/index.php?group_id=17886" )
      )
    ( "More Tools"
      ( "JDEE" . "http://jdee.sf.net" )
      ( "ECB" . "http://ecb.sf.net" )
      ( "CompletionUI" . "http://www.dr-qubit.org/emacs.php" )
      )
    )
  "Structures for the speedbar look-alike nav-bar.")

(defun csrc-insert-sb-item (item level)
  "Insert the speedbar line item in ITEM at LEVEL."
  (let* ((label (car item))
	 (second (cdr item))
	 (url (cond ((stringp second)
		     second)
		    ((vectorp second)
		     (cond
		      ((eq (aref second 0) 'release) (format "http://sourceforge.net/project/showfiles.php?group_id=17886&release_id=%s" (aref second 1)))
		      ((eq (aref second 0) 'mail) (format "http://lists.sourceforge.net/lists/listinfo/%s" (aref second 1)))
		      ))
		    ((and (consp second)
			  (stringp (car second))
			  (consp (car (cdr second))))
		     (car second))))
	 (children (cond ((stringp second)
			  nil)
			 ((and (consp second)
			       (consp (car second)))
			  second)
			 ((and (consp second)
			       (stringp (car second))
			       (consp (car (cdr second))))
			  (cdr second))))
	 )
    ;; Start the line.
    (insert "<tr><td ")
    ;; Level specific icon
    (cond
     ((eq level 0) (insert "class=BAR><img src=dir-minus.gif>&nbsp"))
     ((eq level 1) (insert ">&nbsp<img src=page.gif>&nbsp"))
     ((eq level 2) (insert ">&nbsp&nbsp<img src=tag.png>&nbsp"))
     )
    ;; URL
    (when url
      (insert "<a class=SB href=\"" url "\">"))
    ;; Level specific formatting
    (cond
     ((or (eq level 0) (eq level 1)) (insert "<b>"))
     ((eq level 2) (insert "<b><font size=-1>"))
     )
    ;; Label
    (insert label)
    ;; Level specific formatting close
    (cond
     ((or (eq level 0) (eq level 1)) (insert "</b>"))
     ((eq level 2) (insert "</font></b>"))
     )
    ;; URL Close
    (when url
      (insert "</a>"))
    ;; Tail
    (insert "</a>&nbsp</td></tr>\n")
    ;; Do the children
    (mapc (lambda (i) (csrc-insert-sb-item i (+ level 1))) children)
    ))


(provide 'cedet-src)
;;; cedet-src.el ends here
