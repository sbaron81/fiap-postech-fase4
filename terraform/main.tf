data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, 2)

  # Nome do repositorio ECR de cada servico. Os manifests do fiap-gitops e os
  # workflows de cada repositorio de servico usam esse mesmo padrao.
  ecr_repository_names = { for svc in var.services : svc => "${var.ecr_prefix}/${svc}" }
}

module "networking" {
  source = "./modules/networking"

  project_name       = var.project_name
  cluster_name       = var.cluster_name
  azs                = local.azs
  enable_nat_gateway = var.enable_nat_gateway
}

module "ecr" {
  source = "./modules/ecr"

  repository_names = values(local.ecr_repository_names)
}

module "eks" {
  source = "./modules/eks"

  cluster_name        = var.cluster_name
  kubernetes_version  = var.kubernetes_version
  use_lab_role        = var.use_lab_role
  cluster_subnet_ids  = concat(module.networking.public_subnet_ids, module.networking.private_subnet_ids)
  node_subnet_ids     = module.networking.private_subnet_ids
  node_instance_types = var.node_instance_types
  node_desired_size   = var.node_desired_size
  node_min_size       = var.node_min_size
  node_max_size       = var.node_max_size
}

module "rds" {
  source = "./modules/rds"

  project_name = var.project_name
  vpc_id       = module.networking.vpc_id
  vpc_cidr     = module.networking.vpc_cidr
  subnet_ids   = module.networking.private_subnet_ids
}

module "elasticache" {
  source = "./modules/elasticache"

  project_name = var.project_name
  vpc_id       = module.networking.vpc_id
  vpc_cidr     = module.networking.vpc_cidr
  subnet_ids   = module.networking.private_subnet_ids
  cache_name   = var.elasticache_name
}

module "dynamodb" {
  source = "./modules/dynamodb"

  table_name = var.dynamodb_table_name
}

module "sqs" {
  source = "./modules/sqs"

  queue_name = var.sqs_queue_name
}

module "argocd" {
  source = "./modules/argocd"

  namespace           = var.argocd_namespace
  chart_version       = var.argocd_chart_version
  server_service_type = var.argocd_server_service_type

  # O node group precisa existir (nodes Ready) antes de instalar o chart,
  # senao os pods do argocd ficam Pending indefinidamente.
  depends_on = [module.eks]
}

module "keda" {
  source = "./modules/keda"

  namespace     = var.keda_namespace
  chart_version = var.keda_chart_version

  depends_on = [module.eks]
}

module "ingress_nginx" {
  source = "./modules/ingress-nginx"

  namespace     = var.ingress_nginx_namespace
  chart_version = var.ingress_nginx_chart_version

  depends_on = [module.eks]
}

# Cada microsservico agora vive no seu proprio repositorio, e os manifests
# Kustomize ficam centralizados no fiap-gitops. Este modulo cria as
# Applications do ArgoCD apontando para esse repositorio (o fiap-gitops tem
# so os manifests Kustomize, sem Application).
module "argocd_apps" {
  source = "./modules/argocd-apps"
  count  = var.enable_argocd_apps ? 1 : 0

  argocd_namespace       = module.argocd.namespace
  chart_version          = var.argocd_apps_chart_version
  gitops_repo_url        = var.gitops_repo_url
  gitops_target_revision = var.gitops_target_revision
  services               = var.services

  depends_on = [module.argocd]
}
