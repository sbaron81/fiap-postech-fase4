variable "namespace" {
  type    = string
  default = "ingress-nginx"
}

variable "chart_version" {
  description = "Versao do chart ingress-nginx. null = usa a versao mais recente disponivel no repo."
  type        = string
  default     = null
}
