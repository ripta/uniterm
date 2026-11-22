(import uniterm)

(def spec
  ``{"title": "T", "items": [{"id": "ok", "text": "Sure?", "type": "boolean"}]}``)

(defn fails-with [kind f]
  (def [ok failure] (protect (f)))
  (assert (not ok) (string kind " was accepted"))
  (assert (struct? failure) (string "the error is not a struct: " failure))
  (assert (= (failure :kind) kind) (string "the kind was " (failure :kind)))
  (assert (string? (failure :message)) "the error has no message"))

(def form (uniterm/open-form spec))

(assert (number? form) "the handle is not a number")

# One form at a time, so a second is busy and the script goes on.
(fails-with :busy (fn [] (uniterm/open-form spec)))
(fails-with :bad-argument (fn [] (uniterm/open-form `{"items": [], "extra": 1}`)))
(fails-with :not-found (fn [] (uniterm/wait-form (+ form 1000))))

# Discarding an open form ends it, and the handle is gone.
(assert (nil? (uniterm/discard-form form)) "the discard returned something")
(fails-with :not-found (fn [] (uniterm/wait-form form)))
(fails-with :not-found (fn [] (uniterm/discard-form form)))

# The next form opens, and a wait on a form nobody answered would block, so it is left open.
(assert (number? (uniterm/open-form spec)) "the next form did not open")

# Arguments are checked before the app hears of the call.
(assert (not (first (protect (uniterm/open-form 5)))) "a number was a spec")
(assert (not (first (protect (uniterm/open-form)))) "no spec was accepted")
(assert (not (first (protect (uniterm/wait-form "one")))) "a string was a handle")
(assert (not (first (protect (uniterm/discard-form -1)))) "a negative handle was accepted")
