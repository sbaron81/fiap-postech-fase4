output "repository_urls" {
  description = "Mapa nome-do-repositorio => URL do repositorio ECR"
  value       = { for name, repo in aws_ecr_repository.this : name => repo.repository_url }
}
