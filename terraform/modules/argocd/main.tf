resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = var.chart_version
  namespace        = var.namespace
  create_namespace = true

  # A senha inicial do usuario "admin" e gerada pelo proprio argocd-server no
  # primeiro start e fica no secret "argocd-initial-admin-secret" (ver output
  # argocd_admin_password_command na raiz do projeto).
  values = [
    yamlencode({
      server = {
        service = {
          type = var.server_service_type
        }
      }
    })
  ]
}
