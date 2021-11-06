;;; tree-edit.el --- Description -*- lexical-binding: t; -*-
;;
;; Copyright (C) Ethan Leba <https://github.com/ethan-leba>
;;
;; Author: Ethan Leba <ethanleba5@gmail.com>
;; Version: 0.1.0
;; Homepage: https://github.com/ethan-leba/tree-edit
;; Package-Requires: ((emacs "27.0") (tree-sitter "0.15.0") (tree-sitter-langs "0.10.0") (dash "2.19") (evil "1.0.0") (avy "0.5.0") (reazon "0.4.0") (s "0.0.0"))
;; SPDX-License-Identifier: MIT
;;
;; This file is not part of GNU Emacs.
;;
;;; Commentary:
;;
;;  Structural editing in Emacs for any language supported by tree-sitter.
;;
;;; Code:
;;* Requires
(require 'tree-sitter)
(require 'evil)
(require 'dash)
(require 'reazon)
(require 'avy)
(require 's)

;;* Internal variables
(defvar-local tree-edit--current-node nil
  "The current node to apply editing commands to.")
(defvar-local tree-edit--node-overlay nil
  "The display overlay to show the current node.")
(defvar-local tree-edit--return-to-tree-state nil
  "Whether tree state should be returned to after exiting insert mode.")

(defvar tree-edit-grammar nil
  "The grammar rules generated by tree-sitter. Set by mode-local grammar file.")
(defvar tree-edit--supertypes nil
  "A mapping from type to supertype, i.e. if_statement is a statement. Set by mode-local grammar file.")
(defvar tree-edit--subtypes nil
  "A mapping from type to subtype, i.e. statement is subtyped by if_statement. Set by mode-local grammar file.")
(defvar tree-edit--containing-types nil
  "A mapping from a type to all possible types that can exist as it's children. Set by mode-local grammar file.")
(defvar tree-edit--identifier-regex nil
  "The regex used to determine if a string is an identifier. Set by mode-local grammar file.")
(defvar tree-edit-significant-node-types nil
  "List of nodes that are considered significant, like methods or classes. Set by mode-local grammar file.")
(defvar tree-edit-semantic-snippets nil
  "Snippets for constructing nodes. Set by mode-local grammar file.

Must be an alist of node type (as a symbol) to list, where the list can
contain any string or a symbol referencing another node type in the alist.")

(defvar tree-edit-nodes nil
  "Nodes that a user can create via tree-edit. Set by mode-local grammar file.

Must be a list of plists, with the following properties:

Properties
  :type           the node's type
  :key            the keybinding for the given node
  :name           human readable name for which-key, defaults to
                  :type if left unset
  :node-override  overrides semantic snippets for the verb
  :wrap-override  overrides semantic snippets for the verb when wrapping")


(defvar tree-edit-mode-map (make-sparse-keymap))

;;* User settings
(defgroup tree-edit nil
  "Structural editing for tree-sitter languages."
  :group 'bindings
  :prefix "tree-edit-")

(defcustom tree-edit-query-timeout 0.1
  "How long a query should take before giving up."
  :type 'float
  :group 'tree-edit)
(defcustom tree-edit-movement-hook nil
  "Functions to call after a tree-edit movement command has been issued."
  :type 'hook
  :group 'tree-edit)
(defcustom tree-edit-after-change-hook nil
  "Functions to call after a tree-edit command modifies the buffer."
  :type 'hook
  :group 'tree-edit)

;;* Utilities
(defun tree-edit--boring-nodep (node)
  "Check if the NODE is not a named node."
  (and (tsc-node-p node) (not (tsc-node-named-p node))))

(defun tree-edit--relevant-types (type parent-type)
  "Return a list of the TYPE and all it's supertypes that occur in PARENT-TYPE.

Return cached result for TYPE and PARENT-TYPE, otherwise compute and return."
  (-intersection
   (alist-get type tree-edit--supertypes)
   (alist-get parent-type tree-edit--containing-types)))

;;* Locals: navigation
(defun tree-edit--get-current-index (node)
  "Return a pair containing the siblings of the NODE and the index of itself."
  (let* ((parent (tsc-get-parent node))
         (pnodes (--map (tsc-get-nth-named-child parent it)
                        (number-sequence 0 (1- (tsc-count-named-children parent))))))
    (--find-index (equal (tsc-node-position-range node) (tsc-node-position-range it)) pnodes)))

(defun tree-edit--save-location (node)
  "Save the current location of the NODE."
  (cons (tsc--node-steps (tsc-get-parent node))
        (tree-edit--get-current-index node)))

(defun tree-edit--restore-location (location movement)
  "Restore the current node to LOCATION, moving MOVEMENT siblings.

If node no longer exists, the location will not be set."
  (condition-case nil
      (let* ((steps (car location))
             (child-index (cdr location))
             (recovered-parent (tsc--node-from-steps tree-sitter-tree steps))
             (num-children (tsc-count-named-children recovered-parent)))
        (setq tree-edit--current-node
              (if (equal num-children 0) recovered-parent
                (tsc-get-nth-named-child recovered-parent
                                         (min (max (+ child-index movement) 0) (1- num-children)))))
        (tree-edit--update-overlay))
    (tsc--invalid-node-step (message "Tree-edit could not restore location"))))

(defmacro tree-edit--preserve-location (node movement &rest body)
  "Preserves the location of NODE during the execution of the BODY.

Optionally applies a MOVEMENT to the node after restoration,
moving the sibling index by the provided value."
  (declare (indent 2)
           (debug t))
  (let ((location-sym (gensym "location")))
    `(let ((,location-sym (tree-edit--save-location ,node)))
       ,@body
       (run-hooks 'tree-edit-after-change-hook)
       (tree-edit--restore-location ,location-sym ,movement))))

(defun tree-edit--update-overlay ()
  "Update the display of the current selected node, and move the cursor."
  (move-overlay tree-edit--node-overlay
                (tsc-node-start-position tree-edit--current-node)
                (tsc-node-end-position tree-edit--current-node))
  (goto-char (tsc-node-start-position tree-edit--current-node))
  (run-hooks 'tree-edit-movement-hook))

(defun tree-edit--apply-until-interesting (fun node)
  "Apply FUN to NODE until a named node is hit."
  (let ((parent (funcall fun node)))
    (if (tree-edit--boring-nodep parent)
        (tree-edit--apply-until-interesting fun parent)
      parent)))

(defun tree-edit-query (patterns)
  "Execute query PATTERNS against the current syntax tree and return captures.

TODO: Build queries and cursors once, then reuse them?"
  (let* ((query (tsc-make-query tree-sitter-language patterns)))
    (seq-map (lambda (capture) (cons (tsc-node-start-position (cdr capture)) (cdr capture)))
             (tsc-query-captures query tree-edit--current-node #'tsc--buffer-substring-no-properties))))

(defun tree-edit--sig-up (node)
  "Move NODE to the next (interesting) named sibling."
  (interactive)
  (setq node (tsc-get-parent node))
  (while (not (member (tsc-node-type node) tree-edit-significant-node-types))
    (setq node (tsc-get-parent node)))
  node)

(defun tree-edit--apply-movement (fun)
  "Apply movement FUN, and then update the node position and display."
  (when-let ((new-pos (tree-edit--apply-until-interesting fun tree-edit--current-node)))
    (setq tree-edit--current-node new-pos)
    (tree-edit--update-overlay)))

;;* Globals: navigation
(defun tree-edit-up ()
  "Move to the next (interesting) named sibling."
  (interactive)
  (tree-edit--apply-movement #'tsc-get-next-named-sibling))

(defun tree-edit-down ()
  "Move to the previous (interesting) named sibling."
  (interactive)
  (tree-edit--apply-movement #'tsc-get-prev-named-sibling))

(defun tree-edit-left ()
  "Move to the up to the next interesting parent."
  (interactive)
  (tree-edit--apply-movement #'tsc-get-parent))

(defun tree-edit-right ()
  "Move to the first child, unless it's an only child."
  (interactive)
  (tree-edit--apply-movement (lambda (node) (tsc-get-nth-named-child node 0))))

(defun tree-edit-sig-up ()
  "Move to the next (interesting) named sibling."
  (interactive)
  (tree-edit--apply-movement #'tree-edit--sig-up))

(defun tree-edit-avy-jump (node-type &optional pred)
  "Avy jump to a node with the NODE-TYPE and filter the node with PRED.

PRED will receive a pair of (position . node).
NODE-TYPE can be a symbol or a list of symbol."
  (interactive)
  (let* ((node-type (if (listp node-type) node-type `(,node-type)))
         ;; Querying needs a @name for unknown reasons
         (query-string
          (format "[%s] @foo"
                  (-as-> node-type %
                         (-mapcat (lambda (x) (alist-get x tree-edit--subtypes)) %)
                         ;; FIXME
                         (-uniq %)
                         (--remove (or (equal it 'yield_statement)
                                       (equal it 'switch_expression)
                                       (string-prefix-p "_" (symbol-name it))) %)

                         (--map (format "(%s)" it) %)
                         (string-join % " "))))
         (position->node
          (-filter (or pred (-const t))
                   (-remove-first (-lambda ((pos . _))
                                    (equal pos (tsc-node-start-position tree-edit--current-node)))
                                  (tree-edit-query query-string))))
         ;; avy-action declares what should be done with the result of avy-process
         (avy-action (lambda (pos)
                       (setq tree-edit--current-node (alist-get pos position->node))
                       (tree-edit--update-overlay))))
    (cond ((not position->node) (user-error "Nothing to jump to!"))
          ((equal (length position->node) 1) (funcall avy-action (caar position->node)))
          (t (avy-process (-map #'car position->node))))))

;;* Locals: node transformations
(defun tree-edit--get-only-child (node)
  "Assert that NODE has exactly one child, and return it."
  (if (equal (tsc-count-named-children node) 1)
      (tsc-get-nth-named-child node 0)
    (throw 'fragment-type nil)))

;; Error recovery seems to be a bit arbitrary:
;; - "foo.readl" in java parses as (program (expression_statement (...) (MISSING \";\")))
;; - "foo.read" in java parses as (program (ERROR (...)))
(defun tree-edit--type-of-fragment (s)
  "Try to identify the node-type of the fragment S.

Fragments should parse as one of the following structures:
- (program (type))
- (program (ERROR (type))
- (program (... (type) (MISSING ...))"
  (catch 'fragment-type
    (let ((first-node (tree-edit--get-only-child
                       (tsc-root-node (tsc-parse-string tree-sitter-parser s)))))
      (if (tsc-node-has-error-p first-node)
          (tsc-node-type (tree-edit--get-only-child first-node))
        (tsc-node-type first-node)))))

(defun tree-edit--get-tokens ()
  "Expand TYPE (if abstract) into concrete list of nodes."
  (--map (tsc-node-type (tsc-get-nth-child tree-edit--current-node it))
         (number-sequence 0 (1- (tsc-count-children tree-edit--current-node)))))

(defun tree-edit--get-all-children (node)
  "Return all of NODE's children."
  (--map (tsc-get-nth-child node it)
         (number-sequence 0 (1- (tsc-count-children node)))))

(defun tree-edit--get-parent-tokens (node)
  "Return a pair containing the siblings of the NODE and the index of itself."
  (let* ((parent (tsc-get-parent node))
         (children (tree-edit--get-all-children parent)))
    (cons (-map #'tsc-node-type children)
          (--find-index (equal (tsc-node-position-range node) (tsc-node-position-range it)) children))))

;; TODO: Handle less restrictively by ripping out surrounding syntax (ie delete)
(defun tree-edit--valid-replacement-p (type node)
  "Return non-nil if the NODE can be replaced with a node of the provided TYPE."
  (-let* ((reazon-occurs-check nil)
          (parent-type (tsc-node-type (tsc-get-parent node)))
          (grammar (alist-get parent-type tree-edit-grammar))
          ((children . index) (tree-edit--get-parent-tokens node))
          ;; removing the selected element
          ((left (_ . right)) (-split-at index children))
          (supertype (tree-edit--relevant-types type parent-type)))
    (if-let (result (reazon-run 1 q
                      (reazon-fresh (tokens qr ql)
                        (tree-edit-superpositiono right qr parent-type)
                        (tree-edit-superpositiono left ql parent-type)
                        (tree-edit-max-lengtho q 3)
                        ;; FIXME: this should be limited to only 1 new named node, of the requested type
                        (tree-edit-includes-typeo q supertype)
                        (tree-edit-prefixpostfix ql q qr tokens)
                        (tree-edit-parseo grammar tokens '()))))
        ;; TODO: Put this in the query
        ;; Rejecting multi-node solutions
        (if (equal (length (car result)) 1)
            (--reduce-from (-replace it type acc) (car result) supertype)))))

(defun tree-edit--find-raise-ancestor (ancestor child-type)
  "Find a suitable ANCESTOR to be replaced with a node of CHILD-TYPE."
  (interactive)
  (cond
   ((not (and ancestor (tsc-get-parent ancestor))) (user-error "Can't raise node!"))
   ((tree-edit--valid-replacement-p child-type ancestor) ancestor)
   (t (tree-edit--find-raise-ancestor (tsc-get-parent ancestor) child-type))))

;; TODO: Refactor commonalities between syntax generators
(defun tree-edit--valid-insertions (type after &optional node)
  "Return a valid sequence of tokens containing the provided TYPE, or nil.

If AFTER is t, generate the tokens after NODE, otherwise before."
  (-let* ((reazon-occurs-check nil)
          (node (or node tree-edit--current-node))
          (parent-type (tsc-node-type (tsc-get-parent node)))
          (grammar (alist-get parent-type tree-edit-grammar))
          ((children . index) (tree-edit--get-parent-tokens node))
          ((left right) (-split-at (+ index (if after 1 0)) children))
          (supertype (tree-edit--relevant-types type parent-type)))
    (if-let (result (reazon-run 1 q
                      (reazon-fresh (tokens qr ql)
                        (tree-edit-superpositiono right qr parent-type)
                        (tree-edit-superpositiono left ql parent-type)
                        (tree-edit-max-lengtho q 5)
                        (tree-edit-prefixpostfix ql q qr tokens)
                        ;; FIXME: this should be limited to only 1 new named node, of the requested type
                        (tree-edit-includes-typeo q supertype)
                        (tree-edit-parseo grammar tokens '()))))
        (--reduce-from (-replace it type acc)
                       (car result)
                       supertype)
      (user-error "Cannot insert %s" type))))

(defun tree-edit--remove-node-and-surrounding-syntax (tokens idx)
  "Return a pair of indices to remove the node at IDX in TOKENS and all surrounding syntax."
  (let ((end (1+ idx))
        (start (1- idx)))
    (while (stringp (nth end tokens))
      (setq end (1+ end)))
    (while (and (>= start 0) (stringp (nth start tokens)))
      (setq start (1- start)))
    (cons (1+ start) end)))

(defun tree-edit--valid-deletions (&optional node)
  "Return a set of edits if NODE can be deleted, else nil.

If successful, the return type will give a range of siblings to
delete, and what syntax needs to be inserted after, if any."
  (let* ((node (or node tree-edit--current-node))
         (reazon-occurs-check nil)
         (parent-type (tsc-node-type (tsc-get-parent node)))
         (grammar (alist-get
                   (tsc-node-type (tsc-get-parent node))
                   tree-edit-grammar))
         (current (tree-edit--get-parent-tokens node))
         (split (tree-edit--remove-node-and-surrounding-syntax
                  (car current) (cdr current)))
         (left-idx (car split))
         (left (-take left-idx (car current)))
         (right-idx (cdr split))
         (right (-drop right-idx (car current)))
         (nodes-deleted (- right-idx left-idx)))
    ;; FIXME: Q should be only string types, aka syntax -- we're banking that
    ;;        the first thing reazon stumbles upon is syntax.
    (if-let ((result (reazon-run 1 q
                       (reazon-fresh (tokens qr ql)
                         (tree-edit-superpositiono right qr parent-type)
                         (tree-edit-superpositiono left ql parent-type)
                         ;; Prevent nodes from being 'deleted' by putting the exact same thing back
                         (tree-edit-max-lengtho q (1- nodes-deleted))
                         (tree-edit-prefixpostfix ql q qr tokens)
                         (tree-edit-parseo grammar tokens '())))))
        (if (-every-p #'stringp (car result))
            `(,left-idx ,(1- right-idx) ,(car result))))))

;;* Locals: node generation and rendering
(defun tree-edit-make-node (node-type rules &optional fragment)
  "Given a NODE-TYPE and a set of RULES, generate a node string.

If FRAGMENT is passed in, that will be used as a basis for node
construction, instead of looking up the rules for node-type."
  (interactive)
  (tree-edit--render-node (tree-edit--generate-node node-type rules fragment)))

(defun tree-edit--adhoc-pcre-to-rx (pcre)
  "Convert PCRE to an elisp regex (in no way robust)

pcre2el package doesn't support character classes, so can't use that.
Upstream patch?"
  (s-replace-all '(("\\p{L}" . "[:alpha:]")
                   ("\\p{Nd}" . "[:digit:]")) pcre))

(defun tree-edit--generate-node (node-type rules &optional fragment)
  "Given a NODE-TYPE and a set of RULES, generate a node string.

If FRAGMENT is passed in, that will be used as a basis for node
construction, instead of looking up the rules for node-type."
  (interactive)
  (--mapcat (if (symbolp it) (tree-edit--generate-node it rules) `(,it))
            ;; TODO: See if we can make it via. the parser?
            (or fragment (alist-get node-type rules) (user-error "No node definition for %s" node-type))))

(defun tree-edit--needs-space-p (left right)
  "Check if the two tokens LEFT and RIGHT need a space between them.

https://tree-sitter.github.io/tree-sitter/creating-parsers#keyword-extraction"
  (let ((regex (tree-edit--adhoc-pcre-to-rx tree-edit--identifier-regex)))
    (< (length (s-matched-positions-all regex (string-join `(,left ,right))))
       (+ (length (s-matched-positions-all regex left))
          (length (s-matched-positions-all regex right))))))

(defun tree-edit--render-node (tokens)
  "Combine TOKENS into a string, properly spacing as needed."
  (string-join
   (--mapcat
    (pcase-let ((`(,prev . ,current) it))
      (cond ((not current) '())
            ((and prev (tree-edit--needs-space-p prev current))
             `(" " ,current))
            (t `(,current))))
    (-zip `(,nil ,@tokens)
          `(,@tokens nil)))))

(defun tree-edit--node-text-with-whitespace (siblings)
  "Retrieve the node text for all SIBLINGS, including whitespace.

Retrieves text from node's start until before the beginning of it's next sibling."
  (--map-indexed (if (< it-index (1- (length siblings)))
                     (buffer-substring-no-properties
                      (tsc-node-start-position it)
                      (tsc-node-start-position (nth (1+ it-index) siblings)))
                   (tsc-node-text it))
                 siblings))

(defun tree-edit--replace-fragment (fragment node l r)
  "Replace the nodes between L and R with the FRAGMENT NODE."
  (-let* ((parent (tsc-get-parent node))
          (children (tree-edit--get-all-children parent))
          (children-text (tree-edit--node-text-with-whitespace children))
          (children-text (append (-slice children-text 0 l)
                                 (-slice children-text r (length children-text))))
          ((left right) (-split-at l children-text))
          (render-fragment
           (if fragment (tree-edit--generate-node
                         (tsc-node-type (tsc-get-parent node))
                         tree-edit-semantic-snippets
                         fragment) ""))
          (reconstructed-node (tree-edit--render-node (append left (if fragment render-fragment) right))))
    (goto-char (tsc-node-start-position parent))
    (delete-region (tsc-node-start-position parent)
                   (tsc-node-end-position parent))
    (insert reconstructed-node)))

(defun tree-edit--insert-fragment (fragment node position)
  "Insert rendered FRAGMENT at NODE in the provided POSITION.

POSITION can be :before, :after, or nil."
  ;; XXX: i don't think this accounts for word rules
  (-let* ((parent (tsc-get-parent node))
          (children (tree-edit--get-all-children parent))
          (children-text (tree-edit--node-text-with-whitespace children))
          (node-index (--find-index (equal (tsc-node-position-range node)
                                           (tsc-node-position-range it))
                                    children))
          ((left right) (if children-text
                            (-split-at (min (1- (length children-text))
                                            (+ node-index (if (equal position :after) 1 0))) children-text)))
          (render-fragment
           (if fragment (tree-edit--generate-node
                         (tsc-node-type (tsc-get-parent node))
                         tree-edit-semantic-snippets
                         fragment) ""))
          (reconstructed-node (tree-edit--render-node (append left (if fragment render-fragment) right))))
    ;; HACK
    (delete-region (tsc-node-start-position parent)
                   (tsc-node-end-position parent))
    (insert reconstructed-node)))

;;* Globals: Node transformation and generation
(defun tree-edit-change-node ()
  "Change the current node."
  (interactive)
  (setq tree-edit--return-to-tree-state (tree-edit--save-location tree-edit--current-node))
  (delete-region (tsc-node-start-position tree-edit--current-node)
                 (tsc-node-end-position tree-edit--current-node))
  (evil-change-state 'insert))

(defun tree-edit--re-enter-tree-state ()
  "Change the current node."
  (when tree-edit--return-to-tree-state
    (evil-tree-state)
    (tree-edit--restore-location tree-edit--return-to-tree-state 0)
    (setq tree-edit--return-to-tree-state nil)))

(add-hook 'evil-normal-state-entry-hook #'tree-edit--re-enter-tree-state)

(defun tree-edit-copy ()
  "Copy the current node."
  (interactive)
  (kill-ring-save (tsc-node-start-position tree-edit--current-node)
                  (tsc-node-end-position tree-edit--current-node)))

(defun tree-edit-exchange-node (type-or-text)
  "Exchange the current node for the given TYPE-OR-TEXT.

If TYPE-OR-TEXT is a string, the tree-edit will attempt to infer the type of
the text."
  (interactive)
  (let ((type (if (symbolp type-or-text) type-or-text
                (tree-edit--type-of-fragment type-or-text))))
    (unless (tree-edit--valid-replacement-p type tree-edit--current-node)
      (user-error "Cannot replace the current node with type %s!" type))
    (tree-edit--preserve-location tree-edit--current-node 0
      (delete-region (tsc-node-start-position tree-edit--current-node)
                     (tsc-node-end-position tree-edit--current-node))
      (insert (if (symbolp type-or-text)
                  (tree-edit-make-node type tree-edit-semantic-snippets)
                type-or-text)))))

(defun tree-edit-raise ()
  "Move the current node up the syntax tree until a valid replacement is found."
  (interactive)
  (let ((ancestor-to-replace (tree-edit--find-raise-ancestor
                              (tsc-get-parent tree-edit--current-node)
                              (tsc-node-type tree-edit--current-node))))
    (tree-edit--preserve-location ancestor-to-replace 0
      (let ((node-text (tsc-node-text tree-edit--current-node)))
        (delete-region (tsc-node-start-position ancestor-to-replace)
                       (tsc-node-end-position ancestor-to-replace))
        (insert node-text)))))

(defun tree-edit-insert-sibling (type-or-text &optional before node)
  "Insert a node of the given TYPE-OR-TEXT next to NODE.

if BEFORE is t, the sibling node will be inserted before the
current, otherwise after."
  (interactive)
  (let* ((node (or node tree-edit--current-node))
         (type (if (symbolp type-or-text) type-or-text
                 (tree-edit--type-of-fragment type-or-text)))
         (fragment (tree-edit--valid-insertions type (not before) node))
         (fragment (if (symbolp type-or-text) fragment (-replace-first type type-or-text fragment))))
    (tree-edit--preserve-location node (if before 0 1)
      (tree-edit--insert-fragment fragment node (if before :before :after)))))

(defun tree-edit-insert-sibling-before (type)
  "Insert a node of the given TYPE before the current."
  (interactive)
  (tree-edit-insert-sibling type t))

(defun tree-edit-insert-child (type-or-text &optional node)
  "Insert a node of the given TYPE-OR-TEXT inside of NODE."
  (interactive)
  ;; FIXME: Can't use insert-sibling in the body, since preserve-location breaks on unnamed nodes
  (let ((node (or node tree-edit--current-node)))
    (tree-edit--preserve-location node 0
      (let* ((node (tsc-get-nth-child node 0))
             (type (if (symbolp type-or-text) type-or-text
                     (tree-edit--type-of-fragment type-or-text)))
             (fragment (tree-edit--valid-insertions type t node))
             (fragment (if (symbolp type-or-text) fragment (-replace-first type type-or-text fragment))))
        (tree-edit--insert-fragment fragment node :after))))
  (tree-edit-right))

(defun tree-edit-slurp ()
  "Transform NODE's next sibling into it's leftmost child, if possible."
  (interactive)
  (let ((slurp-candidate (tsc-get-next-named-sibling (tsc-get-parent tree-edit--current-node))))
    (cond ((not slurp-candidate) (user-error "Nothing to slurp!"))
          ;; No named children, use insert child
          ((equal (tsc-count-named-children tree-edit--current-node) 0)
           (let ((slurper tree-edit--current-node))
             (unless (tree-edit--valid-deletions slurp-candidate)
               (user-error "Cannot delete %s!" (tsc-node-text slurp-candidate)))
             (unless (tree-edit--valid-insertions (tsc-node-type slurp-candidate)
                                                  t
                                                  (tsc-get-nth-child tree-edit--current-node 0))
               (user-error "Cannot add %s into %s!"
                           (tsc-node-text slurp-candidate)
                           (tsc-node-type tree-edit--current-node)))
             (let ((slurp-text (tsc-node-text slurp-candidate)))
               (tree-edit--preserve-location tree-edit--current-node 0
                 (tree-edit-delete-node slurp-candidate)
                 (tree-edit-insert-child slurp-text slurper)))))
          ;; Named children, use insert sibling
          (t
           (let ((slurper
                  (tsc-get-nth-named-child tree-edit--current-node
                                           (1- (tsc-count-named-children tree-edit--current-node)))))
             (unless (tree-edit--valid-deletions slurp-candidate)
               (user-error "Cannot delete %s!" (tsc-node-text slurp-candidate)))
             (unless (tree-edit--valid-insertions
                      (tsc-node-type slurp-candidate) t
                      slurper)
               ;; FIXME
               (user-error "Cannot add %s into %s!"
                           (tsc-node-text slurp-candidate)
                           (tsc-node-type tree-edit--current-node)))
             (let ((slurp-text (tsc-node-text slurp-candidate)))
               (tree-edit--preserve-location tree-edit--current-node 0
                 (tree-edit-delete-node slurp-candidate)
                 (tree-edit-insert-sibling slurp-text nil slurper))))))))

(defun tree-edit-barf ()
  "Transform NODE's leftmost child into it's next sibling, if possible."
  (interactive)
  (unless (> (tsc-count-named-children tree-edit--current-node) 0)
    (user-error "Cannot barf a node with no named children!"))
  (let* ((barfee (tsc-get-nth-named-child tree-edit--current-node
                                          (1- (tsc-count-named-children tree-edit--current-node))))
         (barfer (tsc-get-parent tree-edit--current-node))
         ;; FIXME: need to get refreshed node
         (barfer-steps (tsc--node-steps barfer)))
    (unless (tree-edit--valid-deletions barfee)
      (user-error "Cannot delete %s!" (tsc-node-text barfee)))
    (unless (tree-edit--valid-insertions (tsc-node-type barfer)
                                         t
                                         (tsc-get-nth-child tree-edit--current-node 0))
      (user-error "Cannot add %s into %s!"
                  (tsc-node-text barfer)
                  (tsc-node-type tree-edit--current-node)))
    (let ((barfee-text (tsc-node-text barfee)))
      (tree-edit--preserve-location tree-edit--current-node 0
        (tree-edit-delete-node barfee)
        (tree-edit-insert-sibling barfee-text nil (tsc--node-from-steps tree-sitter-tree barfer-steps))))))

(defun tree-edit-wrap-node (type)
  "Wrap the current node in a node of selected TYPE."
  (tree-edit--preserve-location tree-edit--current-node 0
    (let ((node-text (tsc-node-text tree-edit--current-node)))
      (tree-edit-exchange-node type)
      (unwind-protect
          (tree-edit-avy-jump (alist-get type tree-edit--supertypes)
                              (-lambda ((_ . node)) (tree-edit--valid-replacement-p type node)))
        (tree-edit-exchange-node node-text)))))

(defun tree-edit-delete-node (&optional node)
  "Delete NODE, and any surrounding syntax that accompanies it."
  (interactive)
  (let ((node (or node tree-edit--current-node)))
    (pcase-let ((`(,start ,end ,fragment)
                 (or (tree-edit--valid-deletions node)
                     (user-error "Cannot delete the current node"))))
      (tree-edit--preserve-location node 0
        (tree-edit--replace-fragment fragment node start (1+ end))))))


;;* Locals: Relational parser
(reazon-defrel tree-edit-parseo (grammar tokens out)
  "TOKENS are a valid prefix of a node in GRAMMAR and OUT is unused tokens in TOKENS."
  (reazon-disj
   (reazon-fresh (next)
     (tree-edit-takeo 'comment tokens next)
     (tree-edit-parseo grammar next out))
   (pcase grammar
     (`((type . "STRING")
        (value . ,value))
      (tree-edit-takeo value tokens out))
     (`((type . "PATTERN")
        (value . ,_))
      (tree-edit-takeo :regex tokens out))
     (`((type . "BLANK"))
      (reazon-== tokens out))
     ((and `((type . ,type)
             (value . ,_)
             (content . ,content))
           (guard (s-starts-with-p "PREC" type)))
      ;; Silence the foolish linter.
      (ignore type)
      (tree-edit-parseo content tokens out))
     (`((type . "TOKEN")
        (content . ,content))
      (tree-edit-parseo content tokens out))
     (`((type . "SEQ")
        (members . ,members))
      (tree-edit-seqo members tokens out))
     (`((type . "ALIAS")
        (content . ,content)
        (named . ,_)
        (value . ,_))
      (tree-edit-parseo content tokens out))
     (`((type . "REPEAT")
        (content . ,content))
      (tree-edit-repeato content tokens out))
     (`((type . "REPEAT1")
        (content . ,content))
      (tree-edit-repeat1o content tokens out))
     (`((type . "FIELD")
        (name . ,_)
        (content . ,content))
      (tree-edit-parseo content tokens out))
     (`((type . "SYMBOL")
        (name . ,name))
      (tree-edit-takeo name tokens out))
     (`((type . "CHOICE")
        (members . ,members))
      (tree-edit-choiceo members tokens out))
     (_ (error "Bad data: %s" grammar)))))

(reazon-defrel tree-edit-max-lengtho (ls len)
  "LS contains at most LEN elements."
  (cond
   ((> len 0)
    (reazon-disj
     (reazon-nullo ls)
     (reazon-fresh (d)
       (reazon-cdro ls d)
       (tree-edit-max-lengtho d (1- len)))))
   (t (reazon-nullo ls))))

(reazon-defrel tree-edit-seqo (members tokens out)
  "TOKENS parse sequentially for each grammar in MEMBERS, with OUT as leftovers."
  (if members
      (reazon-fresh (next)
        (tree-edit-parseo (car members) tokens next)
        (tree-edit-seqo (cdr members) next out))
    (reazon-== tokens out)))

(reazon-defrel tree-edit-choiceo (members tokens out)
  "TOKENS parse for each grammar in MEMBERS, with OUT as leftovers."
  (if members
      (reazon-disj
       (tree-edit-parseo (car members) tokens out)
       (tree-edit-choiceo (cdr members) tokens out))
    #'reazon-!U))

(reazon-defrel tree-edit-repeato (grammar tokens out)
  "TOKENS parse for GRAMMAR an abritrary amount of times, with OUT as leftovers."
  (reazon-disj
   (reazon-== tokens out)
   (reazon-fresh (next)
     (tree-edit-parseo grammar tokens next)
     (tree-edit-repeato grammar next out))))

(reazon-defrel tree-edit-repeat1o (grammar tokens out)
  "TOKENS parse for GRAMMAR at least once, up to an abritrary amount of times, with OUT as leftovers."
  (reazon-fresh (next)
    (tree-edit-parseo grammar tokens next)
    (tree-edit-repeato grammar next out)))

(reazon-defrel tree-edit-takeo (expected tokens out)
  "TOKENS is a cons, with car as EXPECTED and cdr as OUT."
  (reazon-conso expected out tokens))

(reazon-defrel tree-edit-prefixpostfix (prefix middle postfix out)
  "OUT is equivalent to (append PREFIX MIDDLE POSTFIX)."
  (reazon-fresh (tmp)
    (reazon-appendo prefix middle tmp)
    (reazon-appendo tmp postfix out)))

(reazon-defrel tree-edit-includes-typeo (tokens supertypes)
  "One of the types in SUPERTYPE appears in TOKENS."
  (reazon-fresh (a d)
    (reazon-conso a d tokens)
    (reazon-disj
     (reazon-membero a supertypes)
     (tree-edit-includes-typeo d supertypes))))

(reazon-defrel tree-edit-superpositiono (tokens out parent-type)
  "OUT is TOKENS where each token is either itself or any supertype occurring in PARENT-TYPE."
  (cond
   ((not tokens) (reazon-== out '()))
   ((and (not (equal (car tokens) 'comment)) (symbolp (car tokens)))
    (reazon-fresh (a d)
      (reazon-conso a d out)
      (reazon-membero a (tree-edit--relevant-types (car tokens) parent-type))
      (tree-edit-superpositiono (cdr tokens) d parent-type)))
   (t
    (reazon-fresh (a d)
      (reazon-conso a d out)
      (reazon-== a (car tokens))
      (tree-edit-superpositiono (cdr tokens) d parent-type)))))

;;* Evil state definition and keybindings
(defun tree-edit--enter-tree-state ()
  "Activate tree-edit state."
  (unless tree-edit--node-overlay
    (setq tree-edit--node-overlay (make-overlay 0 0)))
  (let ((node (tsc-get-descendant-for-position-range
               (tsc-root-node tree-sitter-tree) (point) (point))))
    (setq tree-edit--current-node
          (if (tree-edit--boring-nodep node)
              (tree-edit--apply-until-interesting #'tsc-get-parent node)
            node)))
  (overlay-put tree-edit--node-overlay 'face 'region)
  (tree-edit--update-overlay))

(defun tree-edit--exit-tree-state ()
  "De-activate tree-edit state."
  (when tree-edit--node-overlay
    (overlay-put tree-edit--node-overlay 'face '())))

(defun tree-edit-teardown ()
  "De-activate tree-edit state."
  (when tree-edit--node-overlay
    (delete-overlay tree-edit--node-overlay)))

(evil-define-state tree
  "Tree-edit state"
  :tag " <T>"
  :entry-hook (tree-edit--enter-tree-state)
  :exit-hook (tree-edit--exit-tree-state)
  :suppress-keymap t)

(define-minor-mode tree-edit-mode
  "Structural editing for any* language."
  :init-value nil
  :keymap tree-edit-mode-map
  :lighter " TE "
  (cond
   (tree-edit-mode
    (tree-sitter-mode)
    (add-hook 'before-revert-hook #'tree-edit-teardown nil 'local))
   (t
    (remove-hook 'before-revert-hook #'tree-edit-teardown 'local))))

(defun define-tree-edit-verb (key func &optional wrap)
  "Define a key command prefixed by KEY, calling FUNC.

FUNC must take two arguments, a symbol of the node type.
If WRAP is t, include :wrap-override."
  (dolist (node tree-edit-nodes)
    (define-key
      evil-tree-state-map
      (string-join (list key (plist-get node :key)))
      (cons
       ;; emacs-which-key integration
       (or (plist-get node :name) (s-replace "_" " " (symbol-name (plist-get node :type))))
       `(lambda ()
          (interactive)
          (let ((tree-edit-semantic-snippets
                 (append ,(plist-get node :node-override)
                         ,(if wrap (plist-get node :wrap-override))
                         tree-edit-semantic-snippets)))
            (,func ',(plist-get node :type)))))))
  ;; FIXME
  (define-key
    evil-tree-state-map
    (string-join (list key "p"))
    (cons
     "kill-ring"
     `(lambda ()
        (interactive)
        (,func (car kill-ring))))))

(evil-define-key 'normal tree-edit-mode-map "Q" #'evil-tree-state)

(defun tree-edit--make-suppressed-keymap ()
  "Create a sparse keymap where keys default to undefined."
  (make-composed-keymap (make-sparse-keymap) evil-suppress-map))

(defun tree-edit--set-state-bindings ()
  "Set keybindings for `evil-tree-state'.

Should only be used in the context of mode-local bindings, as
each language will have it's own set of nouns."
  (define-tree-edit-verb "i" #'tree-edit-insert-sibling-before)
  (define-tree-edit-verb "a" #'tree-edit-insert-sibling)
  (define-tree-edit-verb "I" #'tree-edit-insert-child)
  (define-tree-edit-verb "s" #'tree-edit-avy-jump)
  (define-tree-edit-verb "e" #'tree-edit-exchange-node)
  (define-tree-edit-verb "w" #'tree-edit-wrap-node t)
  (define-key evil-tree-state-map [escape] 'evil-normal-state)
  (define-key evil-tree-state-map ">" #'tree-edit-slurp)
  (define-key evil-tree-state-map "<" #'tree-edit-barf)
  (define-key evil-tree-state-map "j" #'tree-edit-up)
  (define-key evil-tree-state-map "k" #'tree-edit-down)
  (define-key evil-tree-state-map "h" #'tree-edit-left)
  (define-key evil-tree-state-map "f" #'tree-edit-right)
  (define-key evil-tree-state-map "c" #'tree-edit-change-node)
  (define-key evil-tree-state-map "d" #'tree-edit-delete-node)
  (define-key evil-tree-state-map "r" #'tree-edit-raise)
  (define-key evil-tree-state-map "y" #'tree-edit-copy)
  (define-key evil-tree-state-map "A" #'tree-edit-sig-up))

(provide 'tree-edit)
;;; tree-edit.el ends here
