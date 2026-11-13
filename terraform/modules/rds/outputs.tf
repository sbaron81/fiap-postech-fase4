output "endpoints" {
  description = "Mapa nome-do-servico => endpoint host:port"
  value       = { for name, db in aws_db_instance.this : name => db.endpoint }
}

output "database_names" {
  value = { for name, db in aws_db_instance.this : name => db.db_name }
}

output "usernames" {
  value = { for name, db in aws_db_instance.this : name => db.username }
}

output "passwords" {
  description = "Mapa nome-do-servico => senha gerada (sensivel)"
  value       = { for name, pw in random_password.this : name => pw.result }
  sensitive   = true
}

output "database_urls" {
  description = "Mapa nome-do-servico => postgres:// connection string pronta para DATABASE_URL (sensivel)"
  value = {
    for name, db in aws_db_instance.this :
    name => "postgres://${db.username}:${random_password.this[name].result}@${db.endpoint}/${db.db_name}"
  }
  sensitive = true
}

output "security_group_id" {
  value = aws_security_group.rds.id
}
