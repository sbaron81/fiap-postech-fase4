variable "project_name" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "vpc_cidr" {
  type = string
}

variable "subnet_ids" {
  description = "Subnets privadas usadas pelo cache"
  type        = list(string)
}

variable "cache_name" {
  type    = string
  default = "evaluation-service"
}

variable "max_storage_gb" {
  description = "Limite maximo de armazenamento de dados (GB) do Redis serverless"
  type        = number
  default     = 2
}

variable "max_ecpu_per_second" {
  description = "Limite maximo de ECPUs/segundo do Redis serverless"
  type        = number
  default     = 5000
}
