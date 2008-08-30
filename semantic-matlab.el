;;; semantic-matlab.el --- Semantic details for MATLAB files

;;; Copyright (C) 2004, 2005, 2008 Eric M. Ludlam: The Mathworks, Inc

;; Author: Eric M. Ludlam <eludlam@mathworks.com>
;; X-RCS: $Id$

;; This file is not part of GNU Emacs.

;; This is free software; you can redistribute it and/or modify
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
;; Parse a MATLAB M file for use w/ CEDET/Semantic
;;
;; The MATLAB language is pretty simple from a functional standpoint in that
;; you can only declare functions.  In addition, the language itself is not
;; expressable in a yacc style grammar.  It is therefore more expedient
;; to scan for regular expressions.
;;
;; Caveat: MCOS classes have property declarations. @todo - support them

(require 'semantic)
(require 'semantic-format)
(require 'matlab)
(condition-case nil
    ;; This will eventually become available.
    (require 'semanticdb-matlab)
  (error nil))

;;; Code:
(defvar semantic-matlab-root-directory
  (let* ((mlab (locate-file "matlab" exec-path))
	 (mlint mlint-program)
	 (dir (cond (mlab
		     (file-name-directory mlab))
		    (mlint
		     (file-name-directory mlint))
		    )))
    ;; We have a dir.  Walk up to the root of the install by two steps
    ;; for either of these hits.
    (file-name-directory
     (directory-file-name
      (file-name-directory (directory-file-name dir))))
    )
  "Root directory of MATLAB installation.
Used for determining the include path.")

;; The version of this variable in MATLAB.el is not condusive to extracting
;; the information we need.
(defvar semantic-matlab-match-function-re
  "\\(^\\s-*function\\b[ \t\n.]*\\)\\(\\[[^]]+\\]\\s-*=\\|\\w+\\s-*=\\|\\)\\s-*\\(\\(\\sw\\|\\s_\\)+\\)\\>"
  "Expression to match a function start line.")

;; This function may someday be a part of matlab.el.
;; It does the raw scan and split for function tags.
(defun semantic-matlab-function-tags (&optional buffer)
  "Find all MATLAB function tags in BUFFER.
Return argument is:
  (START END RETURNVARS NAME ARGUMENTS DOCSTRING).
Note that builtin functions from MATLAB will always return
START=END=0 and no arguments or return values."
  (save-excursion
    (if buffer (set-buffer buffer))
    (let ((re semantic-matlab-match-function-re)
	  start ret fn arg end doc
	  (taglist nil)
	  )
      (goto-char (point-min))
      (if (and (string-match (format "^%s" semantic-matlab-root-directory)
			     (buffer-file-name))
	       (looking-at "%\\([A-Z]+\\) \\(.*\\)"))
	  ;; This is a builtin function, ie there's no function line.
	  ;; Hence we must use function name from the doc string.
	  ;; FIXME
	  ;; How can we get function arguments/return vals for builtin func's?
	  (setq taglist
		(cons (list 0 0 nil (downcase (match-string-no-properties 1))
			    nil (match-string-no-properties 2)
			    )
		      taglist))
	;; this is a either not builtin or a user function
	(while (re-search-forward re nil t)
	  (setq start (match-beginning 0)
		ret (buffer-substring-no-properties
		     (match-beginning 2) (match-end 2))
		fn (buffer-substring-no-properties
		    (match-beginning 3) (match-end 3))
		arg (buffer-substring-no-properties
		     (match-end 3) (save-excursion
				     (matlab-end-of-command)
				     (point)))
		doc (save-excursion
		      (forward-line)
		      (beginning-of-line)
		      (if (looking-at "%[A-Z]+ \\(.*\\)")
			  (match-string-no-properties 1)
			nil))
		end (save-excursion
		      (goto-char start)
		      (if matlab-functions-have-end
			  (condition-case nil
			      ;; If we get a failure, we should at least
			      ;; return whatever we got so far.
			      (matlab-forward-sexp)
			    (error (point-max)))
			(matlab-end-of-defun))
		      (point)))
	  (setq taglist
		(cons (list start end
			    (split-string ret "[][,=. \t\n]+" t)
			    fn
			    (split-string arg "[(), \n\t.]+" t)
			    doc
			    )
		      taglist))))
	(nreverse taglist))))

;;; BEGIN PARSER
;;
(defun semantic-matlab-parse-region (&rest ignore)
  "Parse the current MATLAB buffer for function definitions.
IGNORE any arguments which specify a subregion to parse.
Each tag returned is a semantic FUNCTION tag.  See
`semantic-tag-new-function'."
  (let ((raw (condition-case nil
		 ;; Errors from here ought not to be propagated.
		 (semantic-matlab-parse-functions)
	       (error nil))))
    (mapcar 'semantic-matlab-expand-tag raw)))

(defun semantic-matlab-parse-changes ()
  "Parse all changes for the current MATLAB buffer."
  ;; NOTE: For now, just schedule a full reparse.
  ;;       To be implemented later.
  (semantic-parse-tree-set-needs-rebuild))

(defun semantic-matlab-expand-tag (tag)
  "Expand the MATLAB function tag TAG."
  (let ((chil (semantic-tag-components-with-overlays tag)))
    (if chil
        (semantic-tag-put-attribute
         tag :members (mapcar 'semantic-matlab-expand-tag chil)))
    (car (semantic--tag-expand tag))))

(defun semantic-matlab-parse-functions ()
  "Parse all functions from the current MATLAB buffer."
  (car
   (semantic-matlab-sort-raw-tags (semantic-matlab-function-tags)
				  (point-max))
   ))

(defun semantic-matlab-sort-raw-tags (tag-list &optional end)
  "Return a split list of tags from TAG-LIST before END.
Return list is:
  (TAGS-BEFORE-END REMAINING-TAGS)"
  (let ((newlist nil)
	(rest tag-list))
    ;; Loop until there are no more tags, or no tags before END.
    (while (and tag-list (> end (car (car tag-list))))
      (let* ((tag (car tag-list))
	     (start (car tag))
	     (end (nth 1 tag))
	     (ret (nth 2 tag))
	     (name (nth 3 tag))
	     (args (nth 4 tag))
	     (doc (nth 5 tag))
	     (parts (semantic-matlab-sort-raw-tags (cdr tag-list) end))
	     (chil (car parts)))
	(setq rest (car (cdr parts)))
	(setq newlist
	      (cons (append
		     (semantic-tag-new-function name nil args
						:return ret
						:subfunctions chil
						:documentation doc)
		     (list start end))
		    newlist))
	(setq tag-list rest)))
    (list (nreverse newlist) tag-list)))

(define-mode-local-override semantic-tag-components-with-overlays
  matlab-mode (tag)
  "Return the list of subfunctions in TAG."
  (semantic-tag-get-attribute tag :subfunctions))

(defcustom-mode-local-semantic-dependency-system-include-path
  matlab-mode semantic-matlab-dependency-system-include-path
  (list
   (concat (file-name-as-directory semantic-matlab-root-directory)
	   "toolbox/matlab"))
  "The system include paths from MATLAB.")

(defvar semantic-matlab-display-docstring t
  "Flag if function documentation should be displayed after completion.")

(define-mode-local-override semantic-ia-insert-tag
  matlab-mode (tag)
  "Insert TAG into the current buffer based on completion."
  (insert (semantic-tag-name tag))
  (let ((name (semantic-tag-name tag))
	(tt (semantic-tag-class tag))
	(args (semantic-tag-function-arguments tag))
	(doc (semantic-tag-docstring tag)))
    (when (and (eq tt 'function)
	       args)
      (insert "("))
    (when semantic-matlab-display-docstring
      (if (null args)
	  (setq args "()")
	(setq args (format "%S" args))
	(while (string-match "\"" args)
	  (setq args (replace-match "" t t args)))
	(while (string-match " " args)
	  (setq args (replace-match "," t t args))))
      (message "%s %s : %s" name args doc))))

;;;###autoload
(defun semantic-default-matlab-setup ()
  "Set up a buffer for parsing of MATLAB files."
  ;; This will use our parser.
  (semantic-install-function-overrides
   '((parse-region . semantic-matlab-parse-region)
     (parse-changes . semantic-matlab-parse-changes)))
  (setq semantic-parser-name "MATLAB"
        ;; Setup a dummy parser table to enable parsing!
        semantic--parse-table t
        imenu-create-index-function 'semantic-create-imenu-index
	;; semantic-command-separation-character "."
	semantic-type-relation-separator-character '(".")
	semantic-symbol->name-assoc-list '((function . "Function")
					   )
	semantic-imenu-expandable-tag-classes '(function)
	semantic-imenu-bucketize-file nil
	semantic-imenu-bucketize-type-members nil
	senator-step-at-start-end-tag-classes '(function)
	semantic-stickyfunc-sticky-classes '(function)
	)
  )

;; Enable this autoload once versions of matlab.el are synchronized and
;; generally available.
;;;###autoload
(add-hook 'matlab-mode-hook 'semantic-default-matlab-setup)

(provide 'semantic-matlab)

;;; semantic-matlab.el ends here