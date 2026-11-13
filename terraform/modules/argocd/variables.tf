variable "namespace" {
  type    = string
  default = "argocd"
}

variable "chart_version" {
  description = "Versao do chart argo-cd. null = usa a versao mais recente disponivel no repo (mesmo raciocinio do kubernetes_version do EKS: evita fixar uma versao que fica desatualizada/removida)."
  type        = string
  default     = null
}

variable "server_service_type" {
  description = "Tipo do Service do argocd-server. LoadBalancer cria uma ELB publica automaticamente (as subnets publicas ja estao tagueadas para isso)."
  type        = string
  default     = "LoadBalancer"
}
