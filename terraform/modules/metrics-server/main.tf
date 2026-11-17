# O EKS nao instala o metrics-server por padrao. Sem ele a API
# metrics.k8s.io nao existe e os triggers `cpu`/`memory` do KEDA (que viram
# um HPA com metrica de Resource) ficam sem dados - o HPA mostra
# "<unknown>/70%" e nunca escala.
resource "helm_release" "metrics_server" {
  name             = "metrics-server"
  repository       = "https://kubernetes-sigs.github.io/metrics-server/"
  chart            = "metrics-server"
  version          = var.chart_version
  namespace        = var.namespace
  create_namespace = false
}
