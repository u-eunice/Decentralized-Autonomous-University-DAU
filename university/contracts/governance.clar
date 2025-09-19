;; Decentralized Autonomous University (DAU) Governance Contract
;; Implements token-based voting system with balanced stakeholder representation

;; Constants
(define-constant CONTRACT-OWNER tx-sender)
(define-constant ERR-NOT-AUTHORIZED (err u1001))
(define-constant ERR-INVALID-PROPOSAL (err u1002))
(define-constant ERR-PROPOSAL-NOT-ACTIVE (err u1003))
(define-constant ERR-ALREADY-VOTED (err u1004))
(define-constant ERR-INSUFFICIENT-TOKENS (err u1005))
(define-constant ERR-PROPOSAL-EXPIRED (err u1006))

;; Token thresholds for different stakeholder types
(define-constant MIN-STUDENT-TOKENS u100)
(define-constant MIN-FACULTY-TOKENS u500)
(define-constant MIN-ALUMNI-TOKENS u250)
(define-constant MIN-INDUSTRY-TOKENS u1000)

;; Voting periods and quorum requirements
(define-constant VOTING-PERIOD u144) ;; ~24 hours in blocks (assuming 10min blocks)
(define-constant QUORUM-THRESHOLD u20) ;; 20% minimum participation
(define-constant PROPOSAL-DEPOSIT u1000) ;; Tokens required to create proposal

;; Data variables
(define-data-var next-proposal-id uint u1)
(define-data-var total-token-supply uint u10000000) ;; 10M tokens initially

;; Maps
(define-map proposals 
  { proposal-id: uint }
  {
    proposer: principal,
    title: (string-ascii 100),
    description: (string-ascii 500),
    proposal-type: (string-ascii 20),
    start-block: uint,
    end-block: uint,
    votes-for: uint,
    votes-against: uint,
    votes-abstain: uint,
    total-voters: uint,
    status: (string-ascii 10),
    executed: bool
  }
)

(define-map stakeholder-types
  { user: principal }
  { 
    stakeholder-type: (string-ascii 10),
    voting-weight: uint,
    token-balance: uint,
    registration-block: uint
  }
)

(define-map proposal-votes
  { proposal-id: uint, voter: principal }
  {
    vote-choice: (string-ascii 10), ;; "for", "against", "abstain"
    voting-power: uint,
    vote-block: uint
  }
)

(define-map user-voting-history
  { user: principal }
  { 
    total-votes: uint,
    last-vote-block: uint,
    participation-score: uint
  }
)

;; Read-only functions

;; Get proposal details
(define-read-only (get-proposal (proposal-id uint))
  (map-get? proposals { proposal-id: proposal-id })
)

;; Get user's stakeholder information
(define-read-only (get-stakeholder-info (user principal))
  (map-get? stakeholder-types { user: user })
)

;; Check if user has voted on a proposal
(define-read-only (has-voted (proposal-id uint) (voter principal))
  (is-some (map-get? proposal-votes { proposal-id: proposal-id, voter: voter }))
)

;; Calculate voting power based on stakeholder type and token balance
(define-read-only (calculate-voting-power (user principal))
  (let (
    (stakeholder-info (get-stakeholder-info user))
  )
    (match stakeholder-info
      stakeholder-data
      (let (
        (base-tokens (get token-balance stakeholder-data))
        (weight (get voting-weight stakeholder-data))
        (stakeholder-type (get stakeholder-type stakeholder-data))
      )
        (if (>= base-tokens (get-min-tokens-for-type stakeholder-type))
          (* base-tokens weight)
          u0
        )
      )
      u0
    )
  )
)

;; Get minimum tokens required for stakeholder type
(define-read-only (get-min-tokens-for-type (stakeholder-type (string-ascii 10)))
  (if (is-eq stakeholder-type "student")
    MIN-STUDENT-TOKENS
    (if (is-eq stakeholder-type "faculty")
      MIN-FACULTY-TOKENS
      (if (is-eq stakeholder-type "alumni")
        MIN-ALUMNI-TOKENS
        (if (is-eq stakeholder-type "industry")
          MIN-INDUSTRY-TOKENS
          u0
        )
      )
    )
  )
)

;; Check if proposal meets quorum requirements
(define-read-only (meets-quorum (proposal-id uint))
  (let (
    (proposal-data (unwrap! (get-proposal proposal-id) false))
    (total-voters (get total-voters proposal-data))
    (total-supply (var-get total-token-supply))
    (participation-rate (/ (* total-voters u100) total-supply))
  )
    (>= participation-rate QUORUM-THRESHOLD)
  )
)

;; Get proposal result
(define-read-only (get-proposal-result (proposal-id uint))
  (let (
    (proposal-data (unwrap! (get-proposal proposal-id) (err ERR-INVALID-PROPOSAL)))
    (votes-for (get votes-for proposal-data))
    (votes-against (get votes-against proposal-data))
    (current-block stacks-block-height)
    (end-block (get end-block proposal-data))
  )
    (if (and 
          (> current-block end-block)
          (meets-quorum proposal-id))
      (if (> votes-for votes-against)
        (ok "passed")
        (ok "rejected")
      )
      (ok "pending")
    )
  )
)

;; Public functions

;; Register as a stakeholder
(define-public (register-stakeholder (stakeholder-type (string-ascii 10)) (token-balance uint))
  (let (
    (voting-weight (get-stakeholder-voting-weight stakeholder-type))
    (min-tokens (get-min-tokens-for-type stakeholder-type))
  )
    (asserts! (>= token-balance min-tokens) ERR-INSUFFICIENT-TOKENS)
    (ok (map-set stakeholder-types
      { user: tx-sender }
      {
        stakeholder-type: stakeholder-type,
        voting-weight: voting-weight,
        token-balance: token-balance,
        registration-block: stacks-block-height
      }
    ))
  )
)

;; Create a new proposal
(define-public (create-proposal 
  (title (string-ascii 100))
  (description (string-ascii 500))
  (proposal-type (string-ascii 20)))
  (let (
    (proposal-id (var-get next-proposal-id))
    (user-tokens (get-user-token-balance tx-sender))
  )
    (asserts! (>= user-tokens PROPOSAL-DEPOSIT) ERR-INSUFFICIENT-TOKENS)
    (asserts! (is-some (get-stakeholder-info tx-sender)) ERR-NOT-AUTHORIZED)
    
    (map-set proposals
      { proposal-id: proposal-id }
      {
        proposer: tx-sender,
        title: title,
        description: description,
        proposal-type: proposal-type,
        start-block: stacks-block-height,
        end-block: (+ stacks-block-height VOTING-PERIOD),
        votes-for: u0,
        votes-against: u0,
        votes-abstain: u0,
        total-voters: u0,
        status: "active",
        executed: false
      }
    )
    
    (var-set next-proposal-id (+ proposal-id u1))
    (ok proposal-id)
  )
)

;; Cast vote on a proposal
(define-public (vote (proposal-id uint) (vote-choice (string-ascii 10)))
  (let (
    (proposal-data (unwrap! (get-proposal proposal-id) ERR-INVALID-PROPOSAL))
    (current-block stacks-block-height)
    (end-block (get end-block proposal-data))
    (voting-power (calculate-voting-power tx-sender))
    (existing-vote (map-get? proposal-votes { proposal-id: proposal-id, voter: tx-sender }))
  )
    ;; Validate voting conditions
    (asserts! (<= current-block end-block) ERR-PROPOSAL-EXPIRED)
    (asserts! (is-eq (get status proposal-data) "active") ERR-PROPOSAL-NOT-ACTIVE)
    (asserts! (is-none existing-vote) ERR-ALREADY-VOTED)
    (asserts! (> voting-power u0) ERR-NOT-AUTHORIZED)
    (asserts! (or (is-eq vote-choice "for") 
                  (is-eq vote-choice "against") 
                  (is-eq vote-choice "abstain")) ERR-INVALID-PROPOSAL)

    ;; Record the vote
    (map-set proposal-votes
      { proposal-id: proposal-id, voter: tx-sender }
      {
        vote-choice: vote-choice,
        voting-power: voting-power,
        vote-block: current-block
      }
    )

    ;; Update proposal vote counts
    (let (
      (new-votes-for (if (is-eq vote-choice "for") 
                       (+ (get votes-for proposal-data) voting-power)
                       (get votes-for proposal-data)))
      (new-votes-against (if (is-eq vote-choice "against")
                           (+ (get votes-against proposal-data) voting-power)
                           (get votes-against proposal-data)))
      (new-votes-abstain (if (is-eq vote-choice "abstain")
                           (+ (get votes-abstain proposal-data) voting-power)
                           (get votes-abstain proposal-data)))
      (new-total-voters (+ (get total-voters proposal-data) u1))
    )
      (map-set proposals
        { proposal-id: proposal-id }
        (merge proposal-data {
          votes-for: new-votes-for,
          votes-against: new-votes-against,
          votes-abstain: new-votes-abstain,
          total-voters: new-total-voters
        })
      )
    )

    ;; Update user voting history
    (update-voting-history tx-sender)
    (ok true)
  )
)

;; Execute a passed proposal (placeholder for actual execution logic)
(define-public (execute-proposal (proposal-id uint))
  (let (
    (proposal-data (unwrap! (get-proposal proposal-id) ERR-INVALID-PROPOSAL))
    (result (unwrap! (get-proposal-result proposal-id) ERR-INVALID-PROPOSAL))
  )
    (asserts! (is-eq result "passed") ERR-PROPOSAL-NOT-ACTIVE)
    (asserts! (not (get executed proposal-data)) ERR-INVALID-PROPOSAL)
    
    ;; Mark proposal as executed
    (map-set proposals
      { proposal-id: proposal-id }
      (merge proposal-data { executed: true, status: "executed" })
    )
    
    ;; Here would be the actual execution logic based on proposal type
    ;; This is a placeholder that can be extended with specific actions
    (ok true)
  )
)

;; Private functions

;; Get stakeholder voting weight based on type
(define-private (get-stakeholder-voting-weight (stakeholder-type (string-ascii 10)))
  (if (is-eq stakeholder-type "student")
    u1
    (if (is-eq stakeholder-type "faculty")
      u3
      (if (is-eq stakeholder-type "alumni")
        u2
        (if (is-eq stakeholder-type "industry")
          u2
          u1
        )
      )
    )
  )
)

;; Get user token balance (simplified - would integrate with token contract)
(define-private (get-user-token-balance (user principal))
  (match (get-stakeholder-info user)
    stakeholder-data (get token-balance stakeholder-data)
    u0
  )
)

;; Update user voting history
(define-private (update-voting-history (user principal))
  (let (
    (current-history (default-to 
      { total-votes: u0, last-vote-block: u0, participation-score: u0 }
      (map-get? user-voting-history { user: user })
    ))
    (new-total-votes (+ (get total-votes current-history) u1))
    (new-participation-score (+ (get participation-score current-history) u10))
  )
    (map-set user-voting-history
      { user: user }
      {
        total-votes: new-total-votes,
        last-vote-block: stacks-block-height,
        participation-score: new-participation-score
      }
    )
  )
)

;; Initialize contract (called once during deployment)
(define-private (init)
  (begin
    ;; Register contract deployer as initial admin
    (map-set stakeholder-types
      { user: CONTRACT-OWNER }
      {
        stakeholder-type: "admin",
        voting-weight: u5,
        token-balance: u100000,
        registration-block: stacks-block-height
      }
    )
    true
  )
)

;; Call initialization
(init)