;; Client Communication Contract
;; Manages secure client-investigator messaging and case communications

;; Constants
(define-constant CONTRACT-OWNER tx-sender)
(define-constant ERR-NOT-AUTHORIZED (err u300))
(define-constant ERR-MESSAGE-NOT-FOUND (err u301))
(define-constant ERR-INVALID-INPUT (err u302))
(define-constant ERR-CONVERSATION-NOT-FOUND (err u303))
(define-constant ERR-MESSAGE-TOO-LONG (err u304))
(define-constant ERR-INVALID-PRIORITY (err u305))
(define-constant ERR-CASE-NOT-FOUND (err u306))

;; Data Variables
(define-data-var next-message-id uint u1)
(define-data-var next-conversation-id uint u1)

;; Data Maps
(define-map conversations
  uint
  {
    case-id: uint,
    client: principal,
    investigator: principal,
    created-timestamp: uint,
    last-activity: uint,
    status: (string-ascii 20),
    subject: (string-ascii 100),
    message-count: uint
  }
)

(define-map messages
  uint
  {
    conversation-id: uint,
    sender: principal,
    recipient: principal,
    message-hash: (buff 32),
    timestamp: uint,
    message-type: (string-ascii 20),
    priority: uint,
    read-status: bool,
    encrypted: bool
  }
)

(define-map message-content
  uint
  {
    content: (string-ascii 1000),
    attachments: (list 5 (string-ascii 100)),
    metadata: (string-ascii 200)
  }
)

(define-map case-notifications
  {case-id: uint, notification-id: uint}
  {
    recipient: principal,
    notification-type: (string-ascii 50),
    title: (string-ascii 100),
    content: (string-ascii 300),
    timestamp: uint,
    read: bool,
    priority: uint
  }
)

(define-map notification-count uint uint)

(define-map authorized-clients principal bool)
(define-map authorized-investigators principal bool)

(define-map conversation-participants
  {conversation-id: uint, participant: principal}
  bool
)

(define-map read-receipts
  {message-id: uint, reader: principal}
  uint
)

;; Authorization Functions
(define-private (is-client-authorized (user principal))
  (default-to false (map-get? authorized-clients user))
)

(define-private (is-investigator-authorized (user principal))
  (or
    (is-eq user CONTRACT-OWNER)
    (default-to false (map-get? authorized-investigators user))
  )
)

(define-private (is-conversation-participant (conversation-id uint) (user principal))
  (default-to false (map-get? conversation-participants {conversation-id: conversation-id, participant: user}))
)

(define-public (add-authorized-client (client principal))
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
    (ok (map-set authorized-clients client true))
  )
)

(define-public (add-authorized-investigator (investigator principal))
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
    (ok (map-set authorized-investigators investigator true))
  )
)

;; Conversation Management
(define-public (create-conversation
  (case-id uint)
  (client principal)
  (investigator principal)
  (subject (string-ascii 100))
)
  (let ((conversation-id (var-get next-conversation-id)))
    (asserts! (or (is-investigator-authorized tx-sender) (is-eq tx-sender client)) ERR-NOT-AUTHORIZED)
    (asserts! (> (len subject) u0) ERR-INVALID-INPUT)
    (asserts! (is-client-authorized client) ERR-NOT-AUTHORIZED)
    (asserts! (is-investigator-authorized investigator) ERR-NOT-AUTHORIZED)

    (map-set conversations conversation-id {
      case-id: case-id,
      client: client,
      investigator: investigator,
      created-timestamp: block-height,
      last-activity: block-height,
      status: "active",
      subject: subject,
      message-count: u0
    })

    ;; Add participants
    (map-set conversation-participants {conversation-id: conversation-id, participant: client} true)
    (map-set conversation-participants {conversation-id: conversation-id, participant: investigator} true)

    (var-set next-conversation-id (+ conversation-id u1))
    (ok conversation-id)
  )
)

(define-public (update-conversation-status (conversation-id uint) (new-status (string-ascii 20)))
  (let ((conversation (unwrap! (map-get? conversations conversation-id) ERR-CONVERSATION-NOT-FOUND)))
    (asserts! (is-conversation-participant conversation-id tx-sender) ERR-NOT-AUTHORIZED)
    (asserts! (or
      (is-eq new-status "active")
      (is-eq new-status "closed")
      (is-eq new-status "archived")
      (is-eq new-status "escalated")
    ) ERR-INVALID-INPUT)

    (ok (map-set conversations conversation-id (merge conversation {status: new-status})))
  )
)

;; Message Management
(define-public (send-message
  (conversation-id uint)
  (recipient principal)
  (content (string-ascii 1000))
  (message-type (string-ascii 20))
  (priority uint)
  (encrypted bool)
)
  (let (
    (message-id (var-get next-message-id))
    (conversation (unwrap! (map-get? conversations conversation-id) ERR-CONVERSATION-NOT-FOUND))
    (content-hash (keccak256 (concat (unwrap-panic (to-consensus-buff? content)) (unwrap-panic (to-consensus-buff? block-height)))))
  )
    (asserts! (is-conversation-participant conversation-id tx-sender) ERR-NOT-AUTHORIZED)
    (asserts! (is-conversation-participant conversation-id recipient) ERR-NOT-AUTHORIZED)
    (asserts! (> (len content) u0) ERR-INVALID-INPUT)
    (asserts! (<= (len content) u1000) ERR-MESSAGE-TOO-LONG)
    (asserts! (and (>= priority u1) (<= priority u5)) ERR-INVALID-PRIORITY)

    ;; Store message metadata
    (map-set messages message-id {
      conversation-id: conversation-id,
      sender: tx-sender,
      recipient: recipient,
      message-hash: content-hash,
      timestamp: block-height,
      message-type: message-type,
      priority: priority,
      read-status: false,
      encrypted: encrypted
    })

    ;; Store message content
    (map-set message-content message-id {
      content: content,
      attachments: (list),
      metadata: ""
    })

    ;; Update conversation
    (map-set conversations conversation-id (merge conversation {
      last-activity: block-height,
      message-count: (+ (get message-count conversation) u1)
    }))

    (var-set next-message-id (+ message-id u1))
    (ok message-id)
  )
)

(define-public (mark-message-read (message-id uint))
  (let ((message (unwrap! (map-get? messages message-id) ERR-MESSAGE-NOT-FOUND)))
    (asserts! (is-eq tx-sender (get recipient message)) ERR-NOT-AUTHORIZED)

    (map-set messages message-id (merge message {read-status: true}))
    (map-set read-receipts {message-id: message-id, reader: tx-sender} block-height)
    (ok true)
  )
)

(define-public (add-message-attachment (message-id uint) (attachment-hash (string-ascii 100)))
  (let (
    (message (unwrap! (map-get? messages message-id) ERR-MESSAGE-NOT-FOUND))
    (content (unwrap! (map-get? message-content message-id) ERR-MESSAGE-NOT-FOUND))
  )
    (asserts! (is-eq tx-sender (get sender message)) ERR-NOT-AUTHORIZED)
    (asserts! (> (len attachment-hash) u0) ERR-INVALID-INPUT)

    (ok (map-set message-content message-id (merge content {
      attachments: (unwrap! (as-max-len? (append (get attachments content) attachment-hash) u5) ERR-INVALID-INPUT)
    })))
  )
)

;; Notification System
(define-public (send-case-notification
  (case-id uint)
  (recipient principal)
  (notification-type (string-ascii 50))
  (title (string-ascii 100))
  (content (string-ascii 300))
  (priority uint)
)
  (let ((current-count (default-to u0 (map-get? notification-count case-id))))
    (asserts! (is-investigator-authorized tx-sender) ERR-NOT-AUTHORIZED)
    (asserts! (> (len title) u0) ERR-INVALID-INPUT)
    (asserts! (and (>= priority u1) (<= priority u5)) ERR-INVALID-PRIORITY)

    (map-set case-notifications {case-id: case-id, notification-id: current-count} {
      recipient: recipient,
      notification-type: notification-type,
      title: title,
      content: content,
      timestamp: block-height,
      read: false,
      priority: priority
    })
    (map-set notification-count case-id (+ current-count u1))
    (ok current-count)
  )
)

(define-public (mark-notification-read (case-id uint) (notification-id uint))
  (let ((notification (unwrap! (map-get? case-notifications {case-id: case-id, notification-id: notification-id}) ERR-MESSAGE-NOT-FOUND)))
    (asserts! (is-eq tx-sender (get recipient notification)) ERR-NOT-AUTHORIZED)

    (ok (map-set case-notifications {case-id: case-id, notification-id: notification-id}
      (merge notification {read: true})))
  )
)

;; Read-only Functions
(define-read-only (get-conversation (conversation-id uint))
  (map-get? conversations conversation-id)
)

(define-read-only (get-message (message-id uint))
  (map-get? messages message-id)
)

(define-read-only (get-message-content (message-id uint))
  (map-get? message-content message-id)
)

(define-read-only (get-case-notification (case-id uint) (notification-id uint))
  (map-get? case-notifications {case-id: case-id, notification-id: notification-id})
)

(define-read-only (get-notification-count (case-id uint))
  (default-to u0 (map-get? notification-count case-id))
)

(define-read-only (is-participant (conversation-id uint) (user principal))
  (is-conversation-participant conversation-id user)
)

(define-read-only (get-read-receipt (message-id uint) (reader principal))
  (map-get? read-receipts {message-id: message-id, reader: reader})
)

(define-read-only (get-next-message-id)
  (var-get next-message-id)
)

(define-read-only (get-next-conversation-id)
  (var-get next-conversation-id)
)

;; Message verification
(define-read-only (verify-message-hash (message-id uint) (provided-hash (buff 32)))
  (match (map-get? messages message-id)
    message (is-eq (get message-hash message) provided-hash)
    false
  )
)

(define-read-only (get-unread-message-count (conversation-id uint) (user principal))
  ;; Simplified implementation - would need to iterate through messages
  (some u0)
)
