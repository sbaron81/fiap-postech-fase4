variable "cluster_name" {
  type = string
}

variable "kubernetes_version" {
  description = "Versao do Kubernetes para o control plane do EKS. null (padrao) = deixa a AWS escolher a versao estavel mais recente disponivel, evitando fixar uma versao que a AWS acaba descontinuando."
  type        = string
  default     = null
}

variable "use_lab_role" {
  description = "Se true, reusa uma IAM role ja existente (ex.: LabRole do AWS Academy) em vez de criar IAM roles novas. Use false (padrao) em conta pessoal."
  type        = bool
  default     = false
}

variable "lab_role_name" {
  description = "Nome da IAM role fixa a reusar quando use_lab_role = true (ex.: AWS Academy Learner Lab)"
  type        = string
  default     = "LabRole"
}

variable "cluster_subnet_ids" {
  description = "Subnets (publicas + privadas) associadas ao control plane do EKS"
  type        = list(string)
}

variable "node_subnet_ids" {
  description = "Subnets privadas onde os nodes do node group sao provisionados"
  type        = list(string)
}

variable "endpoint_public_access" {
  type    = bool
  default = true
}

variable "node_instance_types" {
  type    = list(string)
  default = ["t3.medium"]
}

variable "node_desired_size" {
  type    = number
  default = 2
}

variable "node_min_size" {
  type    = number
  default = 1
}

variable "node_max_size" {
  type    = number
  default = 4
}

variable "node_disk_size" {
  description = "Tamanho do disco (GB) de cada node"
  type        = number
  default     = 20
}
