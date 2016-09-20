;;; aws-ec2.el --- Manage AWS EC2 instances -*- lexical-binding: t -*-

;; Copyright (C) 2016 Yuki Inoue

;; Author: Yuki Inoue <inouetakahiroki _at_ gmail.com>
;; URL: AWS, Amazon Web Service
;; Version: 0.0.1
;; Package-Requires: ((emacs "24.4") (dash "2.12.1") (dash-functional "1.2.0") (magit-popup "2.6.0") (tablist "0.70"))

;; This file is NOT part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; Manipulate AWS ec2 from emacs.

;;; Code:

(require 'json)
(require 'tabulated-list)
(require 'dash)
(require 'dash-functional)
(require 'magit-popup)


(defun aws--shell-command-to-string (&rest args)
  (let ((cmd (funcall 'combine-and-quote-strings (append (aws-bin) args))))
    (message cmd)
    (shell-command-to-string cmd)))

(defun aws-bin ()
  (if aws-current-profile
      (list "aws" "--profile" aws-current-profile)
    (list "aws")))

(defun aws-ec2-all-raw-instances ()
  (interactive)
  (json-read-from-string
   (aws--shell-command-to-string "ec2" "describe-instances")))

(defun aws-ec2-normalize-raw-instances (raw-instances)
  (->>
   raw-instances
   (assoc-default 'Reservations)
   ((lambda (v) (append v nil)))
   (mapcar (apply-partially 'assoc-default 'Instances))
   (mapcar (lambda (v) (append v nil)))
   (-mapcat 'identity)
   (mapcar 'aws-instance-fix-tag)))

(defun aws-convert-raw-instances (raw-instances)
  (->>
   (aws-ec2-normalize-raw-instances raw-instances)
   (mapcar (lambda (instance)
     (list (cdr (assoc 'InstanceId instance))
           (vector (assoc-default 'InstanceId instance)
                   (assoc-default 'InstanceType instance)
                   (or (assoc-default "Name" (assoc-default 'Tags instance)) "")
                   (assoc-default 'Name (assoc-default 'State instance))
                   (prin1-to-string (assoc-default 'PrivateIpAddress instance) t)
                   (or  "..." (prin1-to-string instance))
                   ))))
   ))

(defun aws-instance-fix-tag (instance)
  (mapcar
   (lambda (entry)
     (if (not (equal (car entry) 'Tags))
         entry
       (cons 'Tags
             (mapcar (lambda (kvassoc)
                       (cons (cdr (assoc 'Key kvassoc))
                             (cdr (assoc 'Value kvassoc))))
                     (cdr entry)))))
   instance))

(defvar aws-current-profile nil
  "The currently used aws profile")

(defun aws-set-profile (profile)
  "Configures which profile to be used."
  (interactive "sProfile: ")
  (if (string= "" profile)
      (setq profile nil))
  (setq aws-current-profile profile))

(define-derived-mode aws-instances-mode tabulated-list-mode "Containers Menu"
  "Major mode for handling a list of docker containers."

  (define-key aws-instances-mode-map "I" 'aws-instances-inspect-popup)
  (define-key aws-instances-mode-map "O" 'aws-instances-stop-popup)
  (define-key aws-instances-mode-map "T" 'aws-instances-terminate-popup)
  (define-key aws-instances-mode-map "S" 'aws-instances-start-popup)
  (define-key aws-instances-mode-map "P" 'aws-set-profile)

  (setq tabulated-list-format
        '[("Repository" 10 nil)
          ("InstType" 10 nil)
          ("Name" 30 nil)
          ("Status" 10 nil)
          ("IP" 15 nil)
          ("Settings" 20 nil)])
  (setq tabulated-list-padding 2)
  (add-hook 'tabulated-list-revert-hook 'aws-instances-refresh nil t)
  (tabulated-list-init-header)
  (tablist-minor-mode))


(defun aws-instances-refresh ()
  "Refresh elasticsearch snapshots."

  (setq tabulated-list-entries
        (aws-convert-raw-instances
         (aws-ec2-all-raw-instances))))

(defun aws-select-if-empty (&optional arg)
  "Select current row is selection is empty."
  (save-excursion
    (when (null (tablist-get-marked-items))
      (tablist-put-mark))))

(defmacro aws-define-popup (name doc &rest args)
  "Wrapper around `aws-utils-define-popup'."
  `(progn
     (magit-define-popup ,name ,doc ,@args)
     (add-function :before (symbol-function ',name) #'aws-select-if-empty)))

(aws-define-popup
 aws-instances-inspect-popup
 'aws-instances-popups
 :actions  '((?I "Inspect" aws-instances-inspect-selection)))

(aws-define-popup
 aws-instances-stop-popup
 'aws-instances-popups
 :actions  '((?O "Stop" aws-instances-stop-selection)))

(aws-define-popup
 aws-instances-terminate-popup
 'aws-instances-popups
 :actions  '((?T "Terminate" aws-instances-terminate-selection)))

(aws-define-popup
 aws-instances-start-popup
 'aws-instances-popups
 :actions  '((?S "start" aws-instances-start-selection)))


(defun aws-ec2-command-on-selection (command)
  (apply 'aws--shell-command-to-string
         "ec2" command "--instance-ids" (docker-utils-get-marked-items-ids)))

(defun aws-instances-stop-selection ()
  (interactive)
  (aws-ec2-command-on-selection "stop-instances"))

(defun aws-instances-terminate-selection ()
  (interactive)
  (aws-ec2-command-on-selection "terminate-instances"))

(defun aws-instances-start-selection ()
  (interactive)
  (aws-ec2-command-on-selection "start-instances"))

(defun aws-instances-inspect-selection ()
  (interactive)
  (let ((result (->>
                 (tablist-get-marked-items)
                 (mapcar 'car)
                 (append '("ec2" "describe-instances" "--instance-ids"))
                 (apply 'aws--shell-command-to-string)))
        (buffer (get-buffer-create "*aws result*")))

    (with-current-buffer buffer
      (erase-buffer)
      (goto-char (point-max))
      (insert result))

    (display-buffer buffer)))

;;;###autoload
(defun aws-instances ()
  "List aws instances using aws-cli. (The `aws` command)."
  (interactive)
  (pop-to-buffer "*aws-instances*")
  (tabulated-list-init-header)
  (aws-instances-mode)
  (tabulated-list-revert))

(defvar aws-global-keymap
  (let ((map (make-sparse-keymap)))
    (define-key map "c" 'aws-instances)
    map))

(provide 'aws-ec2)

;;; aws-ec2.el ends here
