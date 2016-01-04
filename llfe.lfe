#!/usr/bin/env lfe
;; -*- lfe -*-

(include-lib "kernel/include/file.hrl")

(include-lib "clj/include/compose.lfe")

(defun usage ()
  (io:fwrite "LLFE: Literate Lisp Flavoured Erlang\n")
  (io:fwrite "\n")
  (io:fwrite "Usage: llfe [file]...\n")
  (io:fwrite "       llfe watch [file]...\n")
  (io:fwrite "\n")
  (io:fwrite "Syntax: Literate LFE files are written in Markdown.\n")
  (io:fwrite "        For information about the syntax, please refer to:\n")
  (io:fwrite "        https://github.com/quasiquoting/llfe.\n")
  (io:fwrite "\n")
  (io:fwrite "'llfe watch' takes a list of files. When a change is detected\n")
  (io:fwrite "on any of the files, llfe will automatically re-tangle them.\n")
  (io:fwrite "\n")
  (io:fwrite "There are some debugging functions pertaining to the way the\n")
  (io:fwrite "parser handles documents. Their usage is as follows:\n")
  (io:fwrite "\n")
  (io:fwrite "    llfe print-code [file]\n")
  (io:fwrite "    llfe print-unindented-code [file]\n")
  (io:fwrite "    llfe print-concatenated-code [file]\n")
  (io:fwrite "    llfe print-expanded-code [file]\n")
  (io:fwrite "    llfe print-unescaped-code [file]\n")
  (io:fwrite "    llfe print-file-sections [file]\n")
  (io:fwrite "\n")
  (io:fwrite "For more information, it's probably best to read the literate\n")
  (io:fwrite "source of LLFE itself.\n")
  'ok)


;;;===================================================================
;;; Printing
;;;===================================================================

(defun print-code (filename)
  (print-sections (all-code (read-file filename))))

(defun print-unindented-code (filename)
  (print-sections (all-code (read-file filename))))

(defun print-concatenated-code (filename)
  (print-sections (concat-sections (all-code (read-file filename)))))

(defun print-expanded-code (filename)
  (-> (all-code (read-file filename))
      (concat-sections)
      (expand-all-sections)
      (print-sections)))

(defun print-unescaped-code (filename)
  (-> (all-code (read-file filename))
      (concat-sections)
      (expand-all-sections)
      (unescape-sections)
      (file-sections)
      (print-sections)))

(defun print-file-sections (filename)
  (-> (read-file filename)
      (all-code)
      (concat-sections)
      (expand-all-sections)
      (unescape-sections)
      (file-sections)
      (print-sections)))

(defun print-sections (sections)
  (lists:foreach
   (lambda (name-code)
     (io:fwrite "~s~n-----~n~s~n-----~n~n" (tuple_to_list name-code)))
   sections))


;;;===================================================================
;;; Code blocks
;;;===================================================================

(defun collect-to-eol (input)
  (case (lists:splitwith #'not-newline?/1 input)
    (`#(,line [10 . ,rest]) `#(,line ,rest))
    (`#(,line ,rest)        `#(,line ,rest))))

(defun collect-to-fence (input) (collect-to-fence input ""))

(defun collect-to-fence
  ([""                        acc] `#(,(lists:reverse acc) ""))
  ;; 10 = \n
  ([`(10 #\` #\` #\` . ,rest) acc] `#(,(lists:reverse acc) ,rest))
  ([`(,c . ,rest)             acc] (collect-to-fence rest (cons c acc))))

(defun all-code (input) (all-code input ""))

(defun all-code
  ([""                 acc] (lists:reverse acc))
  ([`(10 #\` #\` #\` . ,rest) acc]
   (let* ((`#(,attr ,rest1)  (collect-to-eol rest))
          (`#(match [,name]) (match-name attr))
          (`#(,code ,rest2)  (collect-to-fence rest1)))
     (all-code rest2 `[#(,name ,code) . ,acc])))
  ([`(,_ . ,rest)             acc] (all-code rest acc)))


;;;===================================================================
;;; noweb-style replacement
;;;===================================================================

(defun collect-to-replacement-open (line)
  (collect-to-replacement-open line []))

(defun collect-to-replacement-open
  (["" acc]
   `#(,(lists:reverse acc) ""))
  ([`(#\\ #\< #\< . ,rest) acc]
   (collect-to-replacement-open rest (++ "<<\\" acc)))
  ([`(#\< #\< . ,rest) acc]
   `#(,(lists:reverse acc) ,rest))
  ([`(,c . ,rest) acc]
   (collect-to-replacement-open rest (cons c acc))))

(defun collect-to-replacement-close (input)
  (collect-to-replacement-close input []))

(defun collect-to-replacement-close
  ([""                 acc] `#(,(lists:reverse acc) ""))
  ([`(#\> #\> . ,rest) acc] `#(,(lists:reverse acc) ,rest))
  ([`(,c . ,rest)      acc] (collect-to-replacement-close rest (cons c acc))))


;;;===================================================================
;;; Sections
;;;===================================================================

(defun concat-sections (sections)
  (flet ((join-section (key)
                       `#(,key ,(unlines (proplists:get_all_values key sections)))))
    (lists:map #'join-section/1 (proplists:get_keys sections))))

(defun split-section (line)
  (case (collect-to-replacement-open line)
    (`#(,_ "") 'nil)
    (`#(,prefix ,rest)
     (let ((`#(,padded-name ,suffix) (collect-to-replacement-close rest)))
       `#(,(string:strip padded-name) ,prefix ,suffix)))))

(defun expand-sections (code sections) (expand-sections code sections []))

(defun expand-sections
  ([""   _sections acc] (unlines (lists:reverse acc)))
  ([code sections  acc]
   (let ((`#(,line ,rest) (collect-to-eol code)))
     (case (split-section line)
       ('nil (expand-sections rest sections (cons line acc)))
       (`#(,name ,prefix ,suffix)
        (case (proplists:get_value name sections)
          ('undefined
           (io:fwrite "Warning: code section named ~p not found.~n" `[,name])
           (expand-sections rest sections (cons (++ prefix suffix) acc)))
          (code-to-insert
           (-> (lists:map (lambda (x) (++ prefix x suffix)) (lines code-to-insert))
               (unlines)
               (cons acc)
               (->> (expand-sections rest sections))))))))))

(defun expand-all-sections (sections)
  (lists:map
    (match-lambda
      ([`#(,name ,code)]
       `#(,name ,(expand-sections code sections))))
    sections))


;;;===================================================================
;;; Inspecting files
;;;===================================================================

(defun changed-files (a b)
  (lists:filter
    (lambda (x) (=/= (proplists:get_value x a) (proplists:get_value x b)))
    (proplists:get_keys a)))

(defun existing-files (files) (lists:filter #'filelib:is_file/1 files))

(defun modified-times (files)
  (lists:map (lambda (file) `#(,file ,(modified-time file))) files))

(defun modified-time (filename)
  "Given a filename, return the last time the file was written."
  (let ((`#(ok ,info) (file:read_file_info filename)))
    (file_info-mtime info)))


;;;===================================================================
;;; Reading files
;;;===================================================================

(defun read-file (filename)
  (case (file:read_file filename)
    (`#(ok ,binary) (binary_to_list binary))
    (`#(error ,reason)
     (io:fwrite "Failed to read file (~s): ~s~n" `[,filename ,reason])
     (error `#(read_file ,filename ,reason)))))

(defun file-sections (sections)
  (lists:filtermap
    (match-lambda
      ([`#(,(= `(#\f #\i #\l #\e #\: . ,_) name) ,code)]
       `#(true #(,name ,code)))
      ([_] 'false))
    sections))


;;;===================================================================
;;; Processing files
;;;===================================================================

(defun process-files (files)
  (lists:reverse (lists:flatmap #'process-file/1 files)))

(defun process-file (filename)
  (let* ((base-dir          (filename:dirname filename))
         (concatenated-code (concat-sections (all-code (read-file filename))))
         (expanded-code     (-> concatenated-code
                                (expand-all-sections)
                                (expand-all-sections)
                                (expand-all-sections)
                                (expand-all-sections)))
         (files (file-sections (unescape-sections expanded-code))))
    (write-file-sections base-dir files)))


;;;===================================================================
;;; Writing files
;;;===================================================================

(defun write-file (base-dir filename contents)
  (let ((filename* (file-name base-dir filename)))
    (case (file:write_file filename* (++ contents "\n"))
      ('ok filename*)
      (`#(error ,reason)
       (io:fwrite (++ "Error: Failed to write file (~s): ~s. "
                      "(LLFE doesn't create directories, so you may need to "
                      "create one.)~n")
                  `[,filename* ,reason])))))

;; TODO: handle padline option
(defun write-file-sections (base-dir files)
  (-> (match-lambda
        ([`#((#\f #\i #\l #\e #\: . ,filename) ,contents)]
         (write-file base-dir filename contents)))
      (lists:map files)
      (lists:reverse)))


;;;===================================================================
;;; Watching files
;;;===================================================================

(defun watch (files f) (watch files f []))

(defun watch (files f state)
  (let* ((modified-times (modified-times (existing-files files)))
         (changed-files  (changed-files modified-times state)))
    (if (> (length changed-files) 0)
      (apply f `[,changed-files])
      'noop)
    (timer:sleep (timer:seconds 1))
    (watch files f modified-times)))


;;;===================================================================
;;; Internal functions
;;;===================================================================

(defun file-name (base-dir filename)
  "Given a `base-dir`ectory and a `filename`, return an absolute path.
The result will be formatted in a way that is accepted by the command shell and
native applications on the current platform."
  (filename:nativename (filename:absname_join base-dir filename)))

(defun not-newline?
  "Given a character, return `true` iff it iss not `\\n`."
  ([10] 'false)
  ([_]  'true))

(defun match-name (input)
  (re:run input "name=\"(?<name>[^\"]+)\"" '[#(capture [name] list)]))

(defun lines (string)
  "Break a string up into a list of strings at newline characters.
The resulting strings do not contain newlines."
  (re:split string "\n" '[#(return list)]))

(defun unlines (strings)
  "Joins lines, after appending a terminating newline to each.
[[unlines/1]] is an inverse operation to [[lines/1]]."
  (string:join strings "\n"))

(defun unescape (code)
  "Given the contents of a code block, replace any `\"\<<\"` with `\"<<\"`."
  (re:replace code "\\\\<<" "<<" '[global #(return list)]))

(defun unescape-sections (sections)
  "Given a list of sections, call [[unescape/1]] on each code block."
  (lists:map
    (match-lambda ([`#(,name ,code)] `#(,name ,(unescape code))))
    sections))


;;;===================================================================
;;; Main entry point
;;;===================================================================

(defun main
  (['()] (usage))
  ([`("watch" . ,files)]
   (watch files
          (lambda (changed-files)
            (flet ((print (x) (io:fwrite "~s~n" `[,x])))
              (io:fwrite "\n~s\n" `[,(string:centre " Processing " 30 #\-)])
              (lists:foreach #'print/1 changed-files)
              (io:fwrite "\n~s\n" `[,(string:centre " Output " 30 #\-)])
              (lists:foreach #'print/1 (process-files changed-files))))))
  ([`(,(= `(#\p #\r #\i #\n #\t #\- . ,_) print-function) ,file)]
   (let ((f (list_to_atom print-function)))
     (if (andalso (orelse (=:= "print-file-sections" print-function)
                          (lists:suffix "-code" print-function))
                  (erlang:function_exported (MODULE) f 1))
       (apply (MODULE) f `[,file])
       (usage))))
  ([args]
   (if (lists:any (lambda (x) (lists:member x '["help" "-h" "-help" "--help"])) args)
     (usage)
     (process-files args))))

(main script-args)