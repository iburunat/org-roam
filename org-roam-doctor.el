;;; org-roam-doctor.el --- Rudimentary Roam replica with Org-mode -*- coding: utf-8; lexical-binding: t; -*-
;;
;; Copyright © 2020 Jethro Kuan <jethrokuan95@gmail.com>

;; Author: Jethro Kuan <jethrokuan95@gmail.com>
;; URL: https://github.com/jethrokuan/org-roam
;; Keywords: org-mode, roam, convenience
;; Version: 1.1.0
;; Package-Requires: ((emacs "26.1") (dash "2.13") (f "0.17.2") (s "1.12.0") (org "9.3") (emacsql "3.0.0") (emacsql-sqlite "1.0.0"))

;; This file is NOT part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 3, or (at your option)
;; any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs; see the file COPYING.  If not, write to the
;; Free Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
;; Boston, MA 02110-1301, USA.


;;; Commentary:
;;
;; This library provides `org-roam-doctor', a utility for diagnosing and fixing
;; Org-roam files. Running `org-roam-doctor' launches a list of checks defined
;; by `org-roam-doctor--checkers'. Every checker is an instance of
;; `org-roam-doctor-checker'.
;;
;; Each checker is given the Org parse tree (AST), and is expected to return a
;; list of errors. The checker can also provide "actions" for auto-fixing errors
;; (see `org-roam-doctor--remove-link' for an example).
;;
;; The UX experience is inspired by both org-lint and checkdoc, and their code
;; is heavily referenced.
;;
;;; Code:
;; Library Requires
(require 'cl-lib)
(require 'org)
(require 'org-element)

(declare-function org-roam-insert "org-roam")
(declare-function org-roam--get-roam-buffers "org-roam")
(declare-function org-roam--list-all-files "org-roam")
(declare-function org-roam--org-roam-file-p "org-roam")

(cl-defstruct (org-roam-doctor-checker (:copier nil))
  (name 'missing-checker-name)
  (description "")
  (actions nil))

(defconst org-roam-doctor--checkers
  (list
   (make-org-roam-doctor-checker
    :name 'org-roam-doctor-broken-links
    :description "Fix broken links."
    :actions '(("d" . ("Unlink" . org-roam-doctor--remove-link))
               ("r" . ("Replace link" . org-roam-doctor--replace-link))
               ("R" . ("Replace link (keep label)" . org-roam-doctor--replace-link-keep-label))))))

(defun org-roam-doctor-broken-links (ast)
  "Checker for detecting broken links.
AST is the org-element parse tree."
  (org-element-map ast 'link
    (lambda (l)
      (when (equal "file" (org-element-property :type l))
        (let ((file (org-element-property :path l)))
          (and (not (file-remote-p file))
               (not (file-exists-p file))
               (list (org-element-property :begin l)
                     (format (if (org-element-lineage l '(link))
                                 "Link to non-existent image file \"%s\"\
 in link description"
                               "Link to non-existent local file \"%s\"")
                             file))))))))

(defun org-roam-doctor--check (buffer checkers)
  "Check BUFFER for errors.
CHECKERS is the list of checkers used."
  (with-current-buffer buffer
    (save-excursion
      (goto-char (point-min))
      (let* ((ast (org-element-parse-buffer))
             (errors (sort (cl-mapcan
                            (lambda (c)
                              (mapcar
                               (lambda (report)
                                 (list (set-marker (make-marker) (car report))
                                       (nth 1 report) c))
                               (save-excursion
                                 (funcall
                                  (org-roam-doctor-checker-name c)
                                  ast))))
                            checkers)
                           #'car-less-than-car)))
        (dolist (e errors)
          (pcase-let ((`(,m ,msg ,checker) e))
            (switch-to-buffer buffer)
            (goto-char m)
            (org-reveal)
            (org-roam-doctor--resolve msg checker)
            (set-marker m nil)))
        errors))))

;;; Actions
(defun org-roam-doctor--recursive-edit ()
  "Launch into a recursive edit."
  (message "When you're done editing press C-M-c to continue.")
  (recursive-edit))

(defun org-roam-doctor--replace-link ()
  "Replace the current link with a new link."
  (unless (org-in-regexp org-link-bracket-re 1)
    (user-error "No link at point"))
  (save-excursion
    (delete-region (match-beginning 0) (match-end 0))
    (org-roam-insert)))

(defun org-roam-doctor--replace-link-keep-label ()
  "Replace the current link with a new link, keeping the current link's label."
  (unless (org-in-regexp org-link-bracket-re 1)
    (user-error "No link at point"))
  (save-excursion
    (let ((label (if (match-end 2)
                     (match-string-no-properties 2)
                   (org-link-unescape (match-string-no-properties 1)))))
      (delete-region (match-beginning 0) (match-end 0))
      (org-roam-insert nil nil label))))

(defun org-roam-doctor--remove-link ()
  "Unlink the text at point."
  (unless (org-in-regexp org-link-bracket-re 1)
    (user-error "No link at point"))
  (save-excursion
    (let ((label (if (match-end 2)
                     (match-string-no-properties 2)
                   (org-link-unescape (match-string-no-properties 1)))))
      (delete-region (match-beginning 0) (match-end 0))
      (insert label))))

(defun org-roam-doctor--resolve (msg checker)
  "Resolve an error.
MSG is the error that was found, which is displayed in a help buffer.
CHECKER is a org-roam-doctor checker instance."
  (let ((actions (org-roam-doctor-checker-actions checker))
        ((help-buf-name "*Org-roam-doctor Help*"))
        c)
    (push '("e" . ("Edit" . recursive-edit)) actions)
    (with-output-to-temp-buffer help-buf-name
      (mapc #'princ
            (list "Error message:\n   " msg "\n\n"))
      (dolist (action actions)
        (princ (format "[%s]: %s\n"
                       (car action)
                       (cadr action)))))
    (shrink-window-if-larger-than-buffer
     (get-buffer-window help-buf-name))
    (message "Press key for command:")
    (cl-loop
     do (setq c (char-to-string (read-char-exclusive)))
     until (assoc c actions)
     do (message "Please enter a valid key for command:"))
    (unwind-protect
        (funcall (cddr (assoc c actions)))
      (when (get-buffer-window help-buf-name)
        (delete-window (get-buffer-window help-buf-name))
        (kill-buffer help-buf-name)))))

(defun org-roam-doctor (&optional this-buffer)
  "Perform a check on Org-roam files to ensure cleanliness.
If THIS-BUFFER, run the check only for the current buffer."
  (interactive "P")
  (let ((existing-buffers (org-roam--get-roam-buffers))
        files)
    (if (not this-buffer)
        (setq files (org-roam--list-all-files))
      (unless (org-roam--org-roam-file-p)
        (user-error "Not in an org-roam file"))
      (setq files (list (buffer-file-name))))
    (dolist (f files)
      (let ((buf (find-file-noselect f)))
        (with-current-buffer buf
          (org-roam-doctor--check buf org-roam-doctor--checkers))
        (unless (memq buf existing-buffers)
          (save-buffer buf)
          (kill-buffer buf)))))
  (message "Linting completed."))

(provide 'org-roam-doctor)

;;; org-roam-doctor.el ends here
