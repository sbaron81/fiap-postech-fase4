variable "queue_name" {
  type    = string
  default = "fiap-fase4-toggle-events"
}

variable "visibility_timeout_seconds" {
  type    = number
  default = 30
}

variable "message_retention_seconds" {
  description = "Padrao de 4 dias"
  type        = number
  default     = 345600
}
