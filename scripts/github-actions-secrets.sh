#!/usr/bin/env bash
# Passo 5 do SETUP.md: cadastra os secrets e variables do GitHub Actions
# nos 5 repositorios de servico.
#
# Pre-requisitos: gh autenticado (gh auth status), terraform, jq e
# AWS_PROFILE apontando para a conta onde o terraform foi aplicado.
#
# Uso (a partir da raiz deste repositorio):
#   ./scripts/github-actions-secrets.sh
#
# Os 3 secrets sao pedidos no terminal (sem eco) para nao irem para o
# historico do shell. Tambem podem vir por variavel de ambiente:
#   AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, GITOPS_TOKEN
set -euo pipefail

OWNER="${GITHUB_OWNER:-sbaron81}"
SERVICES=(auth-service flag-service targeting-service evaluation-service analytics-service)
TF_DIR="$(cd "$(dirname "$0")/../terraform" && pwd)"

prompt_secret() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    read -rsp "$name: " "$name"
    echo
  fi
  [[ -n "${!name}" ]] || { echo "ERRO: $name vazio" >&2; exit 1; }
}

echo "Access key do usuario IAM github-actions e PAT do fiap-gitops:"
prompt_secret AWS_ACCESS_KEY_ID
prompt_secret AWS_SECRET_ACCESS_KEY
prompt_secret GITOPS_TOKEN

# {"auth-service": {"AWS_REGION": "...", "ECR_AUTH": "..."}, ...}
VARS_JSON="$(terraform -chdir="$TF_DIR" output -json github_actions_variables)"

for svc in "${SERVICES[@]}"; do
  repo="$OWNER/$svc"
  echo "== $repo"

  # valor via stdin (e nao --body) para nao aparecer na lista de processos
  printf '%s' "$AWS_ACCESS_KEY_ID"     | gh secret set AWS_ACCESS_KEY_ID     --repo "$repo"
  printf '%s' "$AWS_SECRET_ACCESS_KEY" | gh secret set AWS_SECRET_ACCESS_KEY --repo "$repo"
  printf '%s' "$GITOPS_TOKEN"          | gh secret set GITOPS_TOKEN          --repo "$repo"

  # AWS_REGION e ECR_<SERVICO>, direto do output do terraform
  jq -r --arg s "$svc" '.[$s] | to_entries[] | "\(.key)\t\(.value)"' <<<"$VARS_JSON" |
    while IFS=$'\t' read -r key value; do
      gh variable set "$key" --repo "$repo" --body "$value"
    done
done

echo
echo "Conferindo:"
for svc in "${SERVICES[@]}"; do
  repo="$OWNER/$svc"
  echo "== $repo"
  gh secret list   --repo "$repo"
  gh variable list --repo "$repo"
done
