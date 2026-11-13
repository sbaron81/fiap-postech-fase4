# Controller compartilhado por todos os servicos (um unico LB, roteamento
# por path).
#
# NAO usamos annotations do tipo "aws-load-balancer-type: external" (como a
# Fase 2 fazia) porque essas sao especificas do AWS Load Balancer Controller
# - um controller separado que a Fase 2 instalava via eksctl e que NAO existe
# aqui. Sem ele, o Service type=LoadBalancer nunca recebe endereco (nenhum
# controller satisfaz a annotation) e o `helm_release` trava esperando o LB
# ficar pronto ate estourar o timeout.
#
# Deixando sem annotation nenhuma, o Service e provisionado pelo provider
# in-tree do proprio control plane do EKS - o mesmo mecanismo que ja expoe o
# argocd-server como LoadBalancer sem precisar de controller extra.
resource "helm_release" "ingress_nginx" {
  name             = "ingress-nginx"
  repository       = "https://kubernetes.github.io/ingress-nginx"
  chart            = "ingress-nginx"
  version          = var.chart_version
  namespace        = var.namespace
  create_namespace = true
  timeout          = 600

  values = [
    yamlencode({
      controller = {
        service = {
          type = "LoadBalancer"
        }
      }
    })
  ]
}
