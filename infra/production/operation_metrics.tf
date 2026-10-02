variable "operation_metrics_until" {
  description = "Unix timestamp after which sampled operation logs stop automatically; zero disables collection."
  type        = number
  default     = 0
  validation {
    condition     = var.operation_metrics_until >= 0
    error_message = "The expiry timestamp must be non-negative."
  }
}

locals {
  operation_metrics_environment = {
    OPERATION_METRICS_SAMPLE_RATE = "0.1"
    OPERATION_METRICS_UNTIL       = tostring(var.operation_metrics_until)
  }
}
