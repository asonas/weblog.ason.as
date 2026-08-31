variable "aws_region" {
  description = "AWS Region for production resources."
  type        = string
  default     = "ap-northeast-1"
}

variable "webmention_receiver_enabled" {
  description = "Accept new Webmention notifications at the public receiver."
  type        = bool
  default     = false
}

variable "webmention_verification_enabled" {
  description = "Consume queued Webmention verification and delivery jobs."
  type        = bool
  default     = false
}

variable "webmention_publisher_enabled" {
  description = "Publish verifiable static article snapshots from saved-page outboxes."
  type        = bool
  default     = false
}

variable "webmention_sender_enabled" {
  description = "Release outbound Webmention delivery jobs after publishing article snapshots."
  type        = bool
  default     = false
}

variable "inbox_alerting_enabled" {
  description = "Send inbox synchronization alarm and recovery notifications."
  type        = bool
  default     = false
}

variable "inbox_alert_email" {
  description = "Optional email address subscribed to inbox synchronization alerts."
  type        = string
  default     = ""
}
