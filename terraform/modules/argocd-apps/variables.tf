variable "argocd_namespace" {
  type    = string
  default = "argocd"
}

variable "chart_version" {
  description = "Versao do chart argocd-apps (>= 2.0, onde 'applications' e um mapa). null = usa a mais recente."
  type        = string
  default     = null
}

variable "gitops_repo_url" {
  description = "Repositorio Git com os manifests Kustomize dos servicos"
  type        = string
}

variable "gitops_target_revision" {
  description = "Branch/tag/commit do repositorio GitOps que o ArgoCD acompanha"
  type        = string
  default     = "HEAD"
}

variable "services" {
  description = "Servicos com diretorio <servico>/overlays/production no repositorio GitOps"
  type        = list(string)
}
