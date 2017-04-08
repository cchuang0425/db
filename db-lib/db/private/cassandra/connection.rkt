#lang racket/base
(require racket/class
         racket/match
         db/private/generic/interfaces
         db/private/generic/common
         db/private/generic/sql-data
         db/private/generic/prepared
         "message.rkt"
         "dbsystem.rkt")
(provide connection%)

(define current-consistency (make-parameter 'ONE))

;; A LWAC is (cons Semaphore Box)

;; lwac-ref : LWAC -> Any
(define (lwac-ref lwac)
  (semaphore-wait (car lwac))
  (unbox (cdr lwac)))

;; ========================================

(define disconnect2%
  (class locking%
    (inherit dprintf
             call-with-lock*
             connected?)
    (super-new)

    ;; disconnect : -> void
    ;; LOCKING: requires unlocked
    (define/public (disconnect)
      (when (connected?)
        (call-with-lock* 'disconnect
                         (lambda () (disconnect* #t))
                         (lambda () (disconnect* #f))
                         #f)))

    ;; LOCKING: requires locked
    (define/public (disconnect* politely?)
      (dprintf "  ** disconnecting~a\n" (if politely? " politely" ""))
      (void))

    (define/override (on-break-within-lock)
      (dprintf "  ** break occurred within lock\n")
      (disconnect* #f))))

(define connection%
  (class* disconnect2% (connection<%>)
    ;; Lock controls writing to output.
    ;; Reader thread has exclusive access to inport (once connection is complete).
    (init-field inport
                outport)

    (inherit call-with-lock
             call-with-lock*
             add-delayed-call!
             dprintf)

    (super-new)

    ;; ========================================
    ;; Sending messages

    ;; next-streamid : nat
    (define next-streamid 1)

    ;; new-streamid : -> nat
    ;; Just wrap at 16k, hope that old streamids are no longer in use.
    (define/private (new-streamid)
      (begin0 next-streamid
        (set! next-streamid
              (if (< next-streamid 16000) 1 (add1 next-streamid)))))

    ;; send-message : nat message -> void
    (define/private (send-message streamid msg)
      (dprintf "  >> #~s ~s\n" streamid msg)
      (write-message outport msg streamid)
      (flush-output outport))

    ;; ----------------------------------------
    ;; Receiving messages

    ;; recv-map : Hash[ Nat => LWAChan ]
    (define recv-map (make-hash))

    ;; call/lock/streamid : Symbol (Nat -> Void) -> LWAC
    (define/private (call/lock/streamid who proc [k values])
      (define streamid (new-streamid))
      (define lwac (add-recv-lwachan streamid))
      (call-with-lock who (lambda () (proc streamid)))
      (k lwac))

    ;; add-recv-lwachan : Nat -> LWAC
    (define/private (add-recv-lwachan streamid)
      (define lwac (cons (make-semaphore 0) (box #f)))
      (hash-set! recv-map streamid lwac)
      lwac)

    ;; recv-thread-go : Semaphore
    (define recv-thread-go (make-semaphore 0))

    ;; FIXME: handle inport EOF?
    (thread
     (lambda ()
       (semaphore-wait recv-thread-go)
       (with-handlers ([(lambda (e) #t)
                        (lambda (e)
                          ;; FIXME?
                          (disconnect* #f)
                          (raise e))])
         (let loop ()
           (match (read-response inport)
             [(cons resp streamid)
              (dprintf "  << #~s ~s\n" streamid resp)
              (define lwac (hash-ref recv-map streamid))
              (hash-remove! recv-map streamid)
              (set-box! (cdr lwac) resp)
              (semaphore-post (car lwac))])
           (loop)))))

    ;; recv-message : symbol -> message
    (define/private (recv-message who)
      (match (read-response inport)
        [(cons r streamid)
         (dprintf "  << #~s ~s\n" streamid r)
         (cond [(Error? r)
                (raise-backend-error who r)]
               [(Event? r)
                (handle-async-message who r)
                (recv-message who)]
               [else r])]))

    ;; == Asynchronous messages

    ;; handle-async-message : message -> void
    (define/private (handle-async-message fsym msg)
      (match msg
        [_ (add-delayed-call! (lambda () (void)))]))

    ;; == Connection management

    ;; disconnect* : boolean -> void
    (define/override (disconnect* politely?)
      (super disconnect* politely?)
      (let ([outport* outport]
            [inport* inport])
        (when outport*
          (close-output-port outport*)
          (set! outport #f))
        (when inport*
          (close-input-port inport*)
          (set! inport #f))))

    ;; connected? : -> boolean
    (define/override (connected?)
      (let ([outport outport])
        (and outport (not (port-closed? outport)))))

    ;; == System

    (define/public (get-dbsystem) dbsystem)

    (define/public (get-base) this)

    ;; ========================================
    ;; == Connect

    ;; start-connection-protocol : -> void
    (define/public (start-connection-protocol)
      (call-with-lock 'cassandra-connect
        (lambda ()
          (send-message 1 (Startup '(("CQL_VERSION" . "3.0.0"))))
          (connect:expect-ready))))

    ;; connect:expect-ready : -> Void
    (define/private (connect:expect-ready)
      (let ([r (recv-message 'cassandra-connect)])
        (match r
          [(Ready)
           (semaphore-post recv-thread-go)]
          [(Authenticate _)
           (error 'cassandra-connect "got Authenticate message: ~e" r)]
          [(AuthChallenge _)
           (error 'cassandra-connect "got AuthChallenge message: ~e" r)]
          [(AuthSuccess _)
           (error 'cassandra-connect "got AuthSuccess message: ~e" r)])))

    ;; ========================================
    ;; == Transactions

    (define/public (transaction-status who) #f)

    (define/public (start-transaction who isolation option cwt?)
      (error who "transactions not supported"))

    (define/public (end-transaction who mode cwt?)
      (error who "transactions not supported"))

    ;; ========================================
    ;; == Cache

    ;; FIXME: need to reimplement statement cache

    ;; ========================================
    ;; == Prepare

    (define/public (prepare who stmt _close-on-exec?)
      (call/lock/streamid who
        (lambda (streamid) (send-message streamid (Prepare stmt)))
        (lambda (lwac)
          (match (lwac-ref lwac)
            [(Result:Prepared _ stmt-id param-dvecs result-dvecs)
             (new prepared-statement%
                  (handle stmt-id)
                  (close-on-exec? #f)
                  (param-typeids (map dvec-type param-dvecs))
                  (result-dvecs result-dvecs)
                  (stmt stmt)
                  (owner this))]
            [other (error/comm who "during prepare")]))))

    ;; free-statement : prepared-statement -> void
    (define/public (free-statement pst need-lock?)
      ;; protocol does not seem to have any way of freeing statements
      (void))

    ;; ============================================================
    ;; == Query

    (define/public (query-evt who stmt)
      (define lwac (query1:send who stmt #f))
      (wrap-evt (car lwac) (lambda (s) (query1:collect who (unbox (cdr lwac))))))

    ;; query : Symbol Statement Boolean -> QueryResult
    (define/public (query who stmt cursor?)
      (when cursor? (error who "cursors not supported yet"))
      (query1:collect who (lwac-ref (query1:send who stmt cursor?))))

    ;; query1:send : Symbol Statement -> LWAC
    (define/private (query1:send who stmt cursor?)
      (let ([stmt (check-statement who stmt cursor?)])
        (call/lock/streamid who
          (lambda (streamid)
            (match stmt
              [(statement-binding pst params)
               (send-message streamid
                             (Execute (send pst get-handle) (current-consistency) params))]
              [(? string? stmt)
               (send-message streamid
                             (Query stmt (current-consistency) #f))])))))

    ;; query1:collect : Symbol LWAC -> QueryResult
    (define/private (query1:collect who msg)
      (match msg
        [(Result:Void _)
         (simple-result #f)]
        [(Result:Rows _ _pagestate dvecs rows)
         (rows-result (map dvec->field-info dvecs) rows)]))

    ;; check-statement : Symbol Statement -> Statement
    (define/private (check-statement who stmt cursor?)
      (cond [(statement-binding? stmt)
             (let ([pst (statement-binding-pst stmt)])
               (send pst check-owner who this stmt)
               stmt)]
            [(string? stmt) stmt]))

    ;; == Cursor

    (define/public (fetch/cursor who cursor fetch-size)
      (error who "not yet implemented"))

    ;; == Reflection

    (define/public (list-tables who schema)
      (error who "not yet implemented"))
    ))

;; ========================================

;; raise-backend-error : symbol Error -> raises exn
(define (raise-backend-error who r)
  (match r
    [(Error code message)
     (raise-sql-error who code message `((code . ,code) (message . ,message)))]))