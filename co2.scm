#lang racket
;; co2 Copyright (C) 2016 Dave Griffiths
;;
;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU Affero General Public License as
;; published by the Free Software Foundation, either version 3 of the
;; License, or (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU Affero General Public License for more details.
;;
;; You should have received a copy of the GNU Affero General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

(require racket/cmdline)

(define reg-table
  ;; ppu registers
  '((reg-ppu-ctl              "$2000")
    (reg-ppu-mask             "$2001")
    (reg-ppu-status           "$2002")
    (reg-oam-addr             "$2003")
    (reg-oam-data             "$2004")
    (reg-ppu-scroll           "$2005")
    (reg-ppu-addr             "$2006")
    (reg-ppu-data             "$2007")
    ;;  apu registers
    (reg-apu-pulse1-control   "$4000")
    (reg-apu-pulse1-ramp      "$4001")
    (reg-apu-pulse1-ft        "$4002")
    (reg-apu-pulse1-ct        "$4003")
    (reg-apu-pulse2-control   "$4004")
    (reg-apu-pulse2-ramp      "$4005")
    (reg-apu-pulse2-ft        "$4006")
    (reg-apu-pulse2-ct        "$4007")
    (reg-apu-tri-control      "$4008")
    (reg-apu-noise            "$400c")
    (reg-apu-dcm              "$4010")
    (reg-oam-dma              "$4014")
    (reg-apu-channel          "$4015")
    ;; input
    (reg-joypad-0             "$4016")
    (reg-joypad-1             "$4017")
    ;; ppu vram addresses
    (ppu-name-table-0 ("#$20" "#$00"))
    (ppu-attr-table-0 ("#$23" "#$c0"))
    (ppu-name-table-1 ("#$24" "#$00"))
    (ppu-attr-table-1 ("#$27" "#$c0"))
    (ppu-name-table-2 ("#$28" "#$00"))
    (ppu-attr-table-2 ("#$2b" "#$c0"))
    (ppu-name-table-3 ("#$2c" "#$00"))
    (ppu-attr-table-3 ("#$2f" "#$c0"))
    (ppu-palette      ("#$3f" "#$00"))
    (ppu-bg-palette   ("#$3f" "#$00"))
    (ppu-sprite-palette ("#$3f" "#$10"))
    ))

(define (reg-table-lookup x)
  (let ((lu (assoc x reg-table)))
    (if lu (cadr lu) #f)))

;;-------------------------------------------------------------

(define label-id 99)

(define (generate-label name)
  (set! label-id (+ label-id 1))
  (string-append name "" (number->string label-id)))

;; internal compiler reg
(define working-reg "$f0")

;; variables are just an address lookup table
(define variables '())

(define (make-variable! name)
  (when (not (memq name variables))
        (set! variables (append variables (list name)))))

(define (byte->string byte)
  (string-upcase (string-append
                  (number->string (quotient byte 16) 16)
                  (number->string (remainder byte 16) 16))))

;; constant lookup
(define constants '())

(define (make-constant! name value)
  (set! constants (cons (list name value) constants)))

(define (get-constant name)
  (let ((t (assoc name constants)))
    (if t (cadr t) #f)))

(define (lookup name)
  (define (_ l c)
    (cond
     ((null? l) (display "cant find variable ")(display name)(newline) #f)
     ((equal? name (car l)) (string-append "$" (byte->string c)))
     (else (_ (cdr l) (+ c 1)))))
  ;; check registers first
  (let ((reg (reg-table-lookup name)))
    (if reg reg
        ;; then constants
        (let ((const (get-constant name)))
          ;; finally the variable table
          (if const const (_ variables 0))))))

(define (immediate-value x)
  (if (number? x)
      (string-append "#" (number->string x))
      (let ((lu (lookup x)))
        (if lu lu (symbol->string x)))))

;---------------------------------------------------------------


;; is this an immediate value
(define (immediate? x)
  (or (number? x) (symbol? x)))

;; is this a primitive call?
(define (primcall? x)
  (and (list? x) (not (null? x)) (symbol? (car x))))

;--------------------------------------------------------------
;; code generation
;;
;; general rules:
;; * don't use registers across emit-expr as they can be clobbered
;; * use the stack (pha/pla) to store data in this case
;; * currently using internal "working-reg" as a 4th register on zero page
;;   for arithmetic stuff
;; * don't use shorthand branch labels ("-") across emit-expr either
;; * use (generate-label) in this case to use a unique one
;; * working register and returns all stored in a
;; * x/y are used for local optimisation

(define (emit . args)
  (list
   (foldl
    (lambda (arg r)
      (if (equal? r "")
          (string-append r arg)
          (string-append r " " arg)))
    ""
    args)))

;; append a bunch of expressions
(define (emit-expr-list l)
  (cond
    ((null? l) '())
    (else
     (append
      (emit-expr (car l))
      (emit-expr-list (cdr l))))))


(define (emit-asm x)
  (let ((r
         (foldl
          (lambda (str r)
            (if (equal? r "")
                str
                (string-append r "\n" str)))
          ""
          (cdr x))))
    (list r)))

(define (emit-label label)
  (emit (string-append label ":")))

(define (emit-load-variable x)
  (emit "lda" (immediate-value x)))

(define (emit-load-immediate x)
  (cond
    ((number? x) (emit "lda" (string-append "#" (number->string x))))
    ((symbol? x) (emit-load-variable x))))

(define (emit-defvar x)
  (make-variable! (cadr x))
  (append
   (emit-expr (caddr x))
   (emit "sta" (immediate-value (cadr x)))))

(define (emit-defun x)
  (append
   (emit (string-append (symbol->string (car (cadr x))) ":"))
   (emit-expr-list (cddr x))
   (emit "rts")))

(define (emit-defint x)
  (append
   (emit (string-append (symbol->string (car (cadr x))) ":"))
   (emit-expr-list (cddr x))
   (emit "rti")))

(define (emit-fncall x)
  (emit "jsr" (symbol->string (car x))))

(define (emit-set! x)
  (append
   (emit-expr (caddr x))
   (emit "sta" (immediate-value (cadr x)))))

(define (emit-write! x)
  (append
   (emit-expr (list-ref x 3))
   (emit "ldy" (immediate-value (list-ref x 2)))
   (emit "sta" (immediate-value (list-ref x 1)) ",y")))

(define (emit-poke! x)
  (append
   (emit-expr (list-ref x 3)) ;; value
   (emit "pha")
   (emit-expr (list-ref x 2)) ;; address
   (emit "tay")
   (emit "pla")
   (emit "sta" (immediate-value (list-ref x 1)) ",y")))

(define (emit-peek x)
  (append
   (emit-expr (list-ref x 2)) ;; address
   (emit "tay")
   (emit "lda" (immediate-value (list-ref x 1)) ",y")))

;; sets blocks of 256 bytes
;; (set-page variable/value expr)
(define (emit-memset x)
  (append
   (emit-expr (caddr x))
   (emit "ldx" "#$00")
   (emit "- sta" (immediate-value (cadr x)) ",x")
   (emit "inx")
   (emit "bne -")))

;; writes ppu data in blocks of 256 bytes
;; (ppu-write expr-high expr-low value-count expr-value)
;; (define (emit-ppu-memset x)
;;   (append
;;    (emit-expr (list-ref x 1))
;;    (emit "sta" (reg-table-lookup 'reg-ppu-addr))
;;    (emit-expr (list-ref x 2))
;;    (emit "sta" (reg-table-lookup 'reg-ppu-addr))
;;    (emit "ldy" "#$00")
;;    (emit "ldx" (immediate-value (list-ref x 3)))
;;    (emit-expr (list-ref x 4))
;;    (emit "- sta" (reg-table-lookup 'reg-ppu-data))
;;    (emit "iny")
;;    (emit "bne -")
;;    (emit "dex")
;;    (emit "bne -")))

(define (emit-ppu-memset x)
  (append
   (emit-expr (list-ref x 2))
   (emit "tax")
   (emit "lda" (car (immediate-value (list-ref x 1))))
   (emit "sta" (reg-table-lookup 'reg-ppu-addr))
   (emit "lda" (cadr (immediate-value (list-ref x 1))))
   (emit "sta" (reg-table-lookup 'reg-ppu-addr))
   (emit-expr (list-ref x 3))
   (emit "- sta" (reg-table-lookup 'reg-ppu-data))
   (emit "dex")
   (emit "bne -")))

(define (emit-ppu-memset-carry-on x)
  (append
   (emit-expr (list-ref x 2))
   (emit "ldx" (immediate-value (list-ref x 1)))
   (emit "- sta" (reg-table-lookup 'reg-ppu-data))
   (emit "dex")
   (emit "bne -")))

(define (emit-ppu-memcpy x)
  (append
   (emit "lda" (car (immediate-value (list-ref x 1))))
   (emit "sta" (reg-table-lookup 'reg-ppu-addr))
   (emit "lda" (cadr (immediate-value (list-ref x 1))))
   (emit "sta" (reg-table-lookup 'reg-ppu-addr))
   (emit "ldx" "#0")
   (emit "- lda" (immediate-value (list-ref x 3)) ",x")
   (emit "sta" (reg-table-lookup 'reg-ppu-data))
   (emit "inx")
   (emit "cpx" (immediate-value (list-ref x 2)))
   (emit "bne -")))

;; (loop var from to expr)
(define (emit-loop x)
  (let ((label (generate-label "loop")))
    (append
     (emit-expr (list-ref x 2))
     (emit "sta" (immediate-value (list-ref x 1)))
     (emit-label label)
     (emit-expr-list (cddddr x))
     (emit "inc" (immediate-value (list-ref x 1)))
     (emit "lda" (immediate-value (list-ref x 3)))
     (emit "cmp" (immediate-value (list-ref x 1)))
     (emit "bcs" label))))

(define (emit-mul x)
  (let ((label (generate-label "mul")))
    (append
     (emit-expr (cadr x))
     (emit "pha")
     (emit-expr (caddr x))
     (emit "sta" working-reg)
     (emit "pla")
     (emit "tax")
     (emit-label label)
     (emit "clc")
     (emit "adc" working-reg)
     (emit "dex")
     (emit "bne" label))))

(define (unary-procedure proc x)
  (append
   (emit-expr (cadr x))
   (emit proc)))

(define (binary-procedure proc x)
  (append
   (emit-expr (cadr x))
   (emit "pha")
   (emit-expr (caddr x))
   (emit "sta" working-reg)
   (emit "pla")
   (emit proc working-reg)))

(define (emit-procedure x)
  (cond
    ((eq? (car x) '+) (binary-procedure "adc" x))
    ((eq? (car x) '-) (binary-procedure "sbc" x))
    ((eq? (car x) '*) (emit-mul x))
    ((eq? (car x) 'bitwise-and) (binary-procedure "and" x))
    ((eq? (car x) 'bitwise-or) (binary-procedure "or" x))
    ((eq? (car x) 'bitwise-xor) (binary-procedure "eor" x))
    ((eq? (car x) 'inc) (emit "inc" (immediate-value (cadr x))))
    ((eq? (car x) 'dec) (emit "dec" (immediate-value (cadr x))))
    ((eq? (car x) 'wait-vblank)
     (append (emit "- lda $2002")
             (emit "bpl -")))
    ((eq? (car x) 'org) (emit ".org" (immediate-value (cadr x))))
    ((eq? (car x) 'memset) (emit-memset x))
    ((eq? (car x) 'ppu-memset) (emit-ppu-memset x))
    ((eq? (car x) 'ppu-memset-carry-on) (emit-ppu-memset-carry-on x))
    ((eq? (car x) 'ppu-memcpy) (emit-ppu-memcpy x))
    (else
     (emit-fncall x)
     )))


(define debug #t)

(define (emit-expr x)
  (cond
   ((immediate? x) (emit-load-immediate x))
   ((primcall? x)
    (append
     (emit ";;" (symbol->string (car x)))
     (cond
      ((eq? (car x) 'asm) (emit-asm x))
      ((eq? (car x) 'set!) (emit-set! x))
      ((eq? (car x) 'poke!) (emit-poke! x))
      ((eq? (car x) 'peek) (emit-peek x))
      ;;        ((eq? (car x) 'let) (emit-let x))
      ((eq? (car x) 'defvar) (emit-defvar x))
      ((eq? (car x) 'defun) (emit-defun x))
      ((eq? (car x) 'defint) (emit-defint x))
      ((eq? (car x) 'defconst) (make-constant! (cadr x) (caddr x)) '())
      ;;        ((eq? (car x) 'if) (emit-if x))
      ;;        ((eq? (car x) 'when) (emit-when x))
      ((eq? (car x) 'loop) (emit-loop x))
      ((eq? (car x) 'do) (emit-expr-list (cdr x)))
      (else (emit-procedure x)))
     (emit ";; ending " (symbol->string (car x)))
     ))
    (else
     (display "don't understand ")(display x)(newline) '())))

;----------------------------------------------------------------

(define (preprocess-cond-to-if x)
  (define (_ l)
    (cond
      ((null? l) 0)
      ((eq? (pre-process (caar l)) 'else) (cons 'do (pre-process (cdr (car l)))))
      (else (list 'if (pre-process (caar l)) (cons 'do (pre-process (cdr (car l))))
                  (_ (cdr l))))))
  (_ (cdr x)))

;; basically diy-macro from the main tinyscheme stuff
(define (pre-process s)
  (cond
    ((null? s) s)
    ((list? s)
     (map
      (lambda (i)
        (if (and (list? i) (not (null? i)))
            ;; dispatch to macro processors
            (cond
             ((eq? (car i) 'cond) (preprocess-cond-to-if i))
             (else (pre-process i)))
            (pre-process i)))
      s))
    (else s)))

(define (compile-program x)
  (set! variables '())
  (set! constants '())
  (emit-expr (pre-process x)))

(define (output fn x)
  (let ((f (open-output-file fn #:exists 'replace)))
    (for-each
     (lambda (line)
       (display line f)(newline f))
     (compile-program x))
    (close-output-port f)))

(define (assert fn x)
  (when (not x)
    (display "assert failed: ")(display fn)(newline)))

(define (dbg x)
  (display x)(newline) x)

(define (test)
  (assert "emit" (equal? (emit "1" "2" "3") (list "1 2 3")))
  (assert "reg-table-lookup 1" (equal? (reg-table-lookup 'reg-apu-pulse1-control) "$4000"))
  (assert "reg-table-lookup 2" (not (reg-table-lookup 'nonsense)))
  (assert "emit-load-variable 1"
          (equal? (emit-load-variable 'reg-apu-pulse1-control) (list "lda $4000")))
  (make-variable! 'poodle)
  (assert "emit-load-variable 2"
          (equal? (emit-load-variable 'poodle) (list "lda $00")))
  (assert "emit-load-immediate 1"
          (equal? (emit-load-immediate 'reg-oam-dma) (list "lda $4014")))
  (assert "emit-load-immediate 2"
          (equal? (emit-load-immediate 'poodle) (list "lda $00")))
  (assert "emit-defvar" (equal? (emit-defvar '(defvar poodle2 30)) '("lda #30" "sta $01")))
  )

(test)

(let ((f (open-input-file (command-line #:args (input) input))))
  (output "out.asm" (read f))
  (close-input-port f))
