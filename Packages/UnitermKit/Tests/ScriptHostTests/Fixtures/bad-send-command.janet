(import uniterm)

(defn refuses [label needle f]
  (def [ok message] (protect (f)))
  (assert (not ok) (string label " was accepted"))
  (assert (string/find needle (string message)) (string label " failed with: " message)))

(def pane {:window 7 :pane 1})

(defn deep [levels] (if (= levels 0) 1 {:a (deep (- levels 1))}))

(refuses "no argument" "arity" (fn [] (uniterm/send-command)))
(refuses "too many" "arity" (fn [] (uniterm/send-command pane :fixture-slides 1 :status {} {})))
(refuses "a bad pane" "must be a struct" (fn [] (uniterm/send-command 1 :fixture-slides 1 :status)))
(refuses "a string type" "keyword" (fn [] (uniterm/send-command pane "fixture-slides" 1 :status)))
(refuses "a path type" "not a path" (fn [] (uniterm/send-command pane :a/b 1 :status)))
(refuses "a negative version" "whole number" (fn [] (uniterm/send-command pane :fixture-slides -1 :status)))
(refuses "a fractional version" "whole number" (fn [] (uniterm/send-command pane :fixture-slides 1.5 :status)))
(refuses "a version as a string" "must be a number" (fn [] (uniterm/send-command pane :fixture-slides "1" :status)))
(refuses "a number command" "keyword or a string" (fn [] (uniterm/send-command pane :fixture-slides 1 5)))
(refuses "an empty command" "empty" (fn [] (uniterm/send-command pane :fixture-slides 1 "")))
(refuses "array arguments" "struct or a table" (fn [] (uniterm/send-command pane :fixture-slides 1 :status [1])))
(refuses "a function value" "cannot hold" (fn [] (uniterm/send-command pane :fixture-slides 1 :status {:f print})))
(refuses "an infinite number" "not finite" (fn [] (uniterm/send-command pane :fixture-slides 1 :status {:x math/inf})))
(refuses "a number key" "keyword or a string" (fn [] (uniterm/send-command pane :fixture-slides 1 :status {1 2})))
(refuses "a repeated key" "twice" (fn [] (uniterm/send-command pane :fixture-slides 1 :status {:a 1 "a" 2})))
(refuses "deep arguments" "nest" (fn [] (uniterm/send-command pane :fixture-slides 1 :status (deep 20))))
(refuses "large arguments" "bytes as JSON" (fn [] (uniterm/send-command pane :fixture-slides 1 :status {:s (string/repeat "x" 40000)})))
(refuses "text that is not UTF-8" "not UTF-8" (fn [] (uniterm/send-command pane :fixture-slides 1 :status {:s "\xFF"})))
