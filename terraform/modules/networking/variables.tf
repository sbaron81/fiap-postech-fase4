variable "project_name" {
  description = "Prefixo usado no nome dos recursos"
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block da VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "azs" {
  description = "Availability zones usadas para as subnets"
  type        = list(string)
}

variable "public_subnet_cidrs" {
  description = "CIDRs das subnets publicas (uma por AZ)"
  type        = list(string)
  default     = ["10.0.0.0/24", "10.0.1.0/24"]
}

variable "private_subnet_cidrs" {
  description = "CIDRs das subnets privadas (uma por AZ)"
  type        = list(string)
  default     = ["10.0.10.0/24", "10.0.11.0/24"]
}

variable "enable_nat_gateway" {
  description = "Se falso, as subnets privadas ficam sem saida para a internet (economiza custo/tempo de criacao)"
  type        = bool
  default     = true
}

variable "cluster_name" {
  description = "Nome do cluster EKS, usado nas tags kubernetes.io/cluster/<nome> exigidas pelo EKS/ALB controller"
  type        = string
}
