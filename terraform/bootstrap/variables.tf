variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "project_name" {
  type    = string
  default = "fiap-fase4"
}

variable "bucket_name" {
  description = "Nome do bucket S3 para o state remoto. Se null, gera um nome unico a partir do Account ID (nomes de bucket sao globais entre TODAS as contas AWS - um nome fixo como \"fiap-fase4-tfstate\" pode ja pertencer a outra conta)."
  type        = string
  default     = null
}
