variable "authoring_maintenance" {
  description = "Reject authoring Lambda requests before opening the database during schema maintenance."
  type        = bool
  default     = false
}
