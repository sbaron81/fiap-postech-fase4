variable "project_name" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "vpc_cidr" {
  type = string
}

variable "subnet_ids" {
  description = "Subnets privadas usadas pelo DB subnet group"
  type        = list(string)
}

variable "databases" {
  description = "Uma instancia RDS Postgres por chave do mapa"
  type = map(object({
    db_name           = string
    instance_class    = optional(string, "db.t3.micro")
    allocated_storage = optional(number, 20)
    engine_version    = optional(string, "15")
    username          = optional(string, "postgres")
  }))
  default = {
    auth-service = {
      db_name = "auth_db"
    }
    flag-service = {
      db_name = "flags_db"
    }
    targeting-service = {
      db_name = "targeting_db"
    }
  }
}
