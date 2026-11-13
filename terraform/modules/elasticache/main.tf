resource "aws_security_group" "redis" {
  name_prefix = "${var.project_name}-redis-"
  description = "Permite Redis (6379) a partir da VPC"
  vpc_id      = var.vpc_id

  ingress {
    description = "Redis a partir da VPC"
    from_port   = 6379
    to_port     = 6379
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-redis-sg"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# Replica o ElastiCache Serverless (Redis) usado manualmente na Fase 2 -
# nao exige dimensionar nodes, apenas um teto de uso.
resource "aws_elasticache_serverless_cache" "this" {
  engine = "redis"
  name   = var.cache_name

  cache_usage_limits {
    data_storage {
      maximum = var.max_storage_gb
      unit    = "GB"
    }
    ecpu_per_second {
      maximum = var.max_ecpu_per_second
    }
  }

  subnet_ids         = var.subnet_ids
  security_group_ids = [aws_security_group.redis.id]

  tags = {
    Name = var.cache_name
  }
}
