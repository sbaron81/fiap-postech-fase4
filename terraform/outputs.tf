output "vpc_id" {
  value = module.networking.vpc_id
}

output "public_subnet_ids" {
  value = module.networking.public_subnet_ids
}

output "private_subnet_ids" {
  value = module.networking.private_subnet_ids
}

output "ecr_repository_urls" {
  value = module.ecr.repository_urls
}

output "eks_cluster_name" {
  value = module.eks.cluster_name
}

output "eks_cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "configure_kubectl" {
  value = "aws eks update-kubeconfig --region ${var.aws_region} --name ${module.eks.cluster_name}"
}

output "rds_endpoints" {
  value = module.rds.endpoints
}

output "rds_database_urls" {
  value     = module.rds.database_urls
  sensitive = true
}

output "elasticache_redis_url" {
  value = module.elasticache.redis_url
}

output "dynamodb_table_name" {
  value = module.dynamodb.table_name
}

output "sqs_queue_url" {
  value = module.sqs.queue_url
}

output "argocd_get_admin_password" {
  value = "kubectl -n ${module.argocd.namespace} get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo"
}

output "argocd_get_server_address" {
  value = "kubectl -n ${module.argocd.namespace} get svc argocd-server -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'; echo"
}

output "ingress_get_address" {
  value = "kubectl -n ${module.ingress_nginx.namespace} get svc ${module.ingress_nginx.service_name} -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'; echo"
}

output "github_actions_variables" {
  description = "Variables (Settings > Secrets and variables > Actions > Variables) a configurar em cada repositorio de servico"
  value = {
    for svc in var.services : svc => {
      AWS_REGION                                                     = var.aws_region
      "ECR_${upper(replace(trimsuffix(svc, "-service"), "-", "_"))}" = module.ecr.repository_urls[local.ecr_repository_names[svc]]
    }
  }
}

output "argocd_applications" {
  value = var.enable_argocd_apps ? module.argocd_apps[0].applications : []
}
