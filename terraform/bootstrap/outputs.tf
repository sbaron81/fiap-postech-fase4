output "bucket_name" {
  value = aws_s3_bucket.state.bucket
}

output "bucket_arn" {
  value = aws_s3_bucket.state.arn
}

output "backend_config" {
  description = "Copie estes valores para ../backend.hcl"
  value = {
    bucket       = aws_s3_bucket.state.bucket
    key          = "fiap-fase4/terraform.tfstate"
    region       = var.aws_region
    use_lockfile = true
    encrypt      = true
  }
}
