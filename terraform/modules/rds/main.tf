resource "aws_db_subnet_group" "this" {
  name       = "${var.project_name}-rds"
  subnet_ids = var.subnet_ids

  tags = {
    Name = "${var.project_name}-rds-subnet-group"
  }
}

resource "aws_security_group" "rds" {
  name_prefix = "${var.project_name}-rds-"
  description = "Permite Postgres (5432) a partir da VPC"
  vpc_id      = var.vpc_id

  ingress {
    description = "Postgres a partir da VPC"
    from_port   = 5432
    to_port     = 5432
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
    Name = "${var.project_name}-rds-sg"
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "random_password" "this" {
  for_each = var.databases

  length  = 20
  special = false
}

resource "aws_db_instance" "this" {
  for_each = var.databases

  identifier     = "${var.project_name}-${each.key}"
  db_name        = each.value.db_name
  engine         = "postgres"
  engine_version = each.value.engine_version
  instance_class = each.value.instance_class

  allocated_storage     = each.value.allocated_storage
  storage_type          = "gp2"
  max_allocated_storage = 0

  username = each.value.username
  password = random_password.this[each.key].result

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  publicly_accessible    = false

  multi_az                   = false
  backup_retention_period    = 0
  skip_final_snapshot        = true
  deletion_protection        = false
  auto_minor_version_upgrade = true
  apply_immediately          = true

  tags = {
    Name = "${var.project_name}-${each.key}"
  }
}
