# Registra no ArgoCD uma Application por microsservico, todas apontando para
# o repositorio de manifests (fiap-gitops). Usa o chart oficial "argocd-apps"
# em vez de kubernetes_manifest porque o CRD "Application" so existe depois
# que o chart argo-cd e instalado - kubernetes_manifest exigiria o CRD ja no
# "terraform plan" e quebraria o primeiro apply.
resource "helm_release" "argocd_apps" {
  name       = "argocd-apps"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argocd-apps"
  version    = var.chart_version
  namespace  = var.argocd_namespace

  values = [
    yamlencode({
      applications = {
        for svc in var.services : svc => {
          namespace        = var.argocd_namespace
          additionalLabels = { app = svc }
          finalizers       = ["resources-finalizer.argocd.argoproj.io"]
          project          = "default"

          source = {
            repoURL        = var.gitops_repo_url
            targetRevision = var.gitops_target_revision
            path           = "${svc}/overlays/production"
          }

          destination = {
            server    = "https://kubernetes.default.svc"
            namespace = svc
          }

          syncPolicy = {
            automated = {
              prune      = true
              selfHeal   = true
              allowEmpty = false
            }
            syncOptions = [
              "CreateNamespace=true",
              "PrunePropagationPolicy=foreground",
              "PruneLast=true",
            ]
            retry = {
              limit = 5
              backoff = {
                duration    = "5s"
                factor      = 2
                maxDuration = "3m"
              }
            }
          }

          revisionHistoryLimit = 3
        }
      }
    })
  ]
}
