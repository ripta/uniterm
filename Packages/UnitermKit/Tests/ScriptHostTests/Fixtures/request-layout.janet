(import uniterm)

(def pane {:window 7 :pane 1})

(def layout
  {:split :row
   :children [{:pane 1 :weight 2}
              {:split :column
               :children [{:open :fixture-notes :control :remote-controlled}
                          {:open :fixture-chart :directory "/synthetic/charts"
                           :exec {:argv ["/usr/bin/perl" "chart.pl"] :environment-keys ["TOKEN"]}}]}]})

(def reply (uniterm/request-layout pane layout))

(assert (= (reply :window) 7) (string "the reply named window " (reply :window)))
(assert (= (length (reply :panes)) 3) "the reply has no reference for each leaf")
(assert (= ((get (reply :panes) 0) :pane) 1) "the first leaf is not the anchor")
(assert (= ((get (reply :panes) 2) :pane) 21) "the last leaf lost its pane")

(uniterm/request-layout {:nearest :fixture-slides} @{:pane 2})

# A refusal from the app is a struct that names its kind, and the script goes on.
(def [ok failure] (protect (uniterm/request-layout pane {:refuse true})))

(assert (not ok) "a refused layout was accepted")
(assert (= (failure :kind) :refused) (string "the kind was " (failure :kind)))
(assert (string? (failure :message)) "the error has no message")

(def [free busy] (protect (uniterm/request-layout pane {:busy true})))

(assert (not free) "a busy layout was accepted")
(assert (= (busy :kind) :busy) (string "the kind was " (busy :kind)))

(def [found missing] (protect (uniterm/request-layout {:window 7 :pane 404} {:pane 404})))

(assert (not found) "a layout from a closed pane was accepted")
(assert (= (missing :kind) :not-found) (string "the kind was " (missing :kind)))
