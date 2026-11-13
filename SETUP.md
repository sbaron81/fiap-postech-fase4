# Subindo o ambiente do zero (AWS vazia)

Passo a passo para criar toda a infraestrutura do ToggleMaster numa conta AWS
sem nenhum recurso e colocar os 5 serviços no ar via CI/CD + ArgoCD.

**Repositórios envolvidos**

| Repositório | Conteúdo |
|---|---|
| `fiap-postech-fase4` (este) | Terraform da infraestrutura |
| `fiap-gitops` | Manifests Kustomize de cada serviço (lidos pelo ArgoCD) |
| `auth-service`, `flag-service`, `targeting-service`, `evaluation-service`, `analytics-service` | Código, `Dockerfile` e workflow de CI/CD de cada serviço |

**Pré-requisitos locais:** AWS CLI, Terraform >= 1.10, kubectl.

---

## 1. Usuário IAM para o Terraform

No console da AWS (com a conta root ou um admin):

1. **IAM > Policies > Create policy > JSON**: cole o conteúdo de
   [`aws/TerraformPolicy.json`](aws/TerraformPolicy.json) e salve (ex.: `TerraformPolicy`).
2. **IAM > Users > Create user** (ex.: `terraform`) e anexe a policy acima.
3. No usuário criado: **Security credentials > Create access key > CLI**.
4. Configure localmente:

   ```bash
   aws configure --profile fiap
   export AWS_PROFILE=fiap
   aws sts get-caller-identity   # confere se está no usuário certo
   ```

> Use **o mesmo usuário** para o `kubectl`. O EKS dá acesso de admin do
> cluster só para quem o criou.

## 2. Bucket do state remoto (bootstrap)

```bash
cd terraform/bootstrap
terraform init
terraform apply
terraform output backend_config

cd ..
cp backend.hcl.example backend.hcl   # preencha "bucket" com a saída acima
```

## 3. Infraestrutura

```bash
cd terraform
terraform init -backend-config=backend.hcl
terraform plan
terraform apply          # ~15-20 min (EKS e RDS são os mais lentos)

terraform output -raw configure_kubectl | bash
```

Se o `apply` falhar no provider `helm` antes do cluster ficar pronto:

```bash
terraform apply -target=module.eks
terraform apply
```

O apply também instala ArgoCD, KEDA, ingress-nginx e cria as `Application`
do ArgoCD apontando para o `fiap-gitops` (módulo `argocd-apps`).

## 4. Atualizar os manifests no `fiap-gitops`

Os endpoints são novos (nomes `fiap-fase4-*`, senhas do RDS novas, outro
Redis). Atualize e faça push no `fiap-gitops`, que o ArgoCD aplica sozinho:

| Arquivo | Chave | Valor |
|---|---|---|
| `auth-service/base/secret.yaml` | `DATABASE_URL` | `terraform output -json rds_database_urls` |
| `flag-service/base/secret.yaml` | `DATABASE_URL` | `terraform output -json rds_database_urls` |
| `targeting-service/base/secret.yaml` | `DATABASE_URL` | `terraform output -json rds_database_urls` |
| `analytics-service/base/configmap.yaml` | `AWS_SQS_URL` | `terraform output sqs_queue_url` |
| `evaluation-service/base/configmap.yaml` | `AWS_SQS_URL` | `terraform output sqs_queue_url` |
| `evaluation-service/base/configmap.yaml` | `REDIS_URL` | `terraform output elasticache_redis_url` (com `rediss://`) |

Os valores em `secret.yaml` vão em base64 (`echo -n '<valor>' | base64 -w0`).

## 5. Usuário IAM para o GitHub Actions

Crie um usuário separado (ex.: `github-actions`), só com permissão de push
no ECR, usando a policy [`aws/GitHubActionsECRPolicy.json`](aws/GitHubActionsECRPolicy.json),
e gere uma access key para ele.

Em **cada um dos 5 repositórios de serviço**:
**Settings > Secrets and variables > Actions**

| Tipo | Nome | Valor |
|---|---|---|
| Secret | `AWS_ACCESS_KEY_ID` | access key do usuário `github-actions` |
| Secret | `AWS_SECRET_ACCESS_KEY` | secret key do usuário `github-actions` |
| Secret | `GITOPS_TOKEN` | PAT fine-grained do GitHub com *Contents: Read and write* no `fiap-gitops` |
| Variable | `AWS_REGION` | `terraform output github_actions_variables` |
| Variable | `ECR_<SERVICO>` (ex.: `ECR_AUTH`) | `terraform output github_actions_variables` |

## 6. Publicar as imagens

Os repositórios ECR foram recriados vazios: até cada pipeline rodar, os pods
ficam em `ImagePullBackOff` (o `newTag` nos manifests aponta para imagens
que não existem mais).

Faça commit/push na `main` de cada repositório de serviço (ou rode o
workflow manualmente em **Actions > Run workflow**). O pipeline:

1. builda, testa e escaneia o código;
2. publica a imagem no ECR com a tag `v1.0.0-<commit>`;
3. atualiza o `newTag` em `fiap-gitops/<servico>/overlays/production/kustomization.yaml`;
4. o ArgoCD detecta a mudança e faz o deploy.

## 7. Conferir

```bash
# ArgoCD
terraform output -raw argocd_get_server_address | bash   # https://<endereco>
terraform output -raw argocd_get_admin_password | bash   # usuario: admin

# Serviços (ingress compartilhado)
terraform output -raw ingress_get_address | bash
curl http://<endereco>/auth/health
```

| Serviço | Path |
|---|---|
| auth-service | `/auth` |
| flag-service | `/flags` |
| targeting-service | `/targeting` |
| evaluation-service | `/evaluate` |
| analytics-service | `/analytics` |

Depois que o `auth-service` subir, gere uma nova chave nele e atualize o
`SERVICE_API_KEY` em `fiap-gitops/evaluation-service/base/secret.yaml`.

---

## ⚠️ Atenção: senhas no repositório GitOps

O `fiap-gitops` é público e os `secret.yaml` guardam as senhas reais do RDS
em base64, que não é criptografia. Para não expor as credenciais novas:

- torne o `fiap-gitops` privado e cadastre-o no ArgoCD (Settings >
  Repositories, ou um Secret com label `argocd.argoproj.io/secret-type: repository`); ou
- tire os Secrets do Git (ex.: Sealed Secrets / External Secrets).

## Derrubando o ambiente

```bash
cd terraform
terraform destroy
```

O bucket do state (`bootstrap`) tem `prevent_destroy` e não é removido por
esse comando.
