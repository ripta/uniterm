# The shared fixture controller. It imports a packaged module and the bundled uniterm module.
(import uniterm)
(import ./lib/greet)

(print (greet/greeting "fixture"))
(uniterm/post-status :info (greet/greeting "fixture"))
