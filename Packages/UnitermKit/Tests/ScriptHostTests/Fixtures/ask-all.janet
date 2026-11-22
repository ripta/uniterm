(import uniterm)

(print (uniterm/ask-confirm "Delete 3 files?"))
(print (uniterm/ask-text "Branch?" :default "main" :pattern "^[a-z]+$"))
(print (string/join (uniterm/ask-choose "Which?" ["a" "b" "c"] :multiple true) ","))
(print (uniterm/ask-number "Replicas?" :integer true :min 1 :max 20))
(print (uniterm/ask-color "Accent?"))
(print (uniterm/ask-file "Pick" :mode :save :types ["public.json"]))

(def result
  (uniterm/ask
    {:title "Deploy settings"
     :items [{:block :notice :level :warning :text "Production."}
             {:id :region :text "Region?" :type :choice :choices ["us" "eu"] :other true}]
     :actions [{:id :go :label "Go" :role :primary}
               {:id :cancel :role :cancel}]}))

(print (result :action) " " ((result :answers) :region))

# A closed or cancelled question returns nil, and the next form opens in the same tab.
(print (or (uniterm/ask-text "Again?") "nothing"))
(print "done")
