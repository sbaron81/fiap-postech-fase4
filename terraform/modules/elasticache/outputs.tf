output "endpoint" {
  value = aws_elasticache_serverless_cache.this.endpoint[0].address
}

output "port" {
  value = aws_elasticache_serverless_cache.this.endpoint[0].port
}

output "redis_url" {
  # ElastiCache Serverless forca encryption in-transit (nao da pra desligar) -
  # "rediss://" (TLS) e obrigatorio aqui, "redis://" simples nao conecta.
  value = "rediss://${aws_elasticache_serverless_cache.this.endpoint[0].address}:${aws_elasticache_serverless_cache.this.endpoint[0].port}"
}

output "security_group_id" {
  value = aws_security_group.redis.id
}
