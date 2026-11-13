# Os ScaledObject do evaluation-service e analytics-service (SQS-driven)
# exigem os CRDs do KEDA (keda.sh/v1alpha1) no cluster - sem isso o ArgoCD
# falha o sync com "failed to discover server resources for group version
# keda.sh/v1alpha1".
resource "helm_release" "keda" {
  name             = "keda"
  repository       = "https://kedacore.github.io/charts"
  chart            = "keda"
  version          = var.chart_version
  namespace        = var.namespace
  create_namespace = true
}
