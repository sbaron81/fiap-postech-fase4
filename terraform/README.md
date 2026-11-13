# Infraestrutura Terraform - fiap-postech-fase4

Infraestrutura do ToggleMaster (copiada da Fase 3) adaptada para o modelo de
**repositórios independentes**:

| Repositório | Conteúdo |
|---|---|
| `auth-service`, `flag-service`, `targeting-service`, `evaluation-service`, `analytics-service` | Código, `Dockerfile` e workflow de CI/CD de cada serviço |
| `fiap-gitops` | Manifests Kustomize (`<servico>/base` + `<servico>/overlays/production`) |
| `fiap-postech-fase4` (este) | Terraform da infraestrutura |

## O que é criado

| Módulo | Recurso |
|---|---|
| `networking` | VPC, 2 subnets públicas, 2 subnets privadas, Internet Gateway, NAT Gateway, Route Tables |
| `eks` | Cluster EKS + 1 Node Group (nodes nas subnets privadas) + IAM roles do cluster/nodes |
| `rds` | 3 instâncias RDS PostgreSQL (`auth-service`, `flag-service`, `targeting-service`) |
| `elasticache` | 1 ElastiCache Serverless (Redis), usado pelo `evaluation-service` |
| `dynamodb` | Tabela `ToggleMasterAnalytics` (chave `event_id`, on-demand) |
| `sqs` | 1 fila SQS para os eventos de avaliação de flags |
| `ecr` | 5 repositórios: `fiap/auth-service`, `fiap/flag-service`, `fiap/targeting-service`, `fiap/evaluation-service`, `fiap/analytics-service` |
| `argocd` | ArgoCD instalado via Helm chart oficial (`argo/argo-cd`) no cluster criado |
| `argocd-apps` | Uma `Application` do ArgoCD por serviço (chart `argo/argocd-apps`), apontando para `<servico>/overlays/production` no `fiap-gitops` |
| `keda` / `ingress-nginx` | KEDA e o ingress controller compartilhado pelos 5 serviços |

## Conta pessoal vs. AWS Academy

Por padrão (`use_lab_role = false`), o módulo `eks` **cria suas próprias IAM roles**
(uma para o control plane com `AmazonEKSClusterPolicy`, outra para os nodes com
`AmazonEKSWorkerNodePolicy` + `AmazonEKS_CNI_Policy` + `AmazonEC2ContainerRegistryReadOnly`
+ `AmazonSQSFullAccess` + `AmazonDynamoDBFullAccess` — os dois últimos para
`evaluation-service`/`analytics-service` acessarem SQS/DynamoDB a partir do pod,
igual à Fase 2).

Se um dia isso rodar num AWS Academy Learner Lab (onde não se pode criar IAM
roles), sete `use_lab_role = true` no `terraform.tfvars` para reusar a `LabRole`
já existente na conta em vez de criar roles novas.

## Backend remoto (S3 + lock nativo)

O state **não fica local**. O backend é S3, com locking nativo via
`use_lockfile` (Terraform >= 1.10 — não precisa de tabela DynamoDB para lock).

### 1. Crie o bucket de state (uma vez só)

```bash
cd terraform/bootstrap
terraform init
terraform apply
terraform output backend_config
```

Isso cria o bucket (versionado, criptografado, sem acesso público) com um nome
único baseado no seu Account ID. Esse mini-projeto usa state **local** de
propósito — é o único jeito de resolver o "ovo e a galinha" de criar o bucket
que vai guardar o state de tudo o mais.

### 2. Configure o backend do projeto principal

```bash
cd ../
cp backend.hcl.example backend.hcl
# edite backend.hcl com o bucket do passo 1 (saida "bucket_name" do bootstrap)
terraform init -backend-config=backend.hcl
```

`backend.hcl` não vai pro git (está no `.gitignore`) porque o nome do bucket é
específico da sua conta.

## Antes de rodar: IAM policy

Se você anexa uma policy própria e restrita ao usuário/role que roda o
Terraform (em vez de usar credenciais de admin), use
[`../aws/TerraformPolicy.json`](../aws/TerraformPolicy.json) como referência —
ela cobre `ec2`, `eks`, `rds`, `s3`, `ecr`, `sqs`, `dynamodb`, `elasticache` e
as ações de IAM necessárias para o Terraform criar/associar as roles do EKS
(`iam:CreateRole`, `iam:PassRole`, etc., restritas aos nomes `*-eks-cluster-role`
e `*-eks-node-role`).

## Uso

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars   # opcional, os defaults já funcionam
terraform init -backend-config=backend.hcl
terraform plan
terraform apply
```

Para configurar o `kubectl` depois do apply:

```bash
terraform output -raw configure_kubectl | bash
```

Para ver as connection strings dos bancos (sensíveis, não aparecem no `apply` normal):

```bash
terraform output -json rds_database_urls
```

## ArgoCD

O provider `helm` se autentica no cluster usando as mesmas credenciais AWS do
`terraform apply` (via `data.aws_eks_cluster_auth`, equivalente a `aws eks
get-token`). Como o EKS dá permissão de cluster-admin automaticamente para
quem cria o cluster (`bootstrap_cluster_creator_admin_permissions`, default
do provider AWS), isso funciona sem configurar RBAC/aws-auth manualmente —
desde que seja o mesmo usuário/role rodando o `apply` do início ao fim.

O Service `argocd-server` é `LoadBalancer` por padrão (as subnets públicas já
têm a tag `kubernetes.io/role/elb` exigida para o EKS provisionar a ELB
automaticamente). Depois do `apply`:

```bash
# endereço do LoadBalancer (pode levar 1-2 min para o DNS propagar)
terraform output -raw argocd_get_server_address | bash

# senha inicial do usuario "admin"
terraform output -raw argocd_get_admin_password | bash
```

Login via CLI do ArgoCD (`argocd login <endereco> --username admin`) ou pela
UI web em `https://<endereco>` (certificado autoassinado, o navegador vai
avisar).

### Applications (fiap-gitops)

O módulo `argocd-apps` cria as 5 `Application` (o `fiap-gitops` contém só os
manifests Kustomize, sem `Application`). Variáveis relevantes:

| Variável | Default |
|---|---|
| `gitops_repo_url` | `https://github.com/sbaron81/fiap-gitops` |
| `gitops_target_revision` | `main` |
| `services` | os 5 serviços (também define os repositórios ECR `fiap/<servico>`) |
| `enable_argocd_apps` | `true` (use `false` para registrar as Applications manualmente) |

O `fiap-gitops` é público, então o ArgoCD lê sem credencial. Se ele virar
privado, cadastre o repositório no ArgoCD (Settings > Repositories ou um
Secret com label `argocd.argoproj.io/secret-type: repository`).

## CI/CD nos repositórios dos serviços

Cada repositório de serviço tem seu workflow em `.github/workflows/<servico>.yaml`:
build/testes → lint → SAST/SCA → build, scan e push da imagem no ECR →
atualização do `newTag` em `fiap-gitops/<servico>/overlays/production/kustomization.yaml`
→ o ArgoCD sincroniza.

Configuração necessária em **cada repositório de serviço**
(Settings > Secrets and variables > Actions):

| Tipo | Nome | Valor |
|---|---|---|
| Secret | `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` | credenciais com push no ECR |
| Secret | `GITOPS_TOKEN` | PAT fine-grained com *Contents: Read and write* no `fiap-gitops` |
| Variable | `AWS_REGION`, `ECR_<SERVICO>` | `terraform output github_actions_variables` |

**Primeiro apply**: como o provider `helm` só consegue resolver `host`/`token`
depois que o cluster existe, tudo em uma única conta e um único `apply`
funciona normalmente. Se por algum motivo o `apply` completo falhar por causa
do provider `helm` antes do cluster ficar pronto, rode primeiro
`terraform apply -target=module.eks` e depois `terraform apply` sem target.

## Próximos passos (fora deste Terraform)

Os manifests em `fiap-gitops/<servico>/base/secret.yaml` e `configmap.yaml`
apontam para os endpoints da Fase 3. Depois do `apply`, atualize-os com os novos
valores de `terraform output` (`DATABASE_URL`, `REDIS_URL`, `AWS_SQS_URL`,
`AWS_DYNAMODB_TABLE`) e faça push no `fiap-gitops` — o ArgoCD aplica sozinho.

## Convivência com a Fase 3

VPC, EKS, RDS, SQS e o bucket de state agora usam o prefixo `fiap-fase4`, mas
os repositórios ECR (`fiap/<servico>`), a tabela DynamoDB (`ToggleMasterAnalytics`)
e o ElastiCache (`evaluation-service`) mantêm o nome, porque os manifests e os
serviços dependem deles. Por isso, rode `terraform destroy` na Fase 3 antes do
`apply` aqui (ou mude esses nomes nas duas pontas).

## Notas de custo/tempo

- RDS: sem backup (`backup_retention_period = 0`), sem Multi-AZ, `db.t3.micro` —
  minimiza custo, não use essas configurações em produção.
- Um único NAT Gateway (não um por AZ) para reduzir custo.
- `force_delete = true` no ECR e `skip_final_snapshot = true` no RDS para que
  `terraform destroy` funcione de primeira.
