MASTER_KEY='<sua master key>'

# 1. Cria uma API key (o valor só aparece nesta resposta)
KEY=$(curl -s -X POST http://$LB/auth/admin/keys -H "Authorization: Bearer $MASTER_KEY" \
  -H "Content-Type: application/json" -d '{"name":"teste-manual"}' | python3 -c "import sys,json;print(json.load(sys.stdin)['key'])")

# 2. Cria uma flag e uma regra de 50% de rollout
curl -s -X POST http://$LB/flags/flags -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
  -d '{"name":"teste-obs","description":"validação","is_enabled":true}'
curl -s -X POST http://$LB/targeting/rules -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
  -d '{"flag_name":"teste-obs","is_enabled":true,"rules":{"type":"PERCENTAGE","value":50}}'

# 3. Avalia para vários usuários: deve vir um mix de true e false
for u in 1 2 3 4 5 6; do curl -s "http://$LB/evaluate/evaluate?user_id=user-$u&flag_name=teste-obs"; echo; done

# 4. Confirma que o analytics consumiu os eventos e gravou no DynamoDB
kubectl -n analytics-service logs deploy/analytics-service --tail=20 | grep "salvo no DynamoDB"