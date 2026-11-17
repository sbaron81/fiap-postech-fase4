# Controller do KEDA. Os ScaledObject (keda.sh/v1alpha1) ficam no
# fiap-gitops - hoje so o evaluation-service usa (triggers cpu/memory, que
# dependem do metrics-server). Sem os CRDs no cluster o ArgoCD falha o sync
# com "failed to discover server resources for group version keda.sh/v1alpha1".
resource "helm_release" "keda" {
  name             = "keda"
  repository       = "https://kedacore.github.io/charts"
  chart            = "keda"
  version          = var.chart_version
  namespace        = var.namespace
  create_namespace = true
}
