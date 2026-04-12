# paperless-ngx Helm Chart

A Helm chart for deploying the [paperless-ngx](https://docs.paperless-ngx.com/) document management stack on Kubernetes with AI-powered document classification and vision OCR.

## Components

| Component | Required | Description |
|-----------|----------|-------------|
| **paperless-ngx** | Yes | Core document management application |
| **PostgreSQL** (CNPG) | Yes | Database via CloudNativePG operator |
| **Redis** (redis-ha) | Yes | Task queue via DandyDeveloper redis-ha subchart |
| **LiteLLM** | No | Unified OpenAI-compatible gateway — routes requests to multiple LLM backends by model name |
| **Gotenberg** | No | Office document (Word, Excel) to PDF conversion |
| **Apache Tika** | No | Text extraction from complex document formats |
| **Paperless AI** | No | Automatic tagging, classification, correspondent detection, and title generation |
| **Paperless GPT** | No | Vision OCR via local LLM (e.g. qwen25-vl-7b) |
| **Paperless GPT Cloud** | No | Vision OCR via cloud LLM (e.g. Claude Sonnet, GPT-4o) for complex documents |
| **Open WebUI** | No | AI chat interface for querying documents via custom tools |

## Prerequisites

- Kubernetes 1.26+
- Helm 3.x
- [CloudNativePG operator](https://cloudnative-pg.io/) installed in the cluster
- A StorageClass capable of provisioning PersistentVolumes (or pre-created PVs for NFS/local storage)

## Architecture

```
                    ┌─── Gotenberg (office doc conversion)
                    ├─── Apache Tika (text extraction)
paperless-ngx ─────┤
  (core app)       ├─── PostgreSQL (CNPG)
                    └─── Redis (redis-ha)

                    ┌─── Paperless AI (auto classification)
LiteLLM ───────────┤─── Paperless GPT (local vision OCR)
  (AI gateway)     ├─── Paperless GPT Cloud (cloud vision OCR)
                    └─── Open WebUI (document search chat)
                              │
                              └─── paperless-tools (custom search tools)
                                   https://github.com/mattr7m/paperless-tools
```

LiteLLM acts as a unified proxy — all AI components connect to it, and it routes requests to the correct backend (local llama-server or cloud API) based on model name.

## Installation

```bash
helm dependency update .
helm install paperless-ngx . -n <namespace> -f my-values.yaml
```

Or via ArgoCD with multi-source (chart repo + ops/values repo).

---

## Post-Install Setup

### 1. Wait for PostgreSQL and Redis

```bash
kubectl get pods -n <namespace> -l cnpg.io/cluster=<release>-postgresql
kubectl get pods -n <namespace> | grep redis
```

PostgreSQL is ready when the CNPG pod shows `1/1 Running`. Redis is ready at `3/3 Running`.

### 2. Create Superuser

```bash
kubectl exec -it -n <namespace> deploy/<release> -- python3 manage.py createsuperuser
```

### 3. Create Service Accounts and API Tokens

Create a **separate paperless-ngx user** for each service that connects to the API. This provides distinct audit trails and permission control.

| User | Purpose | Permissions |
|------|---------|-------------|
| `paperless-ai` | Auto classification | Superuser (creates tags, types, correspondents) |
| `paperless-gpt-local` | Local vision OCR | Superuser (reads/updates all documents) |
| `paperless-gpt-cloud` | Cloud vision OCR | Superuser (reads/updates all documents) |
| `open-webui` | Document search chat | Superuser (reads all documents, tags, types) |

For each user:
1. Create in paperless-ngx UI: **Settings > Users & Groups**
2. Grant **Superuser status**
3. Generate API token: **Settings > Django Admin > Authorisation Tokens > Add**
4. Create Kubernetes secret:

```bash
kubectl create secret generic <service>-token \
  -n <namespace> \
  --from-literal=PAPERLESS_API_TOKEN=<token> \
  --from-literal=PAPERLESS_USERNAME=<username>
```

Secret naming convention:

| Secret Name | Used By |
|------------|---------|
| `paperless-ai-token` | Paperless AI |
| `paperless-gpt-local-token` | Paperless GPT (local) |
| `paperless-gpt-cloud-token` | Paperless GPT Cloud |

The Open WebUI token is configured in the tool's Valves (UI), not as a Kubernetes secret.

### 4. Reference Secrets in Values

```yaml
paperlessAi:
  existingSecret:
    apiToken:
      name: paperless-ai-token
      key: PAPERLESS_API_TOKEN
    paperlessUsername:
      name: paperless-ai-token
      key: PAPERLESS_USERNAME

paperlessGpt:
  existingSecret:
    apiToken:
      name: paperless-gpt-local-token
      key: PAPERLESS_API_TOKEN
    paperlessUsername:
      name: paperless-gpt-local-token
      key: PAPERLESS_USERNAME

paperlessGptCloud:
  existingSecret:
    apiToken:
      name: paperless-gpt-cloud-token
      key: PAPERLESS_API_TOKEN
    paperlessUsername:
      name: paperless-gpt-cloud-token
      key: PAPERLESS_USERNAME
```

### 5. (Production) Create Django Secret Key

```bash
kubectl create secret generic paperless-secret-key \
  -n <namespace> \
  --from-literal=PAPERLESS_SECRET_KEY=$(openssl rand -hex 32)
```

```yaml
paperless:
  existingSecret:
    secretKey:
      name: paperless-secret-key
      key: PAPERLESS_SECRET_KEY
```

### 6. Create Tags

In the paperless-ngx UI at **Manage > Tags**, create the following. Set **no owner** on all tags so all service accounts can access them.

| Tag | Matching Algorithm | Purpose |
|-----|-------------------|---------|
| `paperless-gpt-ocr-local-auto` | Exact | Triggers local vision OCR |
| `paperless-gpt-ocr-cloud-auto` | Exact | Triggers cloud vision OCR |
| `local-ocr` | None | Persistent tag — doc was OCR'd by local model |
| `cloud-ocr` | None | Persistent tag — doc was OCR'd by cloud model |
| `email` | None | Applied to email-ingested attachments (optional) |

### 7. Create Consume Subfolders

Create nested subfolders in the consume share. The outer folder applies a persistent source tag; the inner folder triggers the OCR pipeline.

```
<consume-share>/
├── local-ocr/
│   └── paperless-gpt-ocr-local-auto/
├── cloud-ocr/
│   └── paperless-gpt-ocr-cloud-auto/
```

Documents dropped in these folders are auto-tagged by paperless-ngx (via `PAPERLESS_CONSUMER_SUBDIRS_AS_TAGS`). After OCR, the trigger tag is removed but `local-ocr` / `cloud-ocr` remains.

### 8. Configure Paperless AI

The Paperless AI wizard must be completed through the web UI after deployment. Env vars seed defaults but the wizard writes its own config.

Open the Paperless AI ingress URL and complete the wizard:

**AI Provider:**

| Field | Value |
|-------|-------|
| AI Provider | Custom / OpenAI Compatible |
| Base URL | `http://<release>-litellm:4000/v1` |
| API Key | `sk-not-needed` |
| Model | `qwen3-235b` (or your model name) |
| Token Limit | `4096` |
| Response Tokens | `2000` |

**Paperless Connection:**

| Field | Value |
|-------|-------|
| Paperless URL | `http://<release>:8000/api` |
| API Token | (pre-populated from secret) |
| Username | `paperless-ai` |

**Advanced Settings:**

| Setting | Value |
|---------|-------|
| Use existing Correspondents and Tags? | **No** |
| Scan Interval | `*/30 * * * *` (cron format, every 30 min) |
| Process only specific pre tagged documents? | **No** |
| Tags | (leave empty — do not enter literal values) |
| Add AI-processed tag? | **Yes** — tag name: `ai-processed` |
| Use specific tags in prompt? | **No** |
| Disable automatic processing? | **Unchecked** (auto enabled) |

**AI Functions — enable all:**

| Function | Enable |
|----------|--------|
| Tags Assignment | Yes |
| Correspondent Detection | Yes |
| Document Type Classification | Yes |
| Title Generation | Yes |
| Custom Fields | No (optional) |

**Gotchas:**
- `SCAN_INTERVAL` must be cron format (`*/30 * * * *`), not plain minutes
- `PROCESS_PREDEFINED_DOCUMENTS` must be `no` in the values to process all documents
- Documents with the `ai-processed` tag are skipped — remove it to re-process a document

### 9. Configure Open WebUI

Open the Open WebUI ingress URL, create an admin account, then set up the paperless search tool.

**Register the tool:**
1. Go to **Workspace > Tools > + (New Tool)**
2. Paste the contents of `paperless_search.py` from [paperless-tools](https://github.com/mattr7m/paperless-tools)
3. Click **Save**

**Configure the tool (Valves):**
1. Click the **gear icon** on the tool
2. Set `base_url` to `http://<release>:8000` (internal service URL)
3. Set `api_token` to the `open-webui` user's API token

**Enable on model:**
1. Go to **Workspace > Models > select your model > Tools**
2. Enable "Paperless-ngx Document Search"

**Enable native function calling:**
1. Go to **Admin > Settings > Models > (select model) > Advanced Parameters > Function Calling > Native**

**Set system prompt** on the model at **Workspace > Models > (select model) > System Prompt**:

```
You have access to the user's personal document library via the Paperless-ngx
search tools. When the user asks about events, purchases, bills, invoices,
maintenance records, or any information that could be in their scanned documents,
ALWAYS use the search tools first before answering from general knowledge.
The user's documents contain receipts, mail, flyers, statements, and other
scanned paperwork.

When searching, use simple keywords that would literally appear in the document
text. Do not include words like "upcoming", "recent", "latest", or "my" in
search queries — these words won't be in the documents.
```

### 10. Object Permissions

Tags, correspondents, and document types created by AI are **private by default** (owned by the creating user). To make them visible to all users:
- Clear the **Owner** field on each object, or
- Configure default permissions in **Settings > Permissions** so new objects have no owner

---

## Storage

The chart supports three storage modes for paperless-ngx's media, consume, and export volumes.

### Dynamic Provisioning (default)

The chart creates PVCs automatically. Set `storageClass` and `size`:

```yaml
paperless:
  persistence:
    media:
      size: 50Gi
      storageClass: my-storage-class
```

### Existing Claims (NFS, local PVs)

Pre-create PVs/PVCs externally and reference them:

```yaml
paperless:
  persistence:
    media:
      existingClaim: my-media-pvc
    consume:
      existingClaim: my-consume-pvc
    export:
      existingClaim: my-export-pvc
```

When `existingClaim` is set, the chart skips PVC creation.

### Node Selector

Pin paperless-ngx to a specific node (e.g. for local storage on an Unraid-hosted worker):

```yaml
paperless:
  nodeSelector:
    storage/unraid: "true"
```

### Consumer Polling

NFS and VM-passthrough mounts don't support inotify. Enable polling:

```yaml
paperless:
  env:
    PAPERLESS_CONSUMER_POLLING: "30"
```

---

## LiteLLM — AI Gateway

LiteLLM provides a single endpoint for all AI components. It routes requests to the correct backend based on the model name in the request.

### Local Models

```yaml
litellm:
  enabled: true
  models:
    - name: qwen3-235b
      provider: openai
      apiBase: "http://192.168.100.240:8081/v1"
    - name: qwen25-vl-7b
      provider: openai
      apiBase: "http://192.168.100.240:8082/v1"
```

### Cloud Models

Cloud API keys are injected via `existingSecret`:

```bash
kubectl create secret generic litellm-cloud-keys \
  -n <namespace> \
  --from-literal=ANTHROPIC_API_KEY=sk-ant-...
```

```yaml
litellm:
  existingSecret: litellm-cloud-keys
  models:
    - name: claude-sonnet-4-6
      provider: anthropic
      apiKeyEnv: ANTHROPIC_API_KEY
      tpm: 7000
      rpm: 1
      maxParallelRequests: 1
```

Rate limiting (`tpm`, `rpm`, `maxParallelRequests`) prevents hitting cloud API rate limits when paperless-gpt processes multi-page documents in parallel.

---

## Vision OCR — Local vs Cloud

Two paperless-gpt instances can run side-by-side, each watching a different tag:

| Instance | Trigger Tag | Model | Use Case |
|----------|------------|-------|----------|
| `paperlessGpt` | `paperless-gpt-ocr-local-auto` | Local (e.g. qwen25-vl-7b) | Sensitive documents |
| `paperlessGptCloud` | `paperless-gpt-ocr-cloud-auto` | Cloud (e.g. Claude Sonnet) | Complex/poor-quality scans |

### OCR Source Tags via Nested Subfolders

Use nested consume subfolders to automatically tag documents with their OCR source:

```
consume/
├── local-ocr/
│   └── paperless-gpt-ocr-local-auto/   → tagged: local-ocr + paperless-gpt-ocr-local-auto
├── cloud-ocr/
│   └── paperless-gpt-ocr-cloud-auto/   → tagged: cloud-ocr + paperless-gpt-ocr-cloud-auto
```

After OCR processing, the trigger tag is removed but `local-ocr` or `cloud-ocr` remains — providing a permanent record of which model processed the document.

Requires:
```yaml
paperless:
  env:
    PAPERLESS_CONSUMER_RECURSIVE: "true"
    PAPERLESS_CONSUMER_SUBDIRS_AS_TAGS: "true"
```

Tags to create in paperless-ngx: `local-ocr`, `cloud-ocr`, `paperless-gpt-ocr-local-auto`, `paperless-gpt-ocr-cloud-auto`.

---

## Paperless AI — Auto Classification

Paperless AI scans documents on a cron schedule and uses an LLM to assign tags, correspondents, document types, and titles.

**Configuration is done via the Paperless AI web UI** after deployment — env vars seed defaults but the wizard must be completed.

Key env vars:

| Variable | Description | Example |
|----------|-------------|---------|
| `AI_PROVIDER` | `custom` for OpenAI-compatible (LiteLLM) | `custom` |
| `CUSTOM_BASE_URL` | LiteLLM endpoint | `http://<release>-litellm:4000/v1` |
| `CUSTOM_MODEL` | Model name | `qwen3-235b` |
| `SCAN_INTERVAL` | Cron format | `*/30 * * * *` |
| `PROCESS_PREDEFINED_DOCUMENTS` | `no` to process all docs | `no` |

**Gotchas:**
- `SCAN_INTERVAL` must be cron format (`*/30 * * * *`), not plain minutes
- `PROCESS_PREDEFINED_DOCUMENTS` must be `no` to process all documents
- Documents with the `ai-processed` tag are skipped — remove it to re-process

---

## Open WebUI — Document Search Chat

Open WebUI provides an AI chat interface connected to LiteLLM. Custom tools enable LLM-powered queries against the paperless-ngx document library.

The tool code is maintained separately: **[paperless-tools](https://github.com/mattr7m/paperless-tools)**

### Setup

1. Deploy Open WebUI via the chart (`openWebui.enabled: true`)
2. Register the tool: **Workspace > Tools > + > paste `paperless_search.py`**
3. Configure Valves (gear icon): set `base_url` and `api_token` for paperless-ngx
4. Enable on model: **Workspace > Models > select model > Tools > enable the tool**
5. Enable native function calling: **Admin > Settings > Models > Advanced > Function Calling > Native**
6. Set a system prompt on the model to guide tool usage (see paperless-tools README)

### Disabling Built-in RAG

Open WebUI downloads embedding models on first boot. Since we use custom tools for document retrieval, disable the built-in RAG:

```yaml
openWebui:
  env:
    RAG_EMBEDDING_MODEL: ""
    RAG_RERANKING_MODEL: ""
    ENABLE_RAG_WEB_SEARCH: "false"
```

---

## Values Reference

### paperless (core)

| Key | Default | Description |
|-----|---------|-------------|
| `paperless.image.tag` | `latest` | Image tag |
| `paperless.service.port` | `8000` | Service port |
| `paperless.nodeSelector` | `{}` | Node selector for scheduling |
| `paperless.tolerations` | `[]` | Pod tolerations |
| `paperless.persistence.{media,consume,export}.size` | `10Gi/5Gi/5Gi` | Volume sizes |
| `paperless.persistence.{media,consume,export}.existingClaim` | `""` | Use pre-created PVC |
| `paperless.ingress.enabled` | `false` | Enable ingress |
| `paperless.existingSecret.secretKey.name` | `""` | Django secret key |

### postgresql (CNPG)

| Key | Default | Description |
|-----|---------|-------------|
| `postgresql.instances` | `1` | Replicas (3+ for HA) |
| `postgresql.imageName` | `ghcr.io/cloudnative-pg/postgresql:16` | Image |
| `postgresql.storage.size` | `10Gi` | Storage size |

### redis (redis-ha subchart)

| Key | Default | Description |
|-----|---------|-------------|
| `redis.replicas` | `1` | Replicas (3+ for HA) |
| `redis.auth` | `false` | Enable auth |
| `redis.redis.config.min-replicas-to-write` | `0` | Must be 0 for single replica |

### litellm

| Key | Default | Description |
|-----|---------|-------------|
| `litellm.enabled` | `false` | Deploy LiteLLM |
| `litellm.existingSecret` | `""` | Secret with cloud API keys |
| `litellm.models` | `[]` | Model routing list |
| `litellm.models[].name` | | Model name |
| `litellm.models[].provider` | `openai` | LiteLLM provider |
| `litellm.models[].apiBase` | | Backend URL (local models) |
| `litellm.models[].apiKeyEnv` | | Env var name for API key (cloud models) |
| `litellm.models[].tpm` | | Tokens per minute limit |
| `litellm.models[].rpm` | | Requests per minute limit |
| `litellm.models[].maxParallelRequests` | | Max concurrent requests |

### paperlessAi / paperlessGpt / paperlessGptCloud

| Key | Default | Description |
|-----|---------|-------------|
| `*.enabled` | `false` | Deploy component |
| `*.env` | see values.yaml | Environment variables |
| `*.existingSecret.apiToken.name` | `""` | Secret with paperless API token |
| `*.ingress.enabled` | `false` | Enable ingress |

### openWebui

| Key | Default | Description |
|-----|---------|-------------|
| `openWebui.enabled` | `false` | Deploy Open WebUI |
| `openWebui.env` | `{}` | Environment variables |
| `openWebui.persistence.size` | `5Gi` | Data volume size |
| `openWebui.ingress.enabled` | `false` | Enable ingress |

---

## Secrets Summary

| Secret | Used By | Keys | Purpose |
|--------|---------|------|---------|
| CNPG auto-generated | paperless-ngx | `username`, `password` | Database credentials |
| `paperless-secret-key` | paperless-ngx | `PAPERLESS_SECRET_KEY` | Django secret key |
| `paperless-ai-token` | Paperless AI | `PAPERLESS_API_TOKEN`, `PAPERLESS_USERNAME` | API auth |
| `paperless-gpt-local-token` | Paperless GPT (local) | `PAPERLESS_API_TOKEN`, `PAPERLESS_USERNAME` | API auth |
| `paperless-gpt-cloud-token` | Paperless GPT Cloud | `PAPERLESS_API_TOKEN`, `PAPERLESS_USERNAME` | API auth |
| `litellm-cloud-keys` | LiteLLM | `ANTHROPIC_API_KEY` (or others) | Cloud LLM API keys |

Open WebUI's paperless API token is configured in the tool's Valves (UI), not as a Kubernetes secret.

---

## Retroactive Processing

After enabling Tika/Gotenberg on existing documents:

```bash
kubectl exec -n <namespace> deploy/<release> -- python3 manage.py document_index reindex
kubectl exec -n <namespace> deploy/<release> -- python3 manage.py document_archiver --all
kubectl exec -n <namespace> deploy/<release> -- python3 manage.py document_retagger
```

---

## Image Pre-Pull List

For clusters with image pre-pull deployments:

```
paperless-ngx=ghcr.io/paperless-ngx/paperless-ngx:latest;
paperless-ai=clusterzx/paperless-ai:latest;
paperless-gpt=ghcr.io/icereed/paperless-gpt:latest;
litellm=ghcr.io/berriai/litellm:main-latest;
open-webui=ghcr.io/open-webui/open-webui:main;
gotenberg=gotenberg/gotenberg:latest;
tika=apache/tika:latest;
redis=public.ecr.aws/docker/library/redis:8.2.4-alpine;
```
