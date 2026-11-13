# hash_key "event_id" corresponde exatamente ao item gravado pelo
# analytics-service (put_item com event_id = str(uuid.uuid4())).
resource "aws_dynamodb_table" "this" {
  name         = var.table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "event_id"

  attribute {
    name = "event_id"
    type = "S"
  }

  tags = {
    Name = var.table_name
  }
}
