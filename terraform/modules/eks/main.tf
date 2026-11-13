# Em conta pessoal (fora do AWS Academy) o Terraform cria suas proprias IAM
# roles para o control plane e para os nodes. Se algum dia voltar a rodar em
# um Academy Learner Lab (onde nao e possivel criar IAM roles), basta setar
# use_lab_role = true para reusar a "LabRole" ja existente na conta.
data "aws_iam_role" "lab_role" {
  count = var.use_lab_role ? 1 : 0
  name  = var.lab_role_name
}

data "aws_iam_policy_document" "eks_cluster_assume" {
  count = var.use_lab_role ? 0 : 1

  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "cluster" {
  count              = var.use_lab_role ? 0 : 1
  name               = "${var.cluster_name}-eks-cluster-role"
  assume_role_policy = data.aws_iam_policy_document.eks_cluster_assume[0].json
}

resource "aws_iam_role_policy_attachment" "cluster_policy" {
  count      = var.use_lab_role ? 0 : 1
  role       = aws_iam_role.cluster[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

data "aws_iam_policy_document" "eks_node_assume" {
  count = var.use_lab_role ? 0 : 1

  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "node" {
  count              = var.use_lab_role ? 0 : 1
  name               = "${var.cluster_name}-eks-node-role"
  assume_role_policy = data.aws_iam_policy_document.eks_node_assume[0].json
}

resource "aws_iam_role_policy_attachment" "node_worker" {
  count      = var.use_lab_role ? 0 : 1
  role       = aws_iam_role.node[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "node_cni" {
  count      = var.use_lab_role ? 0 : 1
  role       = aws_iam_role.node[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "node_ecr" {
  count      = var.use_lab_role ? 0 : 1
  role       = aws_iam_role.node[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

# Paridade com a Fase 2: la, o NodeInstanceRole tinha AmazonSQSFullAccess
# anexada diretamente (comentario em eks/analytics-service/scaledobject.yaml),
# pois evaluation-service e analytics-service acessam SQS/DynamoDB a partir
# do pod usando as credenciais do instance profile do node (sem IRSA).
resource "aws_iam_role_policy_attachment" "node_sqs" {
  count      = var.use_lab_role ? 0 : 1
  role       = aws_iam_role.node[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSQSFullAccess"
}

resource "aws_iam_role_policy_attachment" "node_dynamodb" {
  count      = var.use_lab_role ? 0 : 1
  role       = aws_iam_role.node[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonDynamoDBFullAccess"
}

locals {
  cluster_role_arn = var.use_lab_role ? data.aws_iam_role.lab_role[0].arn : aws_iam_role.cluster[0].arn
  node_role_arn    = var.use_lab_role ? data.aws_iam_role.lab_role[0].arn : aws_iam_role.node[0].arn
}

resource "aws_eks_cluster" "this" {
  name     = var.cluster_name
  role_arn = local.cluster_role_arn
  version  = var.kubernetes_version

  vpc_config {
    subnet_ids              = var.cluster_subnet_ids
    endpoint_public_access  = var.endpoint_public_access
    endpoint_private_access = true
  }

  depends_on = [aws_iam_role_policy_attachment.cluster_policy]
}

resource "aws_eks_node_group" "default" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "${var.cluster_name}-default"
  node_role_arn   = local.node_role_arn
  subnet_ids      = var.node_subnet_ids

  instance_types = var.node_instance_types
  disk_size      = var.node_disk_size
  capacity_type  = "ON_DEMAND"

  scaling_config {
    desired_size = var.node_desired_size
    min_size     = var.node_min_size
    max_size     = var.node_max_size
  }

  update_config {
    max_unavailable = 1
  }

  # O EKS gerencia o ciclo de vida do Auto Scaling Group internamente;
  # ignorar mudancas de desired_size feitas por HPA/Cluster Autoscaler fora do Terraform.
  lifecycle {
    ignore_changes = [scaling_config[0].desired_size]
  }

  depends_on = [
    aws_iam_role_policy_attachment.node_worker,
    aws_iam_role_policy_attachment.node_cni,
    aws_iam_role_policy_attachment.node_ecr,
  ]
}
