variable "namespace" {
  type    = string
  default = "keda"
}

variable "chart_version" {
  description = "Versao do chart keda. null = usa a versao mais recente disponivel no repo."
  type        = string
  default     = null
}
