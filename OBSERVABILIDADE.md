# Observabilidade, APM e Self-Healing (Fase 4)

Passo a passo para instrumentar os 5 microsserviços do ToggleMaster com
OpenTelemetry, subir a stack de monitoramento no cluster via GitOps, integrar
um APM e automatizar a resposta a incidentes.

Pré-requisito: ambiente no ar seguindo o [SETUP.md](SETUP.md) (EKS, ArgoCD,
ingress e os 5 serviços sincronizados).

**Escolhas desta implementação**

| Requisito | Ferramenta | Motivo |
|---|---|---|
| Métricas | Prometheus (`kube-prometheus-stack`) | Já traz node-exporter, kube-state-metrics e Grafana |
| Logs | Loki (modo *SingleBinary*) | Recebe OTLP nativamente (Loki 3.x) |
| Visualização / alertas | Grafana | Vem no `kube-prometheus-stack`; alertas e dashboards provisionados via Git |
| Pipeline de telemetria | OpenTelemetry Collector (DaemonSet) | Recebe OTLP dos serviços e lê os logs dos contêineres de cada nó |
| APM | **New Relic** | Aceita OTLP direto, sem agente proprietário (conta grátis: 100 GB/mês) |
| Incidentes | **PagerDuty** | Integração nativa no Grafana (o OpsGenie está sendo descontinuado pela Atlassian) |
| ChatOps | **Slack** | Integração nativa no Grafana via Incoming Webhook |
| Self-healing | **GitHub Action** disparada por webhook (`repository_dispatch`) | Fica versionada e auditável no próprio repositório |

**Arquitetura**

```text
┌──────────────────────────── cluster EKS ─────────────────────────────┐
│                                                                      │
│  5 microsserviços ──OTLP/gRPC──┐                                     │
│                                ▼                                     │
│  stdout dos      ──filelog──▶ OTel Collector (DaemonSet)             │
│  contêineres                   │        │         │                  │
│                     métricas   │  logs  │         │ traces           │
│                                ▼        ▼         │                  │
│                        Prometheus     Loki        │                  │
│                                └───┬────┘         │                  │
│                                    ▼              │                  │
│                                 Grafana           │                  │
│                          (dashboards + alerta)    │                  │
└────────────────────────────────────┼──────────────┼──────────────────┘
                                     │              ▼
                                     │      New Relic (APM, traces, Service Map)
              ┌──────────────────────┼──────────────────────┐
              ▼                      ▼                      ▼
          PagerDuty               Slack        GitHub Actions (repository_dispatch)
         (incidente)          (notificação)                 │
                                                            ▼
                                kubectl rollout restart deployment/auth-service
```

Divisão de responsabilidades:

- **Métricas de infraestrutura** (CPU, memória, pods, nós): o Prometheus coleta
  direto do kubelet/cAdvisor, node-exporter e kube-state-metrics.
- **Métricas de aplicação, traces e logs**: passam todos pelo OTel Collector,
  que roteia métricas → Prometheus, logs → Loki e traces → New Relic.

---

## 1. Capacidade do cluster

A stack de observabilidade adiciona cerca de 15 pods e ~2 GB de memória. Com
2 nós `t3.medium` (limite de 17 pods por nó) o cluster não comporta tudo.
Ajuste o `terraform/terraform.tfvars`:

```hcl
node_instance_types = ["t3.large"]   # 35 pods / 8 GB por nó
node_desired_size   = 3
node_max_size       = 4
```

```bash
cd terraform
terraform apply
```

> Mudar o tipo de instância recria o node group, e os pods ficam fora do ar
> por alguns minutos. Faça isso antes de começar.

O cluster não tem o EBS CSI driver, então Prometheus, Loki e Grafana rodam
**sem volume persistente** (os dados se perdem se o pod reiniciar). Para o
desafio isso basta, porque toda a configuração do Grafana vem do Git (passos 6 e 7).

## 2. Contas externas

Crie as contas e guarde os valores, que vão para Secrets no passo 3.

### 2.1 New Relic (APM)

1. Crie a conta em <https://newrelic.com/signup> (o plano free basta) e anote
   a **região** (US ou EU).
2. **Profile > API Keys > Create a key** do tipo **Ingest - License**. Copie a
   chave: é o `NEW_RELIC_LICENSE_KEY`.
3. Endpoint OTLP: `https://otlp.nr-data.net:4317` (US) ou
   `https://otlp.eu01.nr-data.net:4317` (EU).

### 2.2 PagerDuty (incidentes)

1. Crie a conta em <https://www.pagerduty.com/sign-up/> (plano Free).
2. **Services > Service Directory > New Service**: nome `ToggleMaster - auth-service`.
3. Em *Integrations*, escolha **Events API V2** e copie a **Integration Key**:
   é o `PAGERDUTY_INTEGRATION_KEY`.
4. (Opcional) Instale o app do PagerDuty no Slack para acompanhar o incidente
   também por lá.

### 2.3 Slack (ChatOps)

1. Crie um canal, ex.: `#toggle-master-alertas`.
2. Em <https://api.slack.com/apps>: **Create New App > From scratch**.
3. **Incoming Webhooks > On > Add New Webhook to Workspace** e escolha o canal.
4. Copie a URL `https://hooks.slack.com/services/...`: é o `SLACK_WEBHOOK_URL`.

### 2.4 GitHub (gatilho do self-healing)

Crie um **PAT fine-grained** (**Settings > Developer settings > Personal access
tokens > Fine-grained**):

- *Repository access*: só `sbaron81/fiap-postech-fase4`
- *Permissions*: **Contents: Read and write** (é o que o endpoint
  `repository_dispatch` exige)

Esse token é o `GITHUB_DISPATCH_TOKEN`. Anote a data de expiração.

## 3. Secrets no cluster

Os Secrets são criados à mão e **nunca vão para o Git**, porque o `fiap-gitops`
é público.

```bash
kubectl create namespace observability

# Senha do admin do Grafana
kubectl -n observability create secret generic grafana-admin \
  --from-literal=admin-user=admin \
  --from-literal=admin-password="$(openssl rand -base64 18)"

# Chaves usadas pelos contact points do Grafana (passo 7)
kubectl -n observability create secret generic grafana-alerting \
  --from-literal=PAGERDUTY_INTEGRATION_KEY='<integration key>' \
  --from-literal=SLACK_WEBHOOK_URL='https://hooks.slack.com/services/...' \
  --from-literal=GITHUB_DISPATCH_TOKEN='github_pat_...'

# License key do New Relic, lida pelo OTel Collector
kubectl -n observability create secret generic newrelic-license \
  --from-literal=license-key='<license key>'
```

## 4. Stack de observabilidade no `fiap-gitops`

Estrutura a criar no `fiap-gitops`:

```text
observability/
├── root-app.yaml                  # aplicado uma vez com kubectl (app-of-apps)
├── apps/                          # Applications do ArgoCD (charts Helm)
│   ├── kube-prometheus-stack.yaml
│   ├── loki.yaml
│   ├── otel-collector.yaml
│   └── observability-config.yaml
├── values/                        # values de cada chart
│   ├── kube-prometheus-stack.yaml
│   ├── loki.yaml
│   └── otel-collector.yaml
└── manifests/                     # dashboard, alertas e RBAC do self-healing
    ├── kustomization.yaml
    ├── dashboards/toggle-master.json
    ├── alerting/alert-rules.yaml
    ├── alerting/contact-points.yaml
    └── self-healer.yaml
```

### 4.1 Versões dos charts

Fixe as versões (o `targetRevision` das Applications abaixo) com o que estiver
disponível no momento:

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana https://grafana.github.io/helm-charts
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts
helm repo update
helm search repo prometheus-community/kube-prometheus-stack
helm search repo grafana/loki
helm search repo open-telemetry/opentelemetry-collector
```

> A custom payload do webhook (passo 7) exige **Grafana 12 ou mais recente**,
> que é o que as versões atuais do `kube-prometheus-stack` instalam.

### 4.2 Applications (`observability/apps/`)

As três Applications de chart usam *multi-source*: o chart vem do repositório
Helm e o arquivo de values vem do próprio `fiap-gitops` (`$values`).

`observability/apps/kube-prometheus-stack.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: kube-prometheus-stack
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "0"
spec:
  project: default
  sources:
    - repoURL: https://prometheus-community.github.io/helm-charts
      chart: kube-prometheus-stack
      targetRevision: <VERSAO>
      helm:
        releaseName: kps
        valueFiles:
          - $values/observability/values/kube-prometheus-stack.yaml
    - repoURL: https://github.com/sbaron81/fiap-gitops
      targetRevision: main
      ref: values
  destination:
    server: https://kubernetes.default.svc
    namespace: observability
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true   # os CRDs do Prometheus Operator passam do limite de annotation do client-side apply
```

`observability/apps/loki.yaml`: igual ao anterior, trocando:

```yaml
metadata:
  name: loki
  annotations:
    argocd.argoproj.io/sync-wave: "0"
spec:
  sources:
    - repoURL: https://grafana.github.io/helm-charts
      chart: loki
      targetRevision: <VERSAO>
      helm:
        releaseName: loki
        valueFiles:
          - $values/observability/values/loki.yaml
    - repoURL: https://github.com/sbaron81/fiap-gitops
      targetRevision: main
      ref: values
```

`observability/apps/otel-collector.yaml`: igual, trocando:

```yaml
metadata:
  name: otel-collector
  annotations:
    argocd.argoproj.io/sync-wave: "1"
spec:
  sources:
    - repoURL: https://open-telemetry.github.io/opentelemetry-helm-charts
      chart: opentelemetry-collector
      targetRevision: <VERSAO>
      helm:
        releaseName: otel-collector
        valueFiles:
          - $values/observability/values/otel-collector.yaml
    - repoURL: https://github.com/sbaron81/fiap-gitops
      targetRevision: main
      ref: values
```

`observability/apps/observability-config.yaml` (Kustomize, sem Helm):

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: observability-config
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "2"
spec:
  project: default
  source:
    repoURL: https://github.com/sbaron81/fiap-gitops
    targetRevision: main
    path: observability/manifests
  destination:
    server: https://kubernetes.default.svc
    namespace: observability
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [CreateNamespace=true]
```

### 4.3 Values

`observability/values/kube-prometheus-stack.yaml`:

```yaml
fullnameOverride: kps            # Services: kps-prometheus, kps-grafana...

# Os componentes do control plane do EKS não são acessíveis, então os scrapes
# deles ficariam sempre DOWN.
kubeControllerManager: { enabled: false }
kubeScheduler: { enabled: false }
kubeEtcd: { enabled: false }
kubeProxy: { enabled: false }

# Os alertas ficam no Grafana (passo 7), não no Alertmanager.
alertmanager: { enabled: false }
defaultRules: { create: false }

prometheus:
  prometheusSpec:
    enableRemoteWriteReceiver: true   # o OTel Collector grava em /api/v1/write
    retention: 3d
    serviceMonitorSelectorNilUsesHelmValues: false
    podMonitorSelectorNilUsesHelmValues: false
    resources:
      requests: { cpu: 200m, memory: 512Mi }
      limits: { memory: 1536Mi }

grafana:
  admin:
    existingSecret: grafana-admin
    userKey: admin-user
    passwordKey: admin-password
  # Chaves do PagerDuty/Slack/GitHub. O Grafana interpola ${VAR} nos arquivos
  # de provisioning.
  envFromSecret: grafana-alerting
  additionalDataSources:
    - name: Loki
      uid: loki
      type: loki
      access: proxy
      url: http://loki.observability.svc.cluster.local:3100
  sidecar:
    dashboards:
      enabled: true
      label: grafana_dashboard
      labelValue: "1"
    alerts:
      enabled: true
      label: grafana_alert
      labelValue: "1"
  resources:
    requests: { cpu: 100m, memory: 256Mi }
    limits: { memory: 512Mi }
```

`observability/values/loki.yaml` (monolítico, armazenamento em disco local):

```yaml
deploymentMode: SingleBinary

loki:
  auth_enabled: false
  commonConfig:
    replication_factor: 1
  storage:
    type: filesystem
  schemaConfig:
    configs:
      - from: "2024-04-01"
        store: tsdb
        object_store: filesystem
        schema: v13
        index: { prefix: loki_index_, period: 24h }
  limits_config:
    allow_structured_metadata: true   # necessário para ingestão OTLP
    volume_enabled: true
    retention_period: 72h

singleBinary:
  replicas: 1
  persistence:
    enabled: false                    # sem EBS CSI no cluster
  resources:
    requests: { cpu: 100m, memory: 256Mi }
    limits: { memory: 1Gi }

# Desliga tudo que é de modo distribuído ou que reserva muita memória
read: { replicas: 0 }
write: { replicas: 0 }
backend: { replicas: 0 }
gateway: { enabled: false }
chunksCache: { enabled: false }       # por padrão pede GBs de memória (memcached)
resultsCache: { enabled: false }
minio: { enabled: false }
lokiCanary: { enabled: false }
test: { enabled: false }
```

`observability/values/otel-collector.yaml`:

```yaml
mode: daemonset
fullnameOverride: otel-collector   # Service: otel-collector.observability.svc

image:
  repository: otel/opentelemetry-collector-contrib
command:
  name: otelcol-contrib

presets:
  logsCollection:
    enabled: true          # receiver filelog em /var/log/pods (logs de TODOS os contêineres)
  kubernetesAttributes:
    enabled: true          # adiciona k8s.namespace.name, k8s.pod.name, k8s.deployment.name...

service:
  enabled: true
  internalTrafficPolicy: Local   # cada pod envia para o collector do próprio nó

extraEnvs:
  - name: NEW_RELIC_LICENSE_KEY
    valueFrom:
      secretKeyRef: { name: newrelic-license, key: license-key }

resources:
  requests: { cpu: 50m, memory: 128Mi }
  limits: { memory: 512Mi }

config:
  processors:
    batch: {}
    resource/cluster:
      attributes:
        - { key: k8s.cluster.name, value: fiap-fase4, action: upsert }

  exporters:
    # Métricas de aplicação -> Prometheus
    prometheusremotewrite:
      endpoint: http://kps-prometheus.observability.svc.cluster.local:9090/api/v1/write
    # Logs -> Loki (endpoint OTLP nativo; o exporter acrescenta /v1/logs)
    otlphttp/loki:
      endpoint: http://loki.observability.svc.cluster.local:3100/otlp
    # Traces -> New Relic (troque para otlp.eu01.nr-data.net se a conta for EU)
    otlp/newrelic:
      endpoint: https://otlp.nr-data.net:4317
      compression: gzip
      headers:
        api-key: ${env:NEW_RELIC_LICENSE_KEY}

  service:
    # Os presets incluem k8sattributes (processors) e filelog (receivers de
    # logs) sozinhos. As listas abaixo substituem as padrão do chart.
    pipelines:
      traces:
        receivers: [otlp]
        processors: [memory_limiter, resource/cluster, batch]
        exporters: [otlp/newrelic]
      metrics:
        receivers: [otlp]
        processors: [memory_limiter, resource/cluster, batch]
        exporters: [prometheusremotewrite]
      logs:
        receivers: [otlp]
        processors: [memory_limiter, resource/cluster, batch]
        exporters: [otlphttp/loki]
```

> O `prometheusremotewrite` grava o `service.name` do recurso OTel no label
> `job` do Prometheus. Por isso as queries abaixo filtram por
> `job="auth-service"`. Não defina `service.namespace` nos serviços: com ele,
> o `job` vira `<namespace>/<serviço>`.

### 4.4 Registrar no ArgoCD (app-of-apps)

`observability/root-app.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: observability
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/sbaron81/fiap-gitops
    targetRevision: main
    path: observability/apps
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated: { prune: true, selfHeal: true }
```

Depois de commitar tudo (inclusive o passo 6 e o 7, ou o `observability-config`
fica com erro até eles existirem):

```bash
kubectl apply -f observability/root-app.yaml   # só uma vez; o resto vem do Git
kubectl -n argocd get applications
kubectl -n observability get pods
```

Acesso ao Grafana:

O Grafana fica exposto pela internet no mesmo NLB dos serviços, no path
`/grafana` (`grafana.ingress` + `serve_from_sub_path` no values do
`kube-prometheus-stack`):

```bash
# endereço do NLB (mesmo dos serviços)
cd terraform && terraform output -raw ingress_get_address | bash
# http://<endereco-do-lb>/grafana/

# alternativa sem passar pela internet
kubectl -n observability port-forward svc/kps-grafana 3000:80
# http://localhost:3000/grafana/

# usuário admin, senha:
kubectl -n observability get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d
```

> O NLB é HTTP sem TLS: a senha do admin trafega em texto claro. Use uma
> senha forte (o `openssl rand` do passo 3) e não reutilize em outro lugar.

## 5. Instrumentação dos microsserviços

Todos os serviços usam o SDK do OpenTelemetry e enviam OTLP/gRPC para o
collector do nó. Nenhum deles fala direto com Prometheus, Loki ou New Relic.

| Serviço | Linguagem | Instrumentação |
|---|---|---|
| auth-service | Go | SDK + `otelhttp` (servidor) |
| evaluation-service | Go | SDK + `otelhttp` (servidor e cliente) + `redisotel` + span manual de produtor SQS |
| flag-service, targeting-service | Python/Flask | automática (`opentelemetry-instrument`): Flask, requests, psycopg2 |
| analytics-service | Python/Flask | automática + span manual de consumidor SQS |

Caminho de um trace que começa no `evaluation-service`:

```text
GET /evaluate (evaluation-service)
 ├─ Redis GET (cache)
 ├─ GET flag-service/flags/{nome}  ──▶ flag-service ──▶ auth-service /validate ──▶ PostgreSQL
 ├─ GET targeting-service/rules/{nome} ──▶ targeting-service ──▶ auth-service /validate
 └─ SQS send (producer) ──▶ analytics-service: SQS process (consumer) ──▶ DynamoDB PutItem
```

O contexto passa entre serviços pelo header `traceparent` (W3C) nas chamadas
HTTP e por um *message attribute* `traceparent` na mensagem SQS. É isso que
monta o Service Map com os 5 serviços.

### 5.1 Variáveis de ambiente (`fiap-gitops`)

Acrescente ao `base/configmap.yaml` de **cada** serviço, trocando o
`OTEL_SERVICE_NAME`:

```yaml
  OTEL_SERVICE_NAME: "auth-service"
  OTEL_EXPORTER_OTLP_ENDPOINT: "http://otel-collector.observability.svc.cluster.local:4317"
  OTEL_EXPORTER_OTLP_PROTOCOL: "grpc"
  OTEL_RESOURCE_ATTRIBUTES: "deployment.environment=production"
  OTEL_TRACES_EXPORTER: "otlp"
  OTEL_METRICS_EXPORTER: "otlp"
  # Os logs chegam ao Loki pelo filelog do collector (stdout). Exportar via
  # OTLP também duplicaria as linhas.
  OTEL_LOGS_EXPORTER: "none"
  # Python: usa as convenções HTTP estáveis (mesmos nomes de métrica do Go)
  OTEL_SEMCONV_STABILITY_OPT_IN: "http"
  OTEL_PYTHON_EXCLUDED_URLS: "health"
```

Só no `analytics-service`, acrescente também (o span de consumidor é manual,
ver 5.4):

```yaml
  OTEL_PYTHON_DISABLED_INSTRUMENTATIONS: "boto3sqs"
```

Nos serviços Python, suba o limite de memória do `deployment.yaml` de 128Mi
para **256Mi**, porque o SDK de OpenTelemetry aumenta o consumo.

### 5.2 Go: `auth-service`

```bash
go get go.opentelemetry.io/otel \
       go.opentelemetry.io/otel/sdk \
       go.opentelemetry.io/otel/sdk/metric \
       go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc \
       go.opentelemetry.io/otel/exporters/otlp/otlpmetric/otlpmetricgrpc \
       go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp
```

Novo arquivo `telemetry.go` (é o mesmo nos dois serviços Go):

```go
package main

import (
	"context"
	"errors"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/exporters/otlp/otlpmetric/otlpmetricgrpc"
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc"
	"go.opentelemetry.io/otel/propagation"
	sdkmetric "go.opentelemetry.io/otel/sdk/metric"
	"go.opentelemetry.io/otel/sdk/resource"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
)

// setupOTel configura traces e métricas via OTLP/gRPC. Endpoint, nome do
// serviço e atributos vêm das variáveis OTEL_* (OTEL_EXPORTER_OTLP_ENDPOINT,
// OTEL_SERVICE_NAME, OTEL_RESOURCE_ATTRIBUTES).
func setupOTel(ctx context.Context) (func(context.Context) error, error) {
	res, err := resource.New(ctx,
		resource.WithFromEnv(),
		resource.WithTelemetrySDK(),
		resource.WithHost(),
	)
	if err != nil {
		return nil, err
	}

	traceExp, err := otlptracegrpc.New(ctx)
	if err != nil {
		return nil, err
	}
	tp := sdktrace.NewTracerProvider(
		sdktrace.WithBatcher(traceExp),
		sdktrace.WithResource(res),
	)
	otel.SetTracerProvider(tp)

	metricExp, err := otlpmetricgrpc.New(ctx)
	if err != nil {
		return nil, err
	}
	mp := sdkmetric.NewMeterProvider(
		sdkmetric.WithReader(sdkmetric.NewPeriodicReader(metricExp)),
		sdkmetric.WithResource(res),
	)
	otel.SetMeterProvider(mp)

	// W3C traceparent/baggage: o formato que o Flask/requests do Python
	// também entendem.
	otel.SetTextMapPropagator(propagation.NewCompositeTextMapPropagator(
		propagation.TraceContext{}, propagation.Baggage{},
	))

	return func(ctx context.Context) error {
		return errors.Join(tp.Shutdown(ctx), mp.Shutdown(ctx))
	}, nil
}
```

No `main.go`, logo após carregar o `.env`:

```go
	shutdown, err := setupOTel(context.Background())
	if err != nil {
		log.Fatalf("Erro ao configurar OpenTelemetry: %v", err)
	}
	defer func() { _ = shutdown(context.Background()) }()
```

E troque o `Handler` do servidor HTTP:

```go
	handler := otelhttp.NewHandler(mux, "auth-service",
		otelhttp.WithSpanNameFormatter(func(_ string, r *http.Request) string {
			return r.Method + " " + r.URL.Path
		}),
		// health checks do kubelet não viram trace
		otelhttp.WithFilter(func(r *http.Request) bool { return r.URL.Path != "/health" }),
	)

	srv := &http.Server{
		Addr:    ":" + port,
		Handler: handler,
		// ...timeouts iguais
	}
```

O `otelhttp` gera a métrica `http.server.request.duration` (histograma, com
o label `http.response.status_code`). No Prometheus ela aparece como
`http_server_request_duration_seconds_{count,sum,bucket}`. É a base do
dashboard e do alerta de 5xx.

**Endpoint de caos (para testar o self-healing).** Ele liga uma falha em
memória que só some quando o pod reinicia, então o `rollout restart` de fato
resolve o problema. No `handlers.go`:

```go
// chaosEnabled faz o pod responder 500 em todas as rotas (exceto /health e
// /admin/chaos). Fica só em memória: um restart do pod limpa o estado.
var chaosEnabled atomic.Bool

func (a *App) chaosMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if chaosEnabled.Load() && r.URL.Path != "/health" && r.URL.Path != "/admin/chaos" {
			http.Error(w, "falha simulada (chaos)", http.StatusInternalServerError)
			return
		}
		next.ServeHTTP(w, r)
	})
}

// POST liga a falha; DELETE desliga.
func (a *App) chaosHandler(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case http.MethodPost:
		chaosEnabled.Store(true)
	case http.MethodDelete:
		chaosEnabled.Store(false)
	default:
		http.Error(w, "método não permitido", http.StatusMethodNotAllowed)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}
```

No `main.go`, registre a rota (protegida pela master key) e encadeie o
middleware **dentro** do `otelhttp`, para que os 500 entrem na métrica:

```go
	mux.Handle("/admin/chaos", app.masterKeyAuthMiddleware(http.HandlerFunc(app.chaosHandler)))
	handler := otelhttp.NewHandler(app.chaosMiddleware(mux), "auth-service", /* opções acima */)
```

**Opcional (spans do PostgreSQL).** Use `github.com/XSAM/otelsql`: troque
`sql.Open("pgx", url)` por `otelsql.Open("pgx", url)` e use os métodos
`...Context(r.Context(), ...)` nas queries.

### 5.3 Go: `evaluation-service`

Mesmas dependências do auth-service, mais o hook do Redis:

```bash
go get github.com/go-redis/redis/extra/redisotel/v8@v8.11.5
```

Copie o `telemetry.go`, chame `setupOTel` no `main.go` e envolva o `mux` com
`otelhttp.NewHandler` (igual ao 5.2). Depois:

**1. Cliente HTTP instrumentado** (propaga o `traceparent` para flag/targeting):

```go
	httpClient := &http.Client{
		Timeout:   5 * time.Second,
		Transport: otelhttp.NewTransport(http.DefaultTransport),
	}
```

**2. Redis instrumentado:**

```go
	rdb := redis.NewClient(opt)
	rdb.AddHook(redisotel.NewTracingHook())
```

**3. Passar o contexto da requisição adiante.** Hoje o código usa o `ctx`
global e `http.NewRequest`, o que quebra o trace. Mude as assinaturas para
receber `ctx context.Context` e repasse `r.Context()` a partir do handler:

```go
// handlers.go
info, err := a.getCombinedFlagInfo(r.Context(), flagName)

// evaluator.go
func (a *App) getCombinedFlagInfo(ctx context.Context, flagName string) (*CombinedFlagInfo, error) {
	val, err := a.RedisClient.Get(ctx, cacheKey).Result()   // ctx da requisição, não o global
	// ...
	flagInfo, flagErr = a.fetchFlag(ctx, flagName)
	ruleInfo, ruleErr = a.fetchRule(ctx, flagName)
}

func (a *App) fetchFlag(ctx context.Context, flagName string) (*Flag, error) {
	req, err := http.NewRequestWithContext(ctx, "GET", reqURL, nil)
	// ...
}
// fetchRule: mesma mudança
```

**4. Propagar o trace pela fila SQS** (`sqs.go`). O `evaluation-service`
injeta o contexto nos *message attributes*, e o `analytics-service` extrai
do outro lado:

```go
import (
	"context"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/codes"
	"go.opentelemetry.io/otel/propagation"
	"go.opentelemetry.io/otel/trace"
)

func (a *App) sendEvaluationEvent(ctx context.Context, userID, flagName string, result bool) {
	// ... validações e json.Marshal iguais ...

	ctx, span := otel.Tracer("evaluation-service").Start(ctx, "toggle-events send",
		trace.WithSpanKind(trace.SpanKindProducer),
		trace.WithAttributes(
			attribute.String("messaging.system", "aws_sqs"),
			attribute.String("messaging.destination.name", a.SqsQueueURL),
		),
	)
	defer span.End()

	carrier := propagation.MapCarrier{}
	otel.GetTextMapPropagator().Inject(ctx, carrier)
	attrs := make(map[string]*sqs.MessageAttributeValue, len(carrier))
	for k, v := range carrier {
		attrs[k] = &sqs.MessageAttributeValue{DataType: aws.String("String"), StringValue: aws.String(v)}
	}

	_, err = a.SqsSvc.SendMessageWithContext(ctx, &sqs.SendMessageInput{
		MessageBody:       aws.String(string(body)),
		QueueUrl:          aws.String(a.SqsQueueURL),
		MessageAttributes: attrs,
	})
	if err != nil {
		span.RecordError(err)
		span.SetStatus(codes.Error, err.Error())
		// log igual ao atual
	}
}
```

No `handlers.go`, a chamada roda numa goroutine depois que a resposta já
saiu. Por isso ela leva só o *span context*, e não o `r.Context()`, que é
cancelado no fim da requisição:

```go
	bgCtx := trace.ContextWithSpanContext(context.Background(), trace.SpanContextFromContext(r.Context()))
	go a.sendEvaluationEvent(bgCtx, userID, flagName, result)
```

Ajuste os testes (`*_test.go`) às novas assinaturas.

### 5.4 Python: `flag-service`, `targeting-service`, `analytics-service`

Instrumentação automática, sem mudar o código dos dois primeiros.

`requirements.txt` (nos 3):

```text
opentelemetry-distro
opentelemetry-exporter-otlp
```

> Depois do primeiro build que funcionar, fixe as versões que o `pip` instalou
> (`pip freeze | grep opentelemetry`) para os builds serem reproduzíveis.

`Dockerfile` (exemplo do analytics; nos outros só muda a porta):

```dockerfile
FROM python:3.11-slim

WORKDIR /app/

COPY ./analytics-service .

# opentelemetry-bootstrap detecta as libs instaladas (flask, requests,
# psycopg2, botocore...) e instala os pacotes de instrumentação de cada uma
RUN pip install --no-cache-dir -r requirements.txt \
 && opentelemetry-bootstrap -a install

EXPOSE 8005

# opentelemetry-instrument ativa a instrumentação antes de o gunicorn subir
CMD ["opentelemetry-instrument", "gunicorn", "--bind", "0.0.0.0:8005", "app:app"]
```

**`analytics-service`: span de consumidor SQS.** Extrai o `traceparent` que o
`evaluation-service` enviou, e assim o processamento e o `PutItem` do DynamoDB
entram no mesmo trace. No `app.py`:

```python
from opentelemetry import propagate, trace
from opentelemetry.trace import SpanKind

tracer = trace.get_tracer("analytics-service")

# em sqs_worker_loop():
response = sqs_client.receive_message(
    QueueUrl=SQS_QUEUE_URL,
    MaxNumberOfMessages=10,
    WaitTimeSeconds=20,
    MessageAttributeNames=["All"],   # sem isso o traceparent não vem na mensagem
)
# ...
for message in messages:
    carrier = {
        k: v.get("StringValue", "")
        for k, v in message.get("MessageAttributes", {}).items()
    }
    parent_ctx = propagate.extract(carrier)
    with tracer.start_as_current_span(
        "toggle-events process",
        context=parent_ctx,
        kind=SpanKind.CONSUMER,
        attributes={
            "messaging.system": "aws_sqs",
            "messaging.message.id": message["MessageId"],
        },
    ):
        process_message(message)
```

### 5.5 Publicar

1. Commit/push na `main` dos 5 repositórios de serviço. O pipeline publica a
   imagem e atualiza o `newTag` no `fiap-gitops` (como no [SETUP.md](SETUP.md#6-publicar-as-imagens)).
2. Commit/push das mudanças de ConfigMap/Deployment no `fiap-gitops`.
3. Confira se os pods subiram e se o collector está recebendo dados:

```bash
kubectl -n observability logs ds/otel-collector --tail=50
```

## 6. Dashboard customizado no Grafana

O dashboard é provisionado por ConfigMap com o label `grafana_dashboard: "1"`,
que o sidecar do Grafana carrega automaticamente.

`observability/manifests/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

# Sem "namespace:" global, porque o self-healer.yaml vive no namespace auth-service
resources:
  - self-healer.yaml

generatorOptions:
  disableNameSuffixHash: true

configMapGenerator:
  - name: dashboard-toggle-master
    namespace: observability
    files:
      - toggle-master.json=dashboards/toggle-master.json
    options:
      labels:
        grafana_dashboard: "1"
  - name: alerting-toggle-master
    namespace: observability
    files:
      - alert-rules.yaml=alerting/alert-rules.yaml
      - contact-points.yaml=alerting/contact-points.yaml
    options:
      labels:
        grafana_alert: "1"
```

`observability/manifests/dashboards/toggle-master.json`. São três blocos:
saúde do cluster, RED dos microsserviços (taxa, erros, latência) e logs em
tempo real com filtro por serviço e por texto.

```json
{
  "uid": "toggle-master",
  "title": "ToggleMaster - Saúde do Ecossistema",
  "tags": ["toggle-master"],
  "timezone": "browser",
  "refresh": "30s",
  "time": { "from": "now-1h", "to": "now" },
  "schemaVersion": 39,
  "templating": {
    "list": [
      {
        "name": "servico",
        "label": "Serviço",
        "type": "custom",
        "query": "auth-service,flag-service,targeting-service,evaluation-service,analytics-service",
        "includeAll": true,
        "allValue": "auth-service|flag-service|targeting-service|evaluation-service|analytics-service",
        "current": { "text": "All", "value": "$__all" }
      },
      {
        "name": "busca",
        "label": "Busca nos logs",
        "type": "textbox",
        "query": ""
      }
    ]
  },
  "panels": [
    {
      "type": "row", "title": "Cluster", "collapsed": false,
      "gridPos": { "x": 0, "y": 0, "w": 24, "h": 1 }
    },
    {
      "type": "stat", "title": "Nós prontos",
      "datasource": { "type": "prometheus", "uid": "prometheus" },
      "gridPos": { "x": 0, "y": 1, "w": 4, "h": 4 },
      "targets": [{ "refId": "A", "expr": "sum(kube_node_status_condition{condition=\"Ready\",status=\"true\"})" }]
    },
    {
      "type": "stat", "title": "Pods Running (serviços)",
      "datasource": { "type": "prometheus", "uid": "prometheus" },
      "gridPos": { "x": 4, "y": 1, "w": 4, "h": 4 },
      "targets": [{ "refId": "A", "expr": "sum(kube_pod_status_phase{phase=\"Running\", namespace=~\"$servico\"})" }]
    },
    {
      "type": "gauge", "title": "CPU do cluster",
      "datasource": { "type": "prometheus", "uid": "prometheus" },
      "gridPos": { "x": 8, "y": 1, "w": 4, "h": 4 },
      "fieldConfig": { "defaults": { "unit": "percentunit", "min": 0, "max": 1,
        "thresholds": { "mode": "absolute", "steps": [
          { "color": "green", "value": null }, { "color": "orange", "value": 0.7 }, { "color": "red", "value": 0.9 } ] } } },
      "targets": [{ "refId": "A", "expr": "1 - avg(rate(node_cpu_seconds_total{mode=\"idle\"}[5m]))" }]
    },
    {
      "type": "gauge", "title": "Memória do cluster",
      "datasource": { "type": "prometheus", "uid": "prometheus" },
      "gridPos": { "x": 12, "y": 1, "w": 4, "h": 4 },
      "fieldConfig": { "defaults": { "unit": "percentunit", "min": 0, "max": 1,
        "thresholds": { "mode": "absolute", "steps": [
          { "color": "green", "value": null }, { "color": "orange", "value": 0.75 }, { "color": "red", "value": 0.9 } ] } } },
      "targets": [{ "refId": "A", "expr": "1 - sum(node_memory_MemAvailable_bytes) / sum(node_memory_MemTotal_bytes)" }]
    },
    {
      "type": "stat", "title": "Requisições/s (total)",
      "datasource": { "type": "prometheus", "uid": "prometheus" },
      "gridPos": { "x": 16, "y": 1, "w": 4, "h": 4 },
      "fieldConfig": { "defaults": { "unit": "reqps" } },
      "targets": [{ "refId": "A", "expr": "sum(rate(http_server_request_duration_seconds_count{job=~\"$servico\"}[5m]))" }]
    },
    {
      "type": "stat", "title": "Restarts de contêiner (1h)",
      "datasource": { "type": "prometheus", "uid": "prometheus" },
      "gridPos": { "x": 20, "y": 1, "w": 4, "h": 4 },
      "fieldConfig": { "defaults": { "thresholds": { "mode": "absolute", "steps": [
        { "color": "green", "value": null }, { "color": "red", "value": 1 } ] } } },
      "targets": [{ "refId": "A", "expr": "sum(increase(kube_pod_container_status_restarts_total{namespace=~\"$servico\"}[1h]))" }]
    },
    {
      "type": "timeseries", "title": "CPU por serviço (cores)",
      "datasource": { "type": "prometheus", "uid": "prometheus" },
      "gridPos": { "x": 0, "y": 5, "w": 12, "h": 8 },
      "targets": [{ "refId": "A", "legendFormat": "{{namespace}}",
        "expr": "sum by (namespace) (rate(container_cpu_usage_seconds_total{container!=\"\", namespace=~\"$servico\"}[5m]))" }]
    },
    {
      "type": "timeseries", "title": "Memória por serviço (working set)",
      "datasource": { "type": "prometheus", "uid": "prometheus" },
      "gridPos": { "x": 12, "y": 5, "w": 12, "h": 8 },
      "fieldConfig": { "defaults": { "unit": "bytes" } },
      "targets": [{ "refId": "A", "legendFormat": "{{namespace}}",
        "expr": "sum by (namespace) (container_memory_working_set_bytes{container!=\"\", namespace=~\"$servico\"})" }]
    },
    {
      "type": "row", "title": "Microsserviços (OpenTelemetry)", "collapsed": false,
      "gridPos": { "x": 0, "y": 13, "w": 24, "h": 1 }
    },
    {
      "type": "timeseries", "title": "Taxa de requisições por serviço",
      "datasource": { "type": "prometheus", "uid": "prometheus" },
      "gridPos": { "x": 0, "y": 14, "w": 8, "h": 8 },
      "fieldConfig": { "defaults": { "unit": "reqps" } },
      "targets": [{ "refId": "A", "legendFormat": "{{job}}",
        "expr": "sum by (job) (rate(http_server_request_duration_seconds_count{job=~\"$servico\"}[5m]))" }]
    },
    {
      "type": "timeseries", "title": "Taxa de erros 5xx por serviço",
      "datasource": { "type": "prometheus", "uid": "prometheus" },
      "gridPos": { "x": 8, "y": 14, "w": 8, "h": 8 },
      "fieldConfig": { "defaults": { "unit": "percent",
        "thresholds": { "mode": "absolute", "steps": [
          { "color": "green", "value": null }, { "color": "red", "value": 5 } ] },
        "custom": { "thresholdsStyle": { "mode": "line" } } } },
      "targets": [{ "refId": "A", "legendFormat": "{{job}}",
        "expr": "100 * (sum by (job) (rate(http_server_request_duration_seconds_count{job=~\"$servico\", http_response_status_code=~\"5..\"}[5m])) or (0 * sum by (job) (rate(http_server_request_duration_seconds_count{job=~\"$servico\"}[5m])))) / sum by (job) (rate(http_server_request_duration_seconds_count{job=~\"$servico\"}[5m]))" }]
    },
    {
      "type": "timeseries", "title": "Latência p95 por serviço",
      "datasource": { "type": "prometheus", "uid": "prometheus" },
      "gridPos": { "x": 16, "y": 14, "w": 8, "h": 8 },
      "fieldConfig": { "defaults": { "unit": "s" } },
      "targets": [{ "refId": "A", "legendFormat": "{{job}}",
        "expr": "histogram_quantile(0.95, sum by (job, le) (rate(http_server_request_duration_seconds_bucket{job=~\"$servico\"}[5m])))" }]
    },
    {
      "type": "row", "title": "Logs", "collapsed": false,
      "gridPos": { "x": 0, "y": 22, "w": 24, "h": 1 }
    },
    {
      "type": "logs", "title": "Logs em tempo real",
      "datasource": { "type": "loki", "uid": "loki" },
      "gridPos": { "x": 0, "y": 23, "w": 24, "h": 12 },
      "options": { "showTime": true, "wrapLogMessage": true, "sortOrder": "Descending", "enableLogDetails": true },
      "targets": [{ "refId": "A", "expr": "{k8s_namespace_name=~\"$servico\"} |~ \"(?i)$busca\"" }]
    }
  ]
}
```

> Os datasources são referenciados pelos UIDs `prometheus` (padrão do
> `kube-prometheus-stack`) e `loki` (definido em `additionalDataSources`).
> Confira em **Connections > Data sources** se algum painel ficar sem dados.

## 7. Alerta inteligente, PagerDuty e Slack

O alerta e os contact points são provisionados como arquivo. Assim a
configuração sobrevive a restarts do Grafana (que não tem volume persistente)
e fica versionada. As chaves entram por variável de ambiente (`${VAR}`, vindas
do Secret `grafana-alerting`), e no Git fica só o nome delas.

> Nos arquivos de provisioning o Grafana interpola `$VAR`. Um `$` literal
> (como o `$values` dos templates) precisa ser escrito como `$$`.

### 7.1 Regra: taxa de 5xx do auth-service > 5%

`observability/manifests/alerting/alert-rules.yaml`:

```yaml
apiVersion: 1
groups:
  - orgId: 1
    name: toggle-master-slo
    folder: ToggleMaster
    interval: 1m
    rules:
      - uid: auth-service-5xx-rate
        title: auth-service - taxa de erros 5xx acima de 5%
        condition: C
        data:
          - refId: A
            relativeTimeRange: { from: 300, to: 0 }
            datasourceUid: prometheus
            model:
              refId: A
              instant: true
              # % de respostas 5xx nos últimos 5 min. Sem tráfego o resultado
              # é vazio (NoData), tratado como OK.
              expr: >-
                100 * (sum(rate(http_server_request_duration_seconds_count{job="auth-service", http_response_status_code=~"5.."}[5m])) or vector(0))
                / sum(rate(http_server_request_duration_seconds_count{job="auth-service"}[5m]))
          - refId: C
            datasourceUid: __expr__
            model:
              refId: C
              type: threshold
              expression: A
              conditions:
                - evaluator: { type: gt, params: [5] }
        for: 2m                 # precisa ficar acima de 5% por 2 min (evita falso positivo)
        noDataState: OK
        execErrState: Error
        labels:
          severity: critical
          service: auth-service
          namespace: auth-service
          deployment: auth-service
          self_healing: "true"
        annotations:
          summary: "auth-service com {{ printf \"%.1f\" $$values.A.Value }}% de respostas 5xx"
          description: >-
            Mais de 5% das requisições ao auth-service retornaram HTTP 5xx nos
            últimos 5 minutos. A automação de self-healing vai executar
            rollout restart em deployment/auth-service.
          runbook_url: https://github.com/sbaron81/fiap-postech-fase4/actions/workflows/self-healing.yml
          # Grafana serve em /grafana (ingress e port-forward): http://<endereco-do-lb>/grafana/d/toggle-master
          dashboard: http://localhost:3000/grafana/d/toggle-master
```

### 7.2 Contact points e roteamento

`observability/manifests/alerting/contact-points.yaml`. O contact point tem 3
integrações, e todas disparam juntas:

```yaml
apiVersion: 1

contactPoints:
  - orgId: 1
    name: toggle-master-incidentes
    receivers:
      # 1) Abre (e resolve) o incidente no PagerDuty
      - uid: tm-pagerduty
        type: pagerduty
        settings:
          integrationKey: ${PAGERDUTY_INTEGRATION_KEY}
          severity: critical
          component: '{{ .CommonLabels.service }}'
          class: http-5xx
          summary: '{{ .CommonAnnotations.summary }}'

      # 2) Notificação detalhada no Slack
      - uid: tm-slack
        type: slack
        settings:
          url: ${SLACK_WEBHOOK_URL}
          title: >-
            {{ if eq .Status "firing" }}:rotating_light: ALERTA{{ else }}:white_check_mark: RESOLVIDO{{ end }}
            - {{ .CommonLabels.alertname }}
          text: |-
            {{ range .Alerts }}
            *Serviço:* `{{ .Labels.service }}` (namespace `{{ .Labels.namespace }}`)
            *Severidade:* {{ .Labels.severity }}
            *Resumo:* {{ .Annotations.summary }}
            *Detalhes:* {{ .Annotations.description }}
            *Início:* {{ .StartsAt.Format "02/01/2006 15:04:05 MST" }}
            *Ações:* incidente aberto no PagerDuty | self-healing: {{ .Annotations.runbook_url }}
            {{ end }}

      # 3) Self-healing: dispara o workflow no GitHub (repository_dispatch)
      - uid: tm-github-self-healing
        type: webhook
        disableResolveMessage: true
        settings:
          url: https://api.github.com/repos/sbaron81/fiap-postech-fase4/dispatches
          httpMethod: POST
          authorization_scheme: Bearer
          authorization_credentials: ${GITHUB_DISPATCH_TOKEN}
          # Grafana 12+: corpo customizado no formato que a API do GitHub espera
          payload:
            template: |-
              {"event_type": "grafana-alert", "client_payload": {"status": "{{ .Status }}", "alertname": "{{ .CommonLabels.alertname }}", "namespace": "{{ .CommonLabels.namespace }}", "deployment": "{{ .CommonLabels.deployment }}"}}

policies:
  - orgId: 1
    receiver: toggle-master-incidentes
    group_by: [grafana_folder, alertname]
    group_wait: 30s
    group_interval: 5m
    repeat_interval: 1h
```

Depois do sync, confira em **Alerting > Contact points** e use o botão
**Test** de cada integração. O teste do webhook do GitHub deve criar um run
do workflow do passo 8, que termina sem fazer nada porque o payload de teste
não traz `deployment`.

> Se a sua versão do Grafana rejeitar algum campo, configure o contact point
> pela UI, use **Export** e copie o YAML gerado para este arquivo, trocando os
> segredos por `${VAR}`.

## 8. Self-healing com GitHub Actions

Quando o alerta dispara, o Grafana chama `POST /repos/.../dispatches`, o
GitHub roda o workflow e o workflow executa
`kubectl rollout restart deployment/auth-service` no cluster.

### 8.1 Identidade restrita no cluster

O workflow não usa as credenciais de admin. Ele usa uma ServiceAccount que
só pode reiniciar deployments no namespace `auth-service`.

`observability/manifests/self-healer.yaml`:

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: self-healer
  namespace: auth-service
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: self-healer
  namespace: auth-service
rules:
  - apiGroups: ["apps"]
    resources: ["deployments"]
    verbs: ["get", "list", "watch", "patch"]
  - apiGroups: ["apps"]
    resources: ["replicasets"]
    verbs: ["get", "list", "watch"]
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["get", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: self-healer
  namespace: auth-service
subjects:
  - kind: ServiceAccount
    name: self-healer
    namespace: auth-service
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: self-healer
---
# Token de longa duração da ServiceAccount. Quem gera o token é o Kubernetes,
# então nada sensível fica no Git.
apiVersion: v1
kind: Secret
metadata:
  name: self-healer-token
  namespace: auth-service
  annotations:
    kubernetes.io/service-account.name: self-healer
type: kubernetes.io/service-account-token
```

### 8.2 Kubeconfig como secret do GitHub

Depois que o `observability-config` sincronizar:

```bash
CLUSTER=fiap-fase4
SERVER=$(aws eks describe-cluster --name "$CLUSTER" --query cluster.endpoint --output text)
CA=$(kubectl -n auth-service get secret self-healer-token -o jsonpath='{.data.ca\.crt}')
TOKEN=$(kubectl -n auth-service get secret self-healer-token -o jsonpath='{.data.token}' | base64 -d)

cat > self-healer.kubeconfig <<EOF
apiVersion: v1
kind: Config
clusters:
  - name: $CLUSTER
    cluster: { server: $SERVER, certificate-authority-data: $CA }
users:
  - name: self-healer
    user: { token: $TOKEN }
contexts:
  - name: self-healer
    context: { cluster: $CLUSTER, user: self-healer, namespace: auth-service }
current-context: self-healer
EOF

# testa as permissões: precisa responder "yes" e depois "no"
kubectl --kubeconfig self-healer.kubeconfig auth can-i patch deployment/auth-service
kubectl --kubeconfig self-healer.kubeconfig auth can-i delete deployment/auth-service

base64 -w0 self-healer.kubeconfig   # copie a saída
rm self-healer.kubeconfig
```

No `fiap-postech-fase4`: **Settings > Secrets and variables > Actions > New
repository secret**, com nome `SELF_HEALER_KUBECONFIG` e valor igual à saída
do `base64`.

> O endpoint do EKS precisa ser público (`endpoint_public_access = true`,
> o padrão do módulo) para o runner do GitHub alcançá-lo.

### 8.3 Workflow

`.github/workflows/self-healing.yml` (neste repositório):

```yaml
name: self-healing

on:
  # disparado pelo contact point "webhook" do Grafana
  repository_dispatch:
    types: [grafana-alert]
  # disparo manual, para testar sem o alerta
  workflow_dispatch:
    inputs:
      namespace: { default: auth-service, required: true }
      deployment: { default: auth-service, required: true }

permissions:
  contents: read

concurrency:
  group: self-healing
  cancel-in-progress: false

jobs:
  rollout-restart:
    # só age quando o alerta está disparando (ignora "resolved")
    if: github.event_name == 'workflow_dispatch' || github.event.client_payload.status == 'firing'
    runs-on: ubuntu-latest
    timeout-minutes: 10
    env:
      NAMESPACE: ${{ github.event.client_payload.namespace || inputs.namespace }}
      DEPLOYMENT: ${{ github.event.client_payload.deployment || inputs.deployment }}
      ALERT: ${{ github.event.client_payload.alertname || 'manual' }}
    steps:
      - name: Validar alvo (allowlist)
        run: |
          case "$NAMESPACE/$DEPLOYMENT" in
            auth-service/auth-service) echo "alvo permitido: $NAMESPACE/$DEPLOYMENT" ;;
            *) echo "::error::alvo não permitido: '$NAMESPACE/$DEPLOYMENT'"; exit 1 ;;
          esac

      - name: Configurar kubeconfig
        env:
          KUBECONFIG_B64: ${{ secrets.SELF_HEALER_KUBECONFIG }}
        run: |
          mkdir -p ~/.kube
          echo "$KUBECONFIG_B64" | base64 -d > ~/.kube/config
          chmod 600 ~/.kube/config

      - name: Estado antes
        run: kubectl -n "$NAMESPACE" get deployment "$DEPLOYMENT" -o wide

      - name: Rollout restart
        run: kubectl -n "$NAMESPACE" rollout restart deployment/"$DEPLOYMENT"

      - name: Aguardar rollout
        run: kubectl -n "$NAMESPACE" rollout status deployment/"$DEPLOYMENT" --timeout=180s

      - name: Resumo
        if: always()
        run: |
          {
            echo "### Self-healing: \`$NAMESPACE/$DEPLOYMENT\`"
            echo "- Alerta: $ALERT"
            echo "- Resultado: ${{ job.status }}"
            echo '```'
            kubectl -n "$NAMESPACE" get pods -l app="$DEPLOYMENT" -o wide || true
            echo '```'
          } >> "$GITHUB_STEP_SUMMARY"
```

Detalhes de segurança:

- O alvo vem do payload do webhook, então passa por uma **allowlist** antes
  de qualquer `kubectl`.
- Os valores do payload entram via `env:` e nunca interpolados direto no
  `run:`, o que evita injeção de comando.
- O `rollout restart` só acrescenta a annotation
  `kubectl.kubernetes.io/restartedAt` no template do pod. O ArgoCD não trata
  isso como drift e não desfaz o restart.

## 9. Validação ponta a ponta

```bash
cd terraform
INGRESS=$(terraform output -raw ingress_get_address | bash)
MASTER_KEY='<MASTER_KEY do auth-service>'
```

### 9.1 Traces e Service Map (New Relic)

Gere tráfego no `evaluation-service` usando uma flag que já existe:

```bash
for i in $(seq 1 300); do
  curl -s -o /dev/null "http://$INGRESS/evaluate/evaluate?user_id=user-$i&flag_name=<flag>"
  sleep 0.5
done
```

No New Relic:

- **APM & Services**: os 5 serviços aparecem como entidades OpenTelemetry.
- **evaluation-service > Distributed tracing**: abra um trace de
  `GET /evaluate` e veja o caminho Redis → flag-service → auth-service →
  targeting-service → SQS → analytics-service → DynamoDB.
- **evaluation-service > Service map**: mostra o mapa de dependências com os
  5 serviços e os recursos externos (Redis, PostgreSQL, SQS, DynamoDB).

### 9.2 Métricas e logs (Grafana)

- **Dashboards > ToggleMaster - Saúde do Ecossistema**: os painéis de
  requisições e latência se mexem com o loop acima, e os logs aparecem no
  painel inferior.
- **Explore > Prometheus**: `http_server_request_duration_seconds_count`
  deve ter séries com `job` igual a cada serviço.
- **Explore > Loki**: `{k8s_namespace_name="auth-service"}`.

### 9.3 Alerta → incidente → Slack → self-healing

```bash
# 1. Liga a falha simulada (2 réplicas: repita para cair nos dois pods)
for i in 1 2 3 4; do
  curl -s -X POST -H "Authorization: Bearer $MASTER_KEY" "http://$INGRESS/auth/admin/chaos"
done

# 2. Gera tráfego no auth-service (vai receber 500)
for i in $(seq 1 600); do
  curl -s -o /dev/null -w '%{http_code}\n' "http://$INGRESS/auth/validate" -H "Authorization: Bearer x"
  sleep 0.5
done | sort | uniq -c
```

Linha do tempo esperada (cerca de 3 a 5 minutos):

1. **Grafana > Alerting > Alert rules**: a regra passa de *Normal* para
   *Pending* e, depois de 2 min, para *Firing*.
2. **PagerDuty**: incidente aberto no serviço `ToggleMaster - auth-service`.
3. **Slack**: mensagem com serviço, severidade, taxa de erro e links.
4. **GitHub > Actions > self-healing**: run disparado por `repository_dispatch`
   executa o `rollout restart`.
5. Os pods novos sobem sem a flag de caos, os 5xx param, o alerta volta para
   *Normal*, o incidente do PagerDuty é resolvido e chega um "RESOLVIDO" no Slack.

```bash
kubectl -n auth-service get pods -w     # pods sendo recriados
```

Tire prints de cada etapa para a entrega.

## 10. Troubleshooting

| Sintoma | Verificação |
|---|---|
| Pods em `Pending` | `kubectl describe pod`: falta CPU/memória ou o limite de pods por nó (ver passo 1) |
| `kube-prometheus-stack` OutOfSync / erro de CRD | confirme `ServerSideApply=true` na Application |
| Grafana em `CreateContainerConfigError` | os Secrets `grafana-admin` / `grafana-alerting` não existem (passo 3) |
| Sem métricas `http_server_*` | `kubectl -n observability logs ds/otel-collector`: erros no `prometheusremotewrite`? Confirme `enableRemoteWriteReceiver` |
| Métricas Python com nome `http_server_duration_*` | falta `OTEL_SEMCONV_STABILITY_OPT_IN=http` no ConfigMap |
| Nada no New Relic | license key errada (403 no log do collector) ou região errada (US x EU) |
| Trace "quebrado" (flag/targeting em traces separados) | o `evaluation-service` não está usando `NewRequestWithContext(ctx)` e `otelhttp.NewTransport` |
| analytics-service fora do trace | falta `MessageAttributeNames=["All"]` no `receive_message` ou o `Inject` no `sqs.go` |
| Contact point do GitHub retorna 404/403 | PAT sem *Contents: Read and write* no repositório, ou PAT expirado |
| Workflow falha no `kubectl` | token da SA inválido (o Secret foi recriado?) ou endpoint do EKS privado |

## Checklist da entrega

- [ ] Prometheus, Loki, Grafana e OTel Collector instalados via ArgoCD (`fiap-gitops/observability`)
- [ ] Dashboard com recursos do cluster, taxa de requisições/erros/latência e logs em tempo real
- [ ] OTel Collector recebendo métricas, logs e traces e roteando para Prometheus, Loki e New Relic
- [ ] 5 serviços instrumentados com OpenTelemetry (código + Dockerfile)
- [ ] Trace distribuído partindo do `evaluation-service` visível no New Relic
- [ ] Service Map do New Relic com os 5 serviços
- [ ] Alerta de 5xx > 5% no auth-service
- [ ] Incidente aberto automaticamente no PagerDuty
- [ ] Notificação detalhada no Slack
- [ ] GitHub Action de self-healing executando `rollout restart` sem intervenção humana
