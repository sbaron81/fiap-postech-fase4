variable "repository_names" {
  description = "Nomes dos repositorios ECR a criar, um por microsservico"
  type        = list(string)
  default = [
    "fiap/auth-service",
    "fiap/flag-service",
    "fiap/targeting-service",
    "fiap/evaluation-service",
    "fiap/analytics-service",
  ]
}
