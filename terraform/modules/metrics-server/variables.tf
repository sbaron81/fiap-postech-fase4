variable "namespace" {
  type    = string
  default = "kube-system"
}

variable "chart_version" {
  description = "Versao do chart metrics-server. null = usa a versao mais recente disponivel no repo."
  type        = string
  default     = null
}
