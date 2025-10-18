;; Decentralized Autonomous University - Academic Operations
;; Smart contract-managed courses, outcome-based compensation, and resource allocation

(define-constant CONTRACT-OWNER tx-sender)
(define-constant ERR-NOT-AUTHORIZED (err u2001))
(define-constant ERR-COURSE-NOT-FOUND (err u2002))
(define-constant ERR-INVALID-INPUT (err u2003))
(define-constant ERR-INSUFFICIENT-BUDGET (err u2004))
(define-constant ERR-COURSE-FULL (err u2005))
(define-constant ERR-NOT-ENROLLED (err u2006))

;; Course states
(define-constant COURSE-OPEN u1)
(define-constant COURSE-ACTIVE u2)
(define-constant COURSE-COMPLETED u3)

;; Course offerings
(define-map courses
  uint
  {
    faculty: principal,
    title: (string-ascii 100),
    capacity: uint,
    enrolled: uint,
    state: uint,
    base-pay: uint,
    outcome-threshold: uint,
    actual-outcome: uint,
    created-at: uint
  }
)

;; Student enrollments
(define-map enrollments
  { course-id: uint, student: principal }
  {
    grade: uint
  }
)

;; Outcome-based faculty compensation
(define-map faculty-compensation
  principal
  {
    total-earned: uint,
    courses-taught: uint,
    avg-outcome: uint,
    pending-payout: uint
  }
)

;; Resource budgets per department
(define-map resources
  (string-ascii 32)
  {
    budget: uint,
    allocated: uint,
    available: uint
  }
)

;; Data variables
(define-data-var next-course-id uint u1)
(define-data-var total-admin-fund uint u10000000)

;; Read-only functions
(define-read-only (get-course (course-id uint))
  (map-get? courses course-id)
)

(define-read-only (get-enrollment (course-id uint) (student principal))
  (map-get? enrollments { course-id: course-id, student: student })
)

(define-read-only (get-faculty-compensation (faculty principal))
  (map-get? faculty-compensation faculty)
)

(define-read-only (get-resource-budget (resource (string-ascii 32)))
  (map-get? resources resource)
)

(define-read-only (calculate-outcome-compensation (course-id uint))
  (match (get-course course-id)
    course
    (let ((base (get base-pay course))
          (threshold (get outcome-threshold course))
          (actual (get actual-outcome course)))
      (if (>= actual threshold)
        (+ base (/ (* base u25) u100))
        base))
    u0)
)

;; Public functions - Course Management
(define-public (create-course (title (string-ascii 100)) (capacity uint) (base-pay uint) (outcome-threshold uint))
  (let ((course-id (var-get next-course-id)))
    (asserts! (> capacity u0) ERR-INVALID-INPUT)
    (asserts! (> base-pay u0) ERR-INVALID-INPUT)
    (asserts! (<= outcome-threshold u100) ERR-INVALID-INPUT)
    
    (map-set courses course-id {
      faculty: tx-sender,
      title: title,
      capacity: capacity,
      enrolled: u0,
      state: COURSE-OPEN,
      base-pay: base-pay,
      outcome-threshold: outcome-threshold,
      actual-outcome: u0,
      created-at: stacks-block-height
    })
    
    (var-set next-course-id (+ course-id u1))
    (ok course-id)
  )
)

(define-public (enroll-student (course-id uint) (student principal))
  (match (get-course course-id)
    course
    (begin
      (asserts! (is-eq (get state course) COURSE-OPEN) ERR-INVALID-INPUT)
      (asserts! (< (get enrolled course) (get capacity course)) ERR-COURSE-FULL)
      (asserts! (is-none (map-get? enrollments { course-id: course-id, student: student })) ERR-INVALID-INPUT)
      
      (map-set enrollments
        { course-id: course-id, student: student }
        { grade: u0 })
      
      (map-set courses course-id (merge course {
        enrolled: (+ (get enrolled course) u1)
      }))
      
      (ok true))
    ERR-COURSE-NOT-FOUND)
)

(define-public (start-course (course-id uint))
  (match (get-course course-id)
    course
    (begin
      (asserts! (is-eq tx-sender (get faculty course)) ERR-NOT-AUTHORIZED)
      (asserts! (is-eq (get state course) COURSE-OPEN) ERR-INVALID-INPUT)
      
      (map-set courses course-id (merge course {
        state: COURSE-ACTIVE
      }))
      
      (ok true))
    ERR-COURSE-NOT-FOUND)
)

(define-public (grade-student (course-id uint) (student principal) (grade uint))
  (match (get-course course-id)
    course
    (begin
      (asserts! (is-eq tx-sender (get faculty course)) ERR-NOT-AUTHORIZED)
      (asserts! (is-some (map-get? enrollments { course-id: course-id, student: student })) ERR-NOT-ENROLLED)
      (asserts! (<= grade u100) ERR-INVALID-INPUT)
      
      (map-set enrollments
        { course-id: course-id, student: student }
        { grade: grade })
      
      (ok true))
    ERR-COURSE-NOT-FOUND)
)

;; Complete course with outcome measurement and compensation
(define-public (complete-course (course-id uint) (outcome-score uint))
  (match (get-course course-id)
    course
    (let ((faculty (get faculty course))
          (compensation (calculate-outcome-compensation course-id))
          (current (default-to
                     { total-earned: u0, courses-taught: u0, avg-outcome: u0, pending-payout: u0 }
                     (map-get? faculty-compensation faculty))))
      (begin
        (asserts! (is-eq tx-sender (get faculty course)) ERR-NOT-AUTHORIZED)
        (asserts! (is-eq (get state course) COURSE-ACTIVE) ERR-INVALID-INPUT)
        (asserts! (<= outcome-score u100) ERR-INVALID-INPUT)
        
        (map-set courses course-id (merge course {
          state: COURSE-COMPLETED,
          actual-outcome: outcome-score
        }))
        
        (map-set faculty-compensation faculty {
          total-earned: (+ (get total-earned current) compensation),
          courses-taught: (+ (get courses-taught current) u1),
          avg-outcome: outcome-score,
          pending-payout: (+ (get pending-payout current) compensation)
        })
        
        (ok compensation)))
    ERR-COURSE-NOT-FOUND)
)

;; Resource Allocation Management
(define-public (allocate-resource (resource (string-ascii 32)) (amount uint))
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
    (asserts! (> amount u0) ERR-INVALID-INPUT)
    
    (let ((current (default-to
                     { budget: u0, allocated: u0, available: u0 }
                     (map-get? resources resource))))
      (begin
        (asserts! (<= amount (var-get total-admin-fund)) ERR-INSUFFICIENT-BUDGET)
        
        (map-set resources resource {
          budget: (+ (get budget current) amount),
          allocated: (get allocated current),
          available: (+ (get available current) amount)
        })
        
        (ok amount)))
  )
)

(define-public (use-resource (resource (string-ascii 32)) (amount uint))
  (match (map-get? resources resource)
    budget-info
    (begin
      (asserts! (<= amount (get available budget-info)) ERR-INSUFFICIENT-BUDGET)
      
      (map-set resources resource {
        budget: (get budget budget-info),
        allocated: (+ (get allocated budget-info) amount),
        available: (- (get available budget-info) amount)
      })
      
      (ok true))
    ERR-INVALID-INPUT)
)