terraform {
  # use_lockfile no backend "s3" exige Terraform >= 1.10.
  required_version = ">= 1.10.0"

  # Configuracao parcial de proposito: valores reais (nome do bucket, etc.)
  # vem de backend.hcl, que e especifico de cada conta/aluno e nao vai pro git.
  # terraform init -backend-config=backend.hcl
  backend "s3" {}

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.14"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# Autentica no cluster que o modulo eks acabou de criar, usando um token de
# curta duracao (sts) - equivalente ao "aws eks get-token" da CLI.
data "aws_eks_cluster_auth" "this" {
  name = module.eks.cluster_name
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
    token                  = data.aws_eks_cluster_auth.this.token
  }
}
