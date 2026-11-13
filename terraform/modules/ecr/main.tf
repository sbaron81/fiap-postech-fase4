resource "aws_ecr_repository" "this" {
  for_each = toset(var.repository_names)

  name                 = each.value
  image_tag_mutability = "MUTABLE"
  # force_delete permite "terraform destroy" mesmo com imagens publicadas,
  # util em laboratorio (AWS Academy) onde o ambiente e recriado com frequencia.
  force_delete = true

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = {
    Name = each.value
  }
}
