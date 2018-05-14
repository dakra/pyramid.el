;;; pyramid.el --- Minor mode for working with pyramid projects  -*- lexical-binding: t -*-

;; Copyright (c) 2018 Daniel Kraus <daniel@kraus.my>

;; Author: Daniel Kraus <daniel@kraus.my>
;; URL: https://github.com/dakra/pyramid.el
;; Keywords: python, pyramid, pylons, convenience, tools, processes
;; Version: 0.1
;; Package-Requires: ((emacs "25.2") (pythonic "0.1.0"))

;; This file is NOT part of GNU Emacs.

;;; License:

;; This program is free software; you can redistribute it and/or modify
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
;;
;; `pyramid.el' provides utilities for working with the python
;; web framework pyramid.
;;
;; It has wrapper functions around the pyramid builtin p* scripts
;; like `pserve', `pviews', `ptweens' etc.
;; It lets you easily navigate to your
;; view definitions, templates or sqlalchemy models.
;; Customize the 'pyramid' group to see the settings and
;; read the README for more info.

;;; Code:

(require 'ansi-color)
(require 'compile)
(require 'easymenu)
(require 'json)
(require 'python)
(require 'pythonic)
(require 'subr-x)
(require 'tablist)


;;; Customization

(defgroup pyramid nil
  "Pyramid framework integration"
  :prefix "pyramid-"
  :group 'compilation)

(defcustom pyramid-keymap-prefix (kbd "C-c '")
  "Pyramid keymap prefix."
  :type 'key-sequence)

(defcustom pyramid-settings "development.ini"
  "Pyramid settings file."
  :type 'string
  :safe #'stringp)

(defcustom pyramid-project-root nil
  "Root of the pyramid project.
When NIL it uses the path that contains the `pyramid-settings' file."
  :type 'directory
  :safe #'directory-name-p)

(defcustom pyramid-package-name nil
  "Package name of the pyramid project.
When NIL use the package specified in the `pyramid-settings' file."
  :type 'string
  :safe #'stringp)

(defcustom pyramid-serve-reload t
  "If non-nil, use `--reload' option by default when running `pyramid-serve'."
  :type 'boolean
  :safe #'booleanp)

(defcustom pyramid-cookiecutters (list "gh:Pylons/pyramid-cookiecutter-alchemy"
                                       "gh:Pylons/pyramid-cookiecutter-starter"
                                       "gh:Pylons/pyramid-cookiecutter-zodb")
  "List of pyramid cookiecutter templates."
  :type '(repeat string))

(defcustom pyramid-snippet-dir (expand-file-name
                                (concat (file-name-directory (or load-file-name default-directory))
                                        "./snippets/"))
  "Directory in which to locate Yasnippets for pyramid."
  :type 'directory)


;;; Variables

(defvar pyramid-request-methods
  (list "GET" "POST" "PUT" "PATCH" "DELETE" "OPTIONS" "HEAD" "PROPFIND")
  "List of allowed http methods for the prequest script.")

(defvar pyramid-get-views-code "
from __future__ import print_function
import os, sys
stdout = sys.stdout
sys.stdout = open(os.devnull, 'w')
sys.stderr = open(os.devnull, 'w')
from importlib import import_module
from inspect import findsource, getsourcefile
from json import dumps
from os.path import realpath
from pyramid.config import Configurator
from pyramid.paster import bootstrap
from pyramid.scripts.proutes import get_route_data

env = bootstrap('%s')
registry = env['registry']
config = Configurator(registry)
mapper = config.get_routes_mapper()
routes = mapper.get_routes(include_static=False)
mapped_routes = {}
for route in routes:
    route_data = get_route_data(route, registry)
    for name, pattern, view, method in route_data:
        try:
            base, _, attr = view.rpartition('.')
            if not base:
                continue
            module = import_module(base)
        except ModuleNotFoundError:
            print('not found', view)
            continue
        mapped_routes[view] = {
            'name': name,
            'pattern': pattern,
            'view': view,
            'method': method,
            'sourcefile': realpath(getsourcefile(getattr(module, attr, module))),
            'lineno': findsource(getattr(module, attr, module))[1],
        }
print(dumps(mapped_routes), end='', file=stdout)
" "Python source code to get views.")

(defvar pyramid-get-package-name-code "
from __future__ import print_function
import os, sys
stdout = sys.stdout
sys.stdout = open(os.devnull, 'w')
sys.stderr = open(os.devnull, 'w')
from pyramid.paster import bootstrap
env = bootstrap('%s')
print(env['registry'].package_name, end='', file=stdout)
" "Python source code to get package name.")

(defvar pyramid-get-sqlalchemy-models-code "
from __future__ import print_function
import os, sys
stdout = sys.stdout
sys.stdout = open(os.devnull, 'w')
sys.stderr = open(os.devnull, 'w')
from importlib import import_module
from inspect import findsource, getsourcefile
from json import dumps
from os.path import realpath
try:
    from %1$s.models.meta import Base
except ImportError:
    try:
        from %1$s.models import Base
    except ImportError:
        from %1$s import Base

models = {}
for name, model in Base._decl_class_registry.items():
    if not hasattr(model, '__table__'):
        continue
    models[name] = {
        'name': name,
            'sourcefile': realpath(getsourcefile(model)),
            'lineno': findsource(model)[1],
    }
print(dumps(models), end='', file=stdout)
" "Python source code to get sqlalchemy models.")

(defvar pyramid-get-console-scripts-code "
from __future__ import print_function
import os, sys
stdout = sys.stdout
sys.stdout = open(os.devnull, 'w')
sys.stderr = open(os.devnull, 'w')
from pkg_resources import get_entry_map
from inspect import findsource, getsourcefile
from json import dumps
from os.path import realpath

scripts = {}
for name, entry in get_entry_map('%s', 'console_scripts').items():
    func = entry.load()
    scripts[name] = {
        'name': entry.name,
        'sourcefile': realpath(getsourcefile(func)),
        'lineno': findsource(func)[1],
    }
print(dumps(scripts), end='', file=stdout)
" "Python source code to get console scripts.")

(defvar pyramid-run-console-script-code "
from __future__ import print_function
import re
import sys
from pkg_resources import load_entry_point
sys.argv[0] = re.sub(r'(-script\.pyw?|\.exe)?$', '', sys.argv[0])
sys.argv.append('%s')
load_entry_point('%s', 'console_scripts', '%s')()
" "Python source code to run a console script.")

(defvar pyramid-console-scripts-history nil)
(defvar pyramid-views-history nil)
(defvar pyramid-sqlalchemy-models-history nil)


;;; Private helper functions

(defun pyramid-call (code &rest args)
  "Execute python CODE with ARGS.  Show errors if occurs."
  (let* ((exit-code nil)
         (output (with-output-to-string
                   (with-current-buffer standard-output
                     (hack-dir-local-variables-non-file-buffer)
                     (setq exit-code
                           (call-pythonic
                            :buffer standard-output
                            :args (append (list "-c" code) args)
                            :cwd (pyramid-project-root)))))))
    (when (not (zerop exit-code))
      (pyramid-show-error output (format "Python exit with status code %d" exit-code)))
    output))

(defun pyramid-read (str)
  "Read JSON from Python process output STR.
STR should be a dict where the dict key is a string
that's presented to the user."
  (condition-case err
      (let ((result (json-read-from-string str)))
        (unless (json-alist-p result)
          (signal 'json-error nil))
        result)
    ((json-error wrong-type-argument)
     (pyramid-show-error str (error-message-string err)))))

(defun pyramid-show-error (output error-message)
  "Prepare and show OUTPUT in the ERROR-MESSAGE buffer."
  (let* ((buffer (get-buffer-create "*Pyramid*"))
         (process (get-buffer-process buffer)))
    (when (and process (process-live-p process))
      (setq buffer (generate-new-buffer "*Pyramid*")))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer))
      (fundamental-mode)
      (insert output)
      (goto-char (point-min))
      (compilation-minor-mode 1)
      (pop-to-buffer buffer)
      (error error-message))))

(defun pyramid-find-file-and-line (func key collection)
  "Get KEY from COLLECTION and open it's definition.
COLLECTION an alist of alists where KEY is the string
describing the object (e.g. view-/template-/model-name)
and the inner alist has at least `sourcefile' and
`lineno' as entries which is the location we jump to.
It's created by reading a json string with `pyramid-read'.
FUNC is a function to open the file."
  (let* ((code (cdr (assoc key collection)))
         (value (cdr (assoc 'sourcefile code)))
         (lineno (cdr (assoc 'lineno code))))
    (when (pythonic-remote-p)
      (setq value (concat (pythonic-tramp-connection) value)))
    (funcall func value nil)
    (goto-char (point-min))
    (forward-line lineno)
    (recenter)))

(defun pyramid-prompt-find-file-and-line (func prompt collection hist)
  "Ask user to select some name and open its definition at the line number.

FUNC is function to open file.  PROMPT and COLLECTION stands for
user input.  HIST is a variable to store history of choices."
  (pyramid-find-file-and-line
   func
   (intern (completing-read prompt (mapcar 'symbol-name (mapcar 'car collection)) nil t nil hist))
   collection))


;;; Public functions

(defun pyramid-project-root ()
  "Calculate project root."
  (or pyramid-project-root
      (locate-dominating-file default-directory pyramid-settings)))

(defun pyramid-get-package-name ()
  "Execute and parse python code to get the package name."
  (or pyramid-package-name
      (pyramid-call (format pyramid-get-package-name-code pyramid-settings))))

(defun pyramid-get-views ()
  "Execute and parse python code to get view definitions."
  (pyramid-read (pyramid-call (format pyramid-get-views-code pyramid-settings))))

;;;###autoload
(defun pyramid-find-view ()
  "Jump to definition of a view that's selected from the prompt."
  (interactive)
  (pyramid-prompt-find-file-and-line #'find-file "View: " (pyramid-get-views) 'pyramid-views-history))

(defun pyramid-get-sqlalchemy-models ()
  "Execute and parse python code to get sqlalchemy-model definitions."
  (pyramid-read (pyramid-call
                 (format pyramid-get-sqlalchemy-models-code (pyramid-get-package-name)))))

;;;###autoload
(defun pyramid-find-sqlalchemy-model ()
  "Jump to definition of a sqlalchemy-model that's selected from the prompt."
  (interactive)
  (pyramid-prompt-find-file-and-line
   #'find-file "Model: " (pyramid-get-sqlalchemy-models) 'pyramid-sqlalchemy-models-history))

(defun pyramid-get-templates ()
  "Return all template files in project."
  (let ((proj-root (pyramid-project-root)))
    (mapcar (lambda (f) (file-relative-name f proj-root))
            (directory-files-recursively proj-root "\\.\\(mako?\\|jinja2?\\|pt\\)\\'"))))

;;;###autoload
(defun pyramid-find-template (file)
  "Open template FILE."
  (interactive (list (completing-read "Template: " (pyramid-get-templates))))
  (find-file (expand-file-name file (pyramid-project-root))))

(defun pyramid-get-console-scripts ()
  "Execute and parse python code to get console-script definitions."
  (pyramid-read (pyramid-call (format pyramid-get-console-scripts-code (pyramid-get-package-name)))))

;;;###autoload
(defun pyramid-find-console-script ()
  "Jump to definition of a console-script that's selected from the prompt."
  (interactive)
  (pyramid-prompt-find-file-and-line
   #'find-file "View: " (pyramid-get-console-scripts) 'pyramid-console-scripts-history))

;;;###autoload
(defun pyramid-run-console-script (script)
  "Run a console SCRIPT that's selected from the prompt.
The script will be passed the `pyramid-settings' filename as first argument."
  (interactive
   (list
    (completing-read "Script to run: "
                     (mapcar 'car (pyramid-get-console-scripts))
                     nil t nil 'pyramid-console-scripts-history)))
  (let* ((buffer (get-buffer-create "*Pyramid*"))
         (process (get-buffer-process buffer)))
    (when (and process (process-live-p process))
      (setq buffer (generate-new-buffer "*Pyramid*")))
    (with-current-buffer buffer
      (hack-dir-local-variables-non-file-buffer)
      (start-pythonic :process "pyramid"
                      :buffer buffer
                      :args (list "-c"
                                  (format pyramid-run-console-script-code
                                          pyramid-settings
                                          (pyramid-get-package-name)
                                          script))
                      :cwd (pyramid-project-root)
                      :filter (lambda (process string)
                                (comint-output-filter process (ansi-color-apply string))))
      (let ((inhibit-read-only t))
        (erase-buffer))
      (comint-mode)
      (setq-local comint-prompt-read-only t)
      (pop-to-buffer buffer))))

;;;###autoload
(defun pyramid-find-settings ()
  "Open the settings file."
  (interactive)
  (find-file (expand-file-name pyramid-settings (pyramid-project-root))))

;;;###autoload
(defun pyramid-cookiecutter (dir template)
  "Run cookiecutter on TEMPLATE from DIR."
  (interactive (list (read-directory-name "Directory to run cookiecutter in: ")
                     (completing-read "Cookiecutter: " pyramid-cookiecutters)))
  (let ((default-directory dir))
    (pop-to-buffer-same-window
     (make-comint "Pyramid cookiecutter" (executable-find "cookiecutter") nil template))))


;;; pyramid-script-mode

(defun pyramid-ansi-color-filter ()
  "Handle ansi color escape sequences."
  (ansi-color-apply-on-region compilation-filter-start (point)))

;; `python.el' variables introduced in Emacs 25.1
(defvar python-shell--interpreter)
(defvar python-shell--interpreter-args)

(defun pyramid-track-pdb-prompt ()
  "Change compilation to `python-inferior-mode' when a pdb prompt is detected.

This function is a hack that enables `inferior-python-mode' when
a pdb prompt is detected in `compilation-mode' buffers, and to
work is meant to be added to `compilation-filter-hook'.  To go
back to `compilation-mode' you need to call
\\[pyramid-back-to-compilation]."
  (let ((output (ignore-errors (buffer-substring-no-properties compilation-filter-start (point)))))
    (when (and output (string-match-p (concat "^" python-shell-prompt-pdb-regexp) output))
      (message "Entering pdb...")
      (setq buffer-read-only nil)
      (let ((python-shell--interpreter nil)
            (python-shell--interpreter-args nil))
        (set-process-filter (get-buffer-process (current-buffer)) 'comint-output-filter)
        (inferior-python-mode)
        (run-hook-with-args 'comint-output-filter-functions output)))))

(defun pyramid-back-to-compilation ()
  "Go back to compilation mode.

See `pyramid-track-pdb-prompt' documentation for more
information."
  (interactive)
  (let ((process (get-buffer-process (current-buffer))))
    (when process
      (message "Enabling compilation mode... ")
      (set-process-filter process 'compilation-filter)
      (compilation-mode))))

(define-compilation-mode pyramid-script-mode "Pyramid"
  "Mode for pyramid p* scripts output."
  (add-hook 'compilation-filter-hook 'pyramid-track-pdb-prompt t t)
  (add-hook 'compilation-filter-hook 'pyramid-ansi-color-filter nil t))

(define-key pyramid-script-mode-map (kbd "p") #'compilation-previous-error)
(define-key pyramid-script-mode-map (kbd "n") #'compilation-next-error)

(defun pyramid-compilation-start (command &optional no-settings &rest args)
  "Start compilation mode of COMMAND with ARGS in `pyramid-script-mode'.
When NO-SETTINGS is set, don't pass pyramid settings as argument."
  (python-shell-with-environment
    (let ((command (concat
                    command " "
                    (unless no-settings
                      (concat (expand-file-name (pyramid-project-root)) pyramid-settings))
                    " " (mapconcat 'shell-quote-argument args " "))))
      (compilation-start command
                         #'pyramid-script-mode
                         (lambda (_mode) (format "*Pyramid %s*" command))))))


;;; Functions for pyramid scripts

;;;###autoload
(defun pyramid-serve (&optional arg)
  "Run pyramid pserve script.
When `pyramid-serve-reload' is set, add '--reload' option.
If called with 1 universal argument ARG, add --reload option,
or remove it depending on `pyramid-serve-reload'.
If called with 2 prefix arguments,
select `pyramid-settings' file before running.

When ARG is 2, force to run without '--reload' option regardless of the
`pyramid-serve-reload' setting and when ARG is 3 always use reload."
  (interactive "p")
  (cond
   ((eq arg 1) (pyramid-compilation-start "pserve" nil (when pyramid-serve-reload "--reload")))
   ((eq arg 2) (pyramid-compilation-start "pserve"))
   ((eq arg 3) (pyramid-compilation-start "pserve" nil "--reload"))
   ((eq arg 4) (pyramid-compilation-start "pserve" nil (unless pyramid-serve-reload "--reload")))
   ((eq arg 16) (let* ((default-directory (pyramid-project-root))
                       (pyramid-settings (completing-read "config: " (file-expand-wildcards "*.ini"))))
                  (pyramid-compilation-start "pserve" nil "--reload")))))

;;;###autoload
(defun pyramid-tweens ()
  "Run pyramid ptweens script."
  (interactive)
  (pyramid-compilation-start "ptweens"))

;;;###autoload
(defun pyramid-distreport ()
  "Run pyramid pdistreport script."
  (interactive)
  (pyramid-compilation-start "pdistreport" t))

;;;###autoload
(defun pyramid-views (url)
  "Run pyramid pviews on URL."
  (interactive "sEnter route:")
  (pyramid-compilation-start "pviews" nil url))

;;;###autoload
(defun pyramid-request (path method)
  "Run pyramid request on PATH with METHOD."
  (interactive (list (read-string "Path: ")
                     (completing-read "Method: " pyramid-request-methods nil t)))
  (apply #'pyramid-compilation-start "prequest" t
         (list "-m" method
               (concat (expand-file-name (pyramid-project-root)) pyramid-settings)
               path)))

(defun pyramid-routes-entries ()
  "Return the route entries for `tabulated-list-entries'."
  (mapcar (lambda (e) `(,(car e)
                        ,(vector (cdr (assoc 'method e))
                                 (cdr (assoc 'name e))
                                 (cdr (assoc 'pattern e))
                                 (cdr (assoc 'view e)))))
          (pyramid-get-views)))

(defun pyramid-routes-refresh ()
  "Refresh the routes list."
  (setq tabulated-list-entries (pyramid-routes-entries)))

(defun pyramid-routes-list-goto-definition (&optional _button)
  "Goto definition of the view on the current line."
  (interactive)
  (if-let ((view (tabulated-list-get-id)))
      (pyramid-find-file-and-line #'find-file view (pyramid-get-views))
    (call-interactively 'pyramid-find-view)))

(defvar pyramid-routes-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map tabulated-list-mode-map)
    (define-key map "\r" 'pyramid-routes-list-goto-definition)
    map)
  "Keymap for `pyramid-routes-mode'.")

(define-derived-mode pyramid-routes-mode tabulated-list-mode "Pyramid routes list"
  "Major mode for handling a list of pyramid routes."
  (setq tabulated-list-format [("Method" 8 t)("Name" 25 t)("Pattern" 40 t)("View" 40 t)])
  (setq tabulated-list-padding 2)
  (setq tabulated-list-sort-key (cons "Name" nil))
  (add-hook 'tabulated-list-revert-hook 'pyramid-routes-refresh nil t)
  (tabulated-list-init-header)
  (tablist-minor-mode))

;;;###autoload
(defun pyramid-routes ()
  "List routes."
  (interactive)
  (with-current-buffer (get-buffer-create "*Pyramid routes*")
    (pyramid-routes-mode)
    (tablist-revert)
    (switch-to-buffer (current-buffer))))


;;; Yasnippets

(require 'yasnippet nil t)

;;;###autoload
(with-eval-after-load 'yasnippet
  ;; YAS doesn't provide a completion function
  ;; where the user can also provide his own value.
  ;; See: https://github.com/joaotavora/yasnippet/issues/934
  (defun pyramid-yas-completing-read (&rest args)
    (unless (or yas-moving-away-p
                yas-modified-p)
      (apply completing-read-function args)))

  (when pyramid-snippet-dir
    (yas-load-directory pyramid-snippet-dir)))


;;; pyramid-mode

(defvar pyramid-command-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C") 'pyramid-cookiecutter)
    (define-key map (kbd "D") 'pyramid-distreport)
    (define-key map (kbd "R") 'pyramid-routes)
    (define-key map (kbd "S") 'pyramid-serve)
    (define-key map (kbd "T") 'pyramid-tweens)
    (define-key map (kbd "V") 'pyramid-views)
    (define-key map (kbd "X") 'pyramid-request)
    (define-key map (kbd "!") 'pyramid-run-console-script)
    (define-key map (kbd "c") 'pyramid-find-console-script)
    (define-key map (kbd "m") 'pyramid-find-sqlalchemy-model)
    (define-key map (kbd "s") 'pyramid-find-settings)
    (define-key map (kbd "t") 'pyramid-find-template)
    (define-key map (kbd "v") 'pyramid-find-view)
    map))

(defvar pyramid-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map pyramid-keymap-prefix pyramid-command-map)
    map))

(easy-menu-define pyramid-mode-menu pyramid-mode-map
  "Menu for working with pyramid projects."
  '("Pyramid"
    ["Create new project" pyramid-cookiecutter
     :help "Create a new project from a cookiecutter template"]
    ["Distreport" pyramid-distreport
     :help "Run pyramid script `pdistreport'"]
    ["Routes" pyramid-routes
     :help "Run pyramid script `proutes'"]
    ["Serve" pyramid-serve
     :help "Run pyramid script `pserve'"]
    ["Tweens" pyramid-tweens
     :help "Run pyramid script `ptweens'"]
    ["Views" pyramid-views
     :help "Run pyramid script `pviews'"]
    ["Request" pyramid-request
     :help "Run pyramid script `prequest'"]

    ["Run console script" pyramid-run-console-script
     :help "Run a user console script"]

    ["Find console script" pyramid-find-sqlalchemy-model
     :help "Select and navigate to a user console script"]
    ["Find sqlalchemy model" pyramid-find-sqlalchemy-model
     :help "Select and navigate to a sqlalchemy model definition"]
    ["Find settings" pyramid-find-settings
     :help "Navigate to the settings file"]
    ["Find template" pyramid-find-template
     :help "Select and navigate to a template"]
    ["Find view" pyramid-find-view
     :help "Select and navigate to a view definition."]))

;;;###autoload
(define-minor-mode pyramid-mode
  "Minor mode to interact with Pyramid projects.

\\{pyramid-mode-map}"
  :lighter " Pyramid"
  :keymap pyramid-mode-map)

;;;###autoload
(define-globalized-minor-mode global-pyramid-mode pyramid-mode
  (lambda ()
    (ignore-errors
      (when (pyramid-project-root)
        (pyramid-mode))))
  :require 'pyramid)

(provide 'pyramid)
;;; pyramid.el ends here
