(define (fact n)
  (if (= n 0) 
     1
     (* n (fact (- n 1)))))

(print "(fact 0)")
(print (fact 0))
(sleep 1)

(print "(fact 1)")
(print  (fact 1))
(sleep 1)

(print "(fact 2)")
(print  (fact 2))
(sleep 1)

(print "(fact 3)")
(print  (fact 3))
(sleep 1)

(print "(fact 4)")
(print  (fact 4))
(sleep 1)

(print "(fact 5)")
(print  (fact 5))
(sleep 1)

(print "(fact 6)")
(print  (fact 6))
(sleep 1)

(print "(fact 7)")
(print  (fact 7))
(sleep 1)

(print "(fact 100)")
(print  (fact 100))
(sleep 1)

args
