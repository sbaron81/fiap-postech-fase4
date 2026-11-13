output "cluster_name" {
  value = aws_eks_cluster.this.name
}

output "cluster_endpoint" {
  value = aws_eks_cluster.this.endpoint
}

output "cluster_certificate_authority_data" {
  value = aws_eks_cluster.this.certificate_authority[0].data
}

output "cluster_security_group_id" {
  value = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
}

output "node_group_status" {
  value = aws_eks_node_group.default.status
}

output "cluster_role_arn" {
  value = local.cluster_role_arn
}

output "node_role_arn" {
  value = local.node_role_arn
}
