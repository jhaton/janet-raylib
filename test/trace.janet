# Trace log capture. Runs without a window.
(import raylib :as rl)

(var failures 0)
(defmacro check [what expr expected]
  ~(let [actual (try ,expr ([err] [:error err]))]
     (unless (deep= actual ,expected)
       (++ failures)
       (eprintf "FAIL %s\n  expected %q\n  got      %q" ,what ,expected actual))))

(rl/set-trace-log-level :info)
(rl/set-trace-log-capture true)
(rl/take-trace-logs)

(rl/compress-data (string/repeat "ab" 64))
(def logs (rl/take-trace-logs))
(check "raylib's own messages are queued with their level"
       (map |[($ 0) (string/has-prefix? "SYSTEM: Compress data" ($ 1))] logs)
       @[[rl/log-info true]])
(check "taking drains the queue" (rl/take-trace-logs) @[])

(rl/trace-log :warning "100% done")
(check "messages are not re-interpreted as format strings" (rl/take-trace-logs) @[[rl/log-warning "100% done"]])

(rl/set-trace-log-level :warning)
(rl/trace-log :info "filtered")
(rl/trace-log :error "kept")
(check "the log level still filters" (rl/take-trace-logs) @[[rl/log-error "kept"]])

(for i 0 600 (rl/trace-log :warning (string "message " i)))
(def flooded (rl/take-trace-logs))
(check "a full queue keeps the newest 512 and reports the rest"
       [(length flooded) (first flooded) (get flooded 1) (last flooded)]
       [513 [rl/log-warning "88 older trace log messages were dropped"]
        [rl/log-warning "message 88"] [rl/log-warning "message 599"]])

(rl/set-trace-log-capture false)
(rl/set-trace-log-level :none) # keep raylib quiet now that it prints again
(rl/trace-log :error "not queued")
(check "disabling capture stops queueing" (rl/take-trace-logs) @[])

(if (zero? failures) (print "trace: ok") (do (eprintf "trace: %d failure(s)" failures) (os/exit 1)))
