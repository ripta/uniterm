(import uniterm)

(defn refuses [label needle f]
  (def [ok message] (protect (f)))
  (assert (not ok) (string label " was accepted"))
  (assert (string/find needle (string message)) (string label " failed with: " message)))

(def pane {:window 7 :pane 1})

(defn deep [levels] (if (= levels 0) {:pane 1} {:split :row :children [(deep (- levels 1))]}))

(refuses "no argument" "arity" (fn [] (uniterm/request-layout)))
(refuses "one argument" "arity" (fn [] (uniterm/request-layout pane)))
(refuses "a bad pane" "must be a struct" (fn [] (uniterm/request-layout 1 {:pane 1})))
(refuses "an array layout" "struct or a table" (fn [] (uniterm/request-layout pane [{:pane 1}])))
(refuses "a string layout" "struct or a table" (fn [] (uniterm/request-layout pane "{}")))
(refuses "a function value" "cannot hold" (fn [] (uniterm/request-layout pane {:open print})))
(refuses "an infinite weight" "not finite" (fn [] (uniterm/request-layout pane {:pane 1 :weight math/inf})))
(refuses "a repeated key" "twice" (fn [] (uniterm/request-layout pane {:pane 1 "pane" 2})))
(refuses "a deep layout" "nesting in the layout" (fn [] (uniterm/request-layout pane (deep 20))))

# A too-large layout gets a structured error, as the app's own failures and send-command's do.
(def [ok failure] (protect (uniterm/request-layout pane {:open (string/repeat "x" 40000)})))
(assert (not ok) "a large layout was accepted")
(assert (struct? failure) (string "the oversize error is not a struct: " failure))
(assert (= (failure :kind) :bad-argument) (string "the oversize kind was " (failure :kind)))
(assert (string/find "bytes as JSON" (failure :message)) (string "the oversize message was " (failure :message)))

(refuses "text that is not UTF-8" "not UTF-8" (fn [] (uniterm/request-layout pane {:open "\xFF"})))
