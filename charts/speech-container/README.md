# speech-container — Azure AI Speech Disconnected Containers on Kubernetes

A production-ready Helm chart for deploying **Azure AI Speech disconnected containers** (Speech-to-Text and Neural Text-to-Speech) on **any conformant Kubernetes platform**, with first-class guidance for **Azure Kubernetes Service (AKS)**.

Replaces the abandoned `microsoft/cognitive-services-speech-onpremise` chart (v0.3.3, June 2021) with parameterised CPU/memory, modern Kubernetes APIs, taint+toleration scheduling, and secret-based credentials.

- **Chart repo**: `https://osshaikh.github.io/speechcontainer/`
- **Source**: `https://github.com/Osshaikh/speechcontainer`
- **App version**: 5.3.0 (STT) / 4.6.0 (TTS)
- **Chart version**: 1.1.4

---

## Table of Contents

1. [Platform compatibility](#platform-compatibility)
2. [Quickstart](#quickstart)
3. [Architecture overview](#architecture-overview)
4. [Capacity planning](#capacity-planning)
5. [Prerequisites](#prerequisites)
   - [Azure AI Speech resource](#1-azure-ai-speech-resource-billing-endpoint--api-key)
   - [Network / firewall whitelisting](#2-network--firewall-whitelisting)
   - [Node pools, taints & labels](#3-node-pools-taints--labels-split-pool-pattern)
   - [Speech credentials secret](#4-speech-credentials-secret)
   - [Azure Key Vault integration (AKS)](#4-speech-credentials-secret)
   - [Ingress controller](#5-ingress-controller)
6. [Installing the chart](#installing-the-chart)
7. [Configurable values reference](#configurable-values-reference)
8. [Install command examples](#install-command-examples)
9. [Adding additional language containers](#adding-additional-language-containers)
10. [Verifying the install](#verifying-the-install)
11. [Upgrading & rolling back](#upgrading--rolling-back)
12. [Uninstalling](#uninstalling)
13. [Troubleshooting](#troubleshooting)

---

## Platform compatibility

The chart targets **standard Kubernetes APIs** (Deployment, Service, Ingress, Secret, HPA) and works on any conformant cluster. Tested matrix:

| Platform | Status | Notes |
|---|---|---|
| **Azure Kubernetes Service (AKS)** | ✅ Validated | Recommended platform; native integrations for Key Vault, ACR, Workload Identity |
| **Amazon EKS** | ✅ Compatible | Use ALB ingress + IAM Roles for Service Accounts (IRSA) for secret access |
| **Google GKE** | ✅ Compatible | Use GCE ingress + Workload Identity for Secret Manager |
| **Red Hat OpenShift 4.x** | ✅ Compatible | Set `securityContext.runAsNonRoot=true`; use `Route` instead of `Ingress` |
| **Vanilla Kubernetes / kubeadm** | ✅ Compatible | Bring your own ingress controller and storage class |
| **k3s / k3d / kind** (dev) | ⚠️ Works | Resource minimums (4c STT, 6c TTS) often exceed laptop capacity |

**Required versions:**
- Kubernetes ≥ **1.27**
- Helm ≥ **3.10**
- An ingress controller (chart examples assume `ingress-nginx`, but any controller works)

> 💡 **Why AKS gets special guidance:** This chart originated for Azure customers running disconnected Speech in regulated environments. AKS-specific sections (Key Vault CSI driver, Workload Identity, ACR mirror) are flagged with **AKS** callouts; everything else is platform-neutral.

---

## Quickstart

For an experienced Kubernetes operator who already has a cluster and an Azure Speech resource with disconnected commitment:

```bash
# 1. Add chart repo
helm repo add speech-container https://osshaikh.github.io/speechcontainer/
helm repo update

# 2. Create namespace + credentials secret
kubectl create namespace speech
kubectl create secret generic speech-credentials -n speech \
  --from-literal=billing="https://<your-speech-resource>.cognitiveservices.azure.com/" \
  --from-literal=apikey="<your-speech-key>"

# 3. Pull example values to customize
helm pull speech-container/speech-container --untar
cd speech-container

# 4. Install English STT and TTS
helm install stt-en speech-container/speech-container -n speech \
  -f examples/stt-en.yaml --set secretRef.enabled=true

helm install tts-en speech-container/speech-container -n speech \
  -f examples/tts-en.yaml --set secretRef.enabled=true

# 5. Verify
kubectl get pods -n speech
kubectl port-forward -n speech svc/stt-en-speech-container 5001:5000
curl http://localhost:5001/ready    # → "OK"
```

For taints, ingress, capacity planning, and language-specific containers, read the rest of this guide.

---

## Architecture overview

```
┌─────────────────────────────────────────────────────────────────┐
│                    Kubernetes Cluster                            │
│                                                                  │
│  ┌──────────────┐   ┌──────────────┐   ┌──────────────┐          │
│  │ system pool  │   │   STT pool   │   │   TTS pool   │          │
│  │              │   │ taint=stt    │   │ taint=tts    │          │
│  │              │   │              │   │              │          │
│  │  CoreDNS     │   │  STT pod(s)  │   │  TTS pod(s)  │          │
│  │  Ingress     │   │  4c / 4Gi    │   │  6c / 12Gi   │          │
│  │  addons      │   │              │   │              │          │
│  └──────────────┘   └──────────────┘   └──────────────┘          │
│         │                  │                   │                  │
│         └──────────────────┴───────────────────┘                  │
│                            │                                      │
│                       Speech Secret                               │
│              (billing URL + API key OR CSI-mounted                │
│              from Azure Key Vault / AWS Secrets Manager /         │
│              GCP Secret Manager / external secret operator)       │
└────────────────────────────┼─────────────────────────────────────┘
                             │ outbound HTTPS
                             ▼
                ┌────────────────────────────┐
                │   Azure AI Speech endpoint │
                │  (license / billing only)  │
                └────────────────────────────┘
```

**Why split pools?** STT is CPU-bound, TTS is memory-bound (neural voice models load ~10 GB). Putting each workload on its own node family avoids over-provisioning and improves bin-packing.

> 💡 **AKS:** Pool names like `sttpool`/`ttspool` are conventions, not requirements — you can use any nodepool name. The chart's example values just need taints `workload=stt` / `workload=tts` to exist on those pools.

---

## Capacity planning

Use these throughput figures (validated by Microsoft Speech engineering, confirmed against in-field deployments) to size your cluster for a target call volume.

### Per-container resource requirements

Microsoft Learn — disconnected container host sizing per pod:

| Workload | **Minimum** | **Recommended** | Notes |
|---|---|---|---|
| **STT** (Speech-to-Text) | **4 cores / 4 GB** | **8 cores / 8 GB** | + 4–8 GB headroom for speech model load at startup |
| **Neural TTS** | **6 cores / 12 GB** | **8 cores / 16 GB** | Larger voice models = more RAM; synthesis bursts at 16 GB |

Chart 1.1.4 ships with **minimums** as the example request values; limits stay at the chart default `8c / 16Gi` so the container can burst to recommended sizing under load without rejection.

### Recommended node families

| Pool | Family | Sizing per node | Why | Density (1.1.4 requests) |
|---|---|---|---|---|
| **System** (`syspool`) | General purpose | 4 cores / 16 GB | Runs CoreDNS, ingress, addons | n/a |
| **STT** (`sttpool`) | **Compute-optimized** | 16 cores / 32 GB | STT is CPU-bound | 2 pods/node safe (req 4c each) |
| **TTS** (`ttspool`) | **Memory-optimized** | 16 cores / 128 GB | Neural voices need RAM | 2 pods/node safe (req 6c / 12Gi each) |

### Per-pod throughput

| Workload | Concurrency rule | 8-core pod | Pod throughput @ 30s/call |
|---|---|---|---|
| **STT** | **2 sessions per CPU core** | 8 × 2 = **16 concurrent sessions** | 16 × (3600/30) = **1,920 calls/hour** |
| **TTS** | **5 sessions per 8-core pod** | 5 concurrent sessions | 5 × (3600/30) = **600 calls/hour** |

> Assumes **average call duration of 30 seconds** (typical for IVR/voicebot turns). Adjust proportionally for your real traffic mix.

### Sizing for a target volume

Worked example — **100,000 calls/month**:

```
Average load     = 100,000 calls / 30 days / 24 hr ≈ 139 calls/hour
Peak load (3×)   ≈ 420 calls/hour during business-hour peaks
```

**STT pods needed:**
```
Peak calls / pod throughput = 420 / 1,920 ≈ 1 pod active at peak
Recommended: 2 pods minimum  (HA + headroom for traffic spikes)
```

**TTS pods needed:**
```
Peak calls / pod throughput = 420 / 600 ≈ 1 pod active at peak
Recommended: 2 pods minimum  (HA + headroom)
```

### Reference sizing table

| Monthly calls | Peak calls/hr (3×) | STT pods (req 4c/4Gi) | TTS pods (req 6c/12Gi) | Min sttpool nodes | Min ttspool nodes |
|---|---|---|---|---|---|
| 10 k    | ~42   | 1 (+ 1 HA) | 1 (+ 1 HA) | 1 (compute-opt 16c)  | 1 (memory-opt 16c) |
| 100 k   | ~420  | 2          | 2          | 2 (compute-opt 16c)  | 2 (memory-opt 16c) |
| 500 k   | ~2,100| 2          | 4          | 2 (compute-opt 16c)  | 4 (memory-opt 16c) |
| 1 M     | ~4,200| 3          | 7          | 3 (compute-opt 16c)  | 7 (memory-opt 16c) |
| 5 M     | ~21 k | 11         | 35         | 11 (compute-opt 16c) | 35 (memory-opt 16c) |

> Node count = pod count when using chart minimum requests (1 pod/node fits on a 16-core node with our 4c-STT / 6c-TTS requests — see [density math](#configurable-values-reference)).
> Increase peak multiplier (× factor) if your traffic profile is spikier (e.g., 5× for retail flash events, 10× for emergency campaigns).

### Tunable assumptions in this model

| Variable | Default | Where to change |
|---|---|---|
| Average call duration | 30 s | Multiply formula by `(your_avg_seconds / 30)` |
| STT concurrency/core | 2 sessions | `numberOfConcurrentRequest` env var (also `DECODER_MAX_COUNT`) |
| TTS concurrency/8-core pod | 5 sessions | `numberOfConcurrentRequest` env var |
| Peak-to-average ratio | 3× | Depends on traffic shape (BFSI ≈ 2×, retail ≈ 3–5×) |
| HA replicas | +1 baseline | Maintain at least 2 pods per workload always |

---

## Prerequisites

### 1. Azure AI Speech resource (billing endpoint + API key)

You need a regular Azure AI Speech resource that the disconnected container "checks back" to (only during initial license activation, then runs fully offline).

**Option A — Azure Portal:**
1. Open the [Azure Portal](https://portal.azure.com) → **Create a resource** → search "Speech".
2. Pick subscription + resource group + region; SKU `S0` minimum.
3. After deploy, open the resource → **Keys and Endpoint** → copy **Endpoint** and **Key 1**.
4. Open the resource → **Commitment Tiers** → choose STT hours and/or TTS characters tier → enable **Disconnected** mode.

**Option B — Azure CLI:**
```bash
az group create -n <rg> -l <region>

az cognitiveservices account create \
  --name <speech-resource-name> \
  --resource-group <rg> \
  --kind SpeechServices \
  --sku S0 \
  --location <region> \
  --yes

ENDPOINT=$(az cognitiveservices account show \
  -n <speech-resource-name> -g <rg> --query properties.endpoint -o tsv)
KEY=$(az cognitiveservices account keys list \
  -n <speech-resource-name> -g <rg> --query key1 -o tsv)

echo "Endpoint: $ENDPOINT"
echo "Key:      $KEY"
```
Then activate the disconnected commitment via the Portal (Commitment Tiers blade) — there's no CLI flow for commitment purchase.

> ⚠️ Self-service trial keys won't work for offline use — disconnected containers require an active commitment tier or EA approval.

### 2. Network / firewall whitelisting

Disconnected containers need network access only at specific moments. Egress rules:

| Endpoint | Port | Purpose | When required |
|---|---|---|---|
| `mcr.microsoft.com` | 443 | Container image registry | First pull only — cache after |
| `*.data.mcr.microsoft.com` | 443 | Image blob backing store | First pull only |
| `<resource>.cognitiveservices.azure.com` | 443 | License activation + periodic call-home | **Always** (every 7 days max) |
| Cluster API server | 443 | Standard Kubernetes egress | Always (managed by your platform) |

**Minimum production firewall rules** = only `<resource>.cognitiveservices.azure.com:443` (after the image is cached locally or in a private registry mirror).

**No inbound from the public internet is required** unless you expose ingress externally.

> 💡 **AKS:** Mirror the Speech images into Azure Container Registry (ACR) for air-gapped clusters — `az acr import --source mcr.microsoft.com/azure-cognitive-services/speechservices/speech-to-text:5.3.0-amd64-en-us`. Override `image.repository` at install time to pull from ACR.

### 3. Node pools, taints & labels (split-pool pattern)

The chart's example values files (1.1.4+) expect two dedicated node pools — one for STT, one for TTS — each carrying a taint and matching label. Any nodepool name works; the values reference taints/labels, not pool names.

| Workload | Required taint | Required label |
|---|---|---|
| STT pods | `workload=stt:NoSchedule` | `workload=stt` |
| TTS pods | `workload=tts:NoSchedule` | `workload=tts` |

**How the chart uses them:**
- **Toleration** on each pod allows it to *land* on the tainted node
- **Soft node affinity** (`preferredDuringSchedulingIgnoredDuringExecution`, weight 100) makes the pod *prefer* the matching pool — but falls back to any untainted node if the preferred pool is down (avoids stuck `Pending`)

The hard rejection comes from the **taint** (gate). The soft affinity is a hint (compass).

#### Platform-specific commands

> 💡 **AKS:**
> ```bash
> az aks nodepool add \
>   --cluster-name <aks-name> --resource-group <rg> \
>   --name sttpool \
>   --node-vm-size <compute-optimized-16c> \
>   --node-count 2 \
>   --node-taints "workload=stt:NoSchedule" \
>   --labels "workload=stt" --mode User
>
> az aks nodepool add \
>   --cluster-name <aks-name> --resource-group <rg> \
>   --name ttspool \
>   --node-vm-size <memory-optimized-16c> \
>   --node-count 2 \
>   --node-taints "workload=tts:NoSchedule" \
>   --labels "workload=tts" --mode User
> ```

> 💡 **EKS:** Add taint+label via `eksctl create nodegroup --node-labels=workload=stt --node-taints=workload=stt:NoSchedule` or under `nodeGroups[].taints` in your eksctl YAML.

> 💡 **GKE:** `gcloud container node-pools create stt-pool --node-labels=workload=stt --node-taints=workload=stt:NoSchedule`.

> 💡 **Vanilla / kubeadm / OpenShift:** Apply via `kubectl taint nodes <node> workload=stt:NoSchedule` and `kubectl label nodes <node> workload=stt` — or via your node configuration tooling.

If your nodepools use different taint values, override on install (see [Example 6](#example-6--custom-toleration-value-keyvalue-form)).

### 4. Speech credentials secret

The chart expects an opaque Kubernetes Secret with the billing URL + API key, mounted as env vars at runtime (not as plain CLI args, keeping the key out of `kubectl describe pod` output).

**Quick start — inline values:**
```bash
kubectl create namespace speech

kubectl create secret generic speech-credentials -n speech \
  --from-literal=billing="https://<resource>.cognitiveservices.azure.com/" \
  --from-literal=apikey="<your-key>"
```

Default key names are `billing` and `apikey`. Override at install:
```bash
--set secretRef.name=my-secret \
--set secretRef.billingKey=Billing \
--set secretRef.apiKeyKey=ApiKey
```

**Production: source the secret from an external vault** instead of plaintext:

| Platform | External secret source | Tool |
|---|---|---|
| **AKS** | Azure Key Vault | Secrets Store CSI Driver + Key Vault provider (see below) |
| **EKS** | AWS Secrets Manager / Parameter Store | Secrets Store CSI Driver + AWS provider, or External Secrets Operator |
| **GKE** | Google Secret Manager | Secrets Store CSI Driver + GCP provider |
| **Any K8s** | HashiCorp Vault, 1Password, Bitwarden | External Secrets Operator (https://external-secrets.io) |

In all cases, the chart sees a **standard Kubernetes Secret** — the chart doesn't care whether the Secret was created manually or synced from a vault. Just point `secretRef.name` at it.

> 💡 **AKS — recommended: Azure Key Vault** (collapsible details below). Skip if you're using a different vault or staying with the inline `kubectl create secret` above.

<details>
<summary><b>Azure Key Vault integration via Secrets Store CSI Driver (AKS)</b></summary>

For AKS clusters, Azure Key Vault is the recommended way to store the Speech billing URL and API key. The Secrets Store CSI Driver mounts vault values as a Kubernetes Secret automatically — credentials never live in your Helm values, Git, or CI logs.

**One-time AKS + Key Vault setup**

```bash
# 1. Enable Secrets Store CSI Driver + Azure provider on AKS (one-time per cluster)
az aks enable-addons --addons azure-keyvault-secrets-provider \
  --name <aks-name> --resource-group <rg>

# 2. Enable Workload Identity (replaces deprecated pod-managed identity)
az aks update --name <aks-name> --resource-group <rg> \
  --enable-oidc-issuer --enable-workload-identity

# 3. Create the Key Vault and store secrets
az keyvault create --name <kv-name> --resource-group <rg> --location <region> \
  --enable-rbac-authorization true

az keyvault secret set --vault-name <kv-name> --name speech-billing \
  --value "https://<resource>.cognitiveservices.azure.com/"

az keyvault secret set --vault-name <kv-name> --name speech-apikey \
  --value "<your-speech-key>"

# 4. Create a User-Assigned Managed Identity for the speech workload
az identity create -g <rg> -n speech-mi
CLIENT_ID=$(az identity show -g <rg> -n speech-mi --query clientId -o tsv)
PRINCIPAL_ID=$(az identity show -g <rg> -n speech-mi --query principalId -o tsv)

# 5. Grant the identity Key Vault Secrets User role on the vault
az role assignment create \
  --assignee $PRINCIPAL_ID \
  --role "Key Vault Secrets User" \
  --scope $(az keyvault show -n <kv-name> -g <rg> --query id -o tsv)

# 6. Federate the identity to the Kubernetes ServiceAccount
OIDC=$(az aks show -n <aks-name> -g <rg> --query oidcIssuerProfile.issuerUrl -o tsv)
az identity federated-credential create \
  --name speech-fed \
  --identity-name speech-mi \
  --resource-group <rg> \
  --issuer "$OIDC" \
  --subject "system:serviceaccount:speech:speech-sa"
```

**Apply the SecretProviderClass**

Create `speech-spc.yaml`:
```yaml
apiVersion: secrets-store.csi.x-k8s.io/v1
kind: SecretProviderClass
metadata:
  name: speech-kv
  namespace: speech
spec:
  provider: azure
  parameters:
    usePodIdentity: "false"
    useVMManagedIdentity: "false"
    clientID: "<CLIENT_ID-from-step-4>"
    keyvaultName: "<kv-name>"
    tenantId: "<your-tenant-id>"
    objects: |
      array:
        - |
          objectName: speech-billing
          objectType: secret
        - |
          objectName: speech-apikey
          objectType: secret
  secretObjects:                       # Synthesizes a normal K8s Secret
    - secretName: speech-credentials
      type: Opaque
      data:
        - objectName: speech-billing
          key: billing
        - objectName: speech-apikey
          key: apikey
```

Apply it:
```bash
kubectl apply -f speech-spc.yaml
kubectl create serviceaccount speech-sa -n speech \
  --annotate "azure.workload.identity/client-id=<CLIENT_ID>"
kubectl label serviceaccount speech-sa -n speech \
  azure.workload.identity/use=true
```

**Install the chart with Key Vault binding**

The chart accepts an optional `secretProviderClass.name` and `serviceAccount.name` — when both are set, the rendered Deployment mounts the CSI volume that triggers the secret sync.

```bash
helm install stt-en speech-container/speech-container -n speech \
  -f examples/stt-en.yaml \
  --set secretRef.enabled=true \
  --set secretRef.name=speech-credentials \
  --set secretProviderClass.enabled=true \
  --set secretProviderClass.name=speech-kv \
  --set serviceAccount.create=false \
  --set serviceAccount.name=speech-sa
```

> 💡 **What happens at runtime:** Pod starts → CSI driver authenticates via federated Workload Identity → fetches `speech-billing` and `speech-apikey` from Key Vault → writes them to a tmpfs volume → Kubernetes synthesizes the `speech-credentials` Secret → chart's env vars (`Billing`, `ApiKey`) resolve from that Secret. If Key Vault rotates the value, restarting the pod picks up the new value automatically.

> ⚠️ Workload Identity requires AKS ≥ 1.27. For older clusters, fall back to AAD Pod Identity (deprecated) or use a plain Secret (instructions above).

</details>

### 5. Ingress controller

The chart's example values enable an Ingress resource per release for hostname-based routing (e.g. `speech.example.com/stt/en-US`). Install `ingress-nginx` once per cluster before installing the speech chart:

```bash
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm install ingress-nginx ingress-nginx/ingress-nginx \
  -n ingress-nginx --create-namespace \
  --set controller.service.type=LoadBalancer
```

After install, capture the external IP and point your DNS (or `/etc/hosts` for testing) at it:
```bash
kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
```

---

## Installing the chart

```bash
# 1. Add the Helm repo
helm repo add speech-container https://osshaikh.github.io/speechcontainer/
helm repo update

# 2. List available versions
helm search repo speech-container/speech-container --versions

# 3. Install (using a baked-in example)
helm install stt-en speech-container/speech-container \
  -n speech \
  -f examples/stt-en.yaml \
  --set secretRef.enabled=true
```

To grab the example value files without cloning the repo:
```bash
helm pull speech-container/speech-container --untar
ls speech-container/examples/   # stt-en.yaml, stt-hi.yaml, tts-en.yaml, tts-hi.yaml, prod-overrides.yaml
```

---

## Configurable values reference

All values configurable via `--set`, `--set-json`, or `-f values.yaml`.

### Image
| Key | Default | Notes |
|---|---|---|
| `image.repository` | *(set per mode in examples)* | `mcr.microsoft.com/azure-cognitive-services/speechservices/speech-to-text` or `…/neural-text-to-speech` |
| `image.tag` | `5.3.0-amd64-en-us` (STT) / `4.6.0-amd64-en-us-avaneural` (TTS) | Locale-specific image tag |
| `image.pullPolicy` | `IfNotPresent` | |
| `imagePullSecrets` | `[]` | If using a private ACR mirror |

### Container args + credentials
| Key | Default | Notes |
|---|---|---|
| `args.eula` | `accept` | Must be `accept` |
| `args.billing` | `""` | Inline billing URL (use `secretRef` in prod) |
| `args.apikey` | `""` | Inline API key (use `secretRef` in prod) |
| `secretRef.enabled` | `false` | Set to `true` to pull credentials from a Secret |
| `secretRef.name` | `speech-credentials` | Name of the Secret |
| `secretRef.billingKey` | `billing` | Key inside the Secret for billing URL |
| `secretRef.apiKeyKey` | `apikey` | Key inside the Secret for API key |

### Resources (the most important knobs)
| Key | Chart default | STT example | TTS example |
|---|---|---|---|
| `resources.requests.cpu` | `8` | **`4`** | **`6`** |
| `resources.requests.memory` | `8Gi` | **`4Gi`** | **`12Gi`** |
| `resources.limits.cpu` | `8` | inherited (8) | inherited (8) |
| `resources.limits.memory` | `16Gi` | inherited (16Gi) | inherited (16Gi) |

Concurrency cap (passed as `DECODER_MAX_COUNT` env var):
| Key | Chart default | STT example | TTS example |
|---|---|---|---|
| `concurrency.numberOfConcurrentRequest` | `5` | `4` | `6` |

### Scheduling
| Key | Default | Notes |
|---|---|---|
| `nodeSelector` | `{}` | Hard pin to a node (avoid in prod) |
| `tolerations` | `[]` | STT examples add `workload=stt:NoSchedule`; TTS adds `workload=tts:NoSchedule` |
| `affinity` | `{}` | STT/TTS examples add soft node affinity preferring `workload=stt`/`workload=tts` |
| ⚠️ **Gotcha** | | Arrays REPLACE — `--set tolerations=...` while also using `-f stt-en.yaml` wipes the example's tolerations. Specify the full list. |

### Service & Ingress
| Key | Default | Notes |
|---|---|---|
| `service.type` | `ClusterIP` | Use `LoadBalancer` to expose directly |
| `service.port` | `5000` | Speech container HTTP port |
| `service.targetPort` | `5000` | |
| `ingress.enabled` | `false` (chart) / `true` (examples) | Per-release Ingress |
| `ingress.className` | `nginx` | |
| `ingress.host` | *(unset)* | Set in examples to `speech.example.com` |
| `ingress.path` | *(unset)* | E.g. `/stt/en-US`, `/tts/hi-IN` |
| `ingress.tls.enabled` | `false` | Set `true` + `secretName` for TLS |

### Autoscaling (HPA)
| Key | Default | Notes |
|---|---|---|
| `autoscaling.enabled` | `true` | |
| `autoscaling.minReplicas` | `1` | |
| `autoscaling.maxReplicas` | `5` (chart) / `4` (examples) | |
| `autoscaling.targetCPUUtilizationPercentage` | `70` | |

### Misc
| Key | Default | Notes |
|---|---|---|
| `replicaCount` | `1` | Ignored if HPA enabled |
| `env.extra` | `[]` | Inject extra env vars |
| `podLabels` | `{}` | Additional pod labels |
| `podAnnotations` | `{}` | Additional pod annotations |

---

## Install command examples

### Example 1 — Quickstart STT (English)
```bash
helm install stt-en speech-container/speech-container \
  -n speech --create-namespace \
  -f examples/stt-en.yaml \
  --set secretRef.enabled=true
```
**Result**: 4c/4Gi STT pod on `sttpool`, ingress at `speech.example.com/stt/en-US`.

### Example 2 — Quickstart TTS (Hindi)
```bash
helm install tts-hi speech-container/speech-container \
  -n speech \
  -f examples/tts-hi.yaml \
  --set secretRef.enabled=true
```
**Result**: 6c/12Gi TTS pod on `ttspool`, ingress at `speech.example.com/tts/hi-IN`.

### Example 3 — Override resources at install time
```bash
helm install stt-en speech-container/speech-container -n speech \
  -f examples/stt-en.yaml \
  --set secretRef.enabled=true \
  --set resources.requests.cpu=8 \
  --set resources.requests.memory=8Gi \
  --set concurrency.numberOfConcurrentRequest=8
```
**Use when**: you have spare CPU and want higher per-pod throughput.

### Example 4 — Custom secret name + keys
```bash
helm install stt-en speech-container/speech-container -n speech \
  -f examples/stt-en.yaml \
  --set secretRef.enabled=true \
  --set secretRef.name=my-speech-secret \
  --set secretRef.billingKey=BillingUrl \
  --set secretRef.apiKeyKey=SubscriptionKey
```

### Example 5 — Single shared pool (collapse split-pool)
If you only have ONE speech nodepool labeled/tainted `workload=speech`:
```bash
helm install stt-en speech-container/speech-container -n speech \
  -f examples/stt-en.yaml \
  -f examples/prod-overrides.yaml \
  --set secretRef.enabled=true
```
`prod-overrides.yaml` replaces the STT-specific toleration with `workload=speech` so STT and TTS share one pool.

### Example 6 — Custom toleration value (key=value form)
If your nodepool taint is `dedicated=speech-prod:NoSchedule`:
```bash
helm install stt-en speech-container/speech-container -n speech \
  -f examples/stt-en.yaml \
  --set secretRef.enabled=true \
  --set tolerations[0].key=dedicated \
  --set tolerations[0].operator=Equal \
  --set tolerations[0].value=speech-prod \
  --set tolerations[0].effect=NoSchedule \
  --set affinity.nodeAffinity.preferredDuringSchedulingIgnoredDuringExecution[0].weight=100 \
  --set affinity.nodeAffinity.preferredDuringSchedulingIgnoredDuringExecution[0].preference.matchExpressions[0].key=dedicated \
  --set affinity.nodeAffinity.preferredDuringSchedulingIgnoredDuringExecution[0].preference.matchExpressions[0].operator=In \
  --set affinity.nodeAffinity.preferredDuringSchedulingIgnoredDuringExecution[0].preference.matchExpressions[0].values[0]=speech-prod
```
> Helm arrays REPLACE — when using `--set toleration[0]…` together with `-f stt-en.yaml`, your `--set` values fully replace the example's toleration list.

### Example 7 — Disable HPA, fix replica count
```bash
helm install stt-en speech-container/speech-container -n speech \
  -f examples/stt-en.yaml \
  --set secretRef.enabled=true \
  --set autoscaling.enabled=false \
  --set replicaCount=3
```

### Example 8 — Expose via LoadBalancer (skip ingress)
```bash
helm install stt-en speech-container/speech-container -n speech \
  -f examples/stt-en.yaml \
  --set secretRef.enabled=true \
  --set service.type=LoadBalancer \
  --set ingress.enabled=false
```

### Example 9 — TLS-enabled ingress with cert-manager
```bash
helm install tts-en speech-container/speech-container -n speech \
  -f examples/tts-en.yaml \
  --set secretRef.enabled=true \
  --set ingress.tls.enabled=true \
  --set ingress.tls.secretName=tts-tls \
  --set ingress.host=speech.example.com \
  --set 'ingress.annotations.cert-manager\.io/cluster-issuer=letsencrypt-prod'
```

### Example 10 — Install all 4 (STT en/hi + TTS en/hi)
```bash
for rel in stt-en stt-hi tts-en tts-hi; do
  helm install $rel speech-container/speech-container -n speech \
    -f examples/$rel.yaml \
    --set secretRef.enabled=true
done
```

---

## Adding additional language containers

The chart is language-agnostic — to deploy any locale Microsoft publishes on MCR, override `image.repository` + `image.tag` at install time. You can reuse the STT or TTS example file for scheduling/resources and just swap the image.

### Image naming pattern

| Workload | Repository | Tag pattern |
|---|---|---|
| **STT** | `mcr.microsoft.com/azure-cognitive-services/speechservices/speech-to-text` | `<version>-amd64-<locale>` (e.g. `5.3.0-amd64-ta-in`) |
| **TTS** | `mcr.microsoft.com/azure-cognitive-services/speechservices/neural-text-to-speech` | `<version>-amd64-<locale>-<voice>neural` (e.g. `4.6.0-amd64-ta-in-pallavineural`) |

Locale codes follow BCP-47: `en-US`, `hi-IN`, `ta-IN`, `te-IN`, `mr-IN`, `bn-IN`, `gu-IN`, `kn-IN`, `ml-IN`, `pa-IN`, `ur-IN`, etc.

Browse all available tags: https://mcr.microsoft.com/en-us/catalog?search=speech

### Example 11 — Tamil STT
```bash
helm install stt-ta speech-container/speech-container -n speech \
  -f examples/stt-en.yaml \
  --set secretRef.enabled=true \
  --set image.repository=mcr.microsoft.com/azure-cognitive-services/speechservices/speech-to-text \
  --set image.tag=5.3.0-amd64-ta-in \
  --set ingress.path=/stt/ta-IN
```
**Result**: Tamil STT pod on `sttpool`, ingress at `speech.example.com/stt/ta-IN`. Inherits STT toleration, affinity, and resource requests (4c/4Gi) from `examples/stt-en.yaml`.

### Example 12 — Tamil TTS (Pallavi neural voice)
```bash
helm install tts-ta speech-container/speech-container -n speech \
  -f examples/tts-en.yaml \
  --set secretRef.enabled=true \
  --set image.repository=mcr.microsoft.com/azure-cognitive-services/speechservices/neural-text-to-speech \
  --set image.tag=4.6.0-amd64-ta-in-pallavineural \
  --set ingress.path=/tts/ta-IN
```
**Result**: Tamil TTS pod on `ttspool`, ingress at `speech.example.com/tts/ta-IN`. Inherits TTS toleration, affinity, and resource requests (6c/12Gi).

### Example 13 — Generic "add any language" pattern
Substitute `<LOCALE>`, `<VERSION>`, `<VOICE>`, `<RELEASE>`:
```bash
# STT - any language
helm install <RELEASE> speech-container/speech-container -n speech \
  -f examples/stt-en.yaml \
  --set secretRef.enabled=true \
  --set image.tag=<VERSION>-amd64-<LOCALE> \
  --set ingress.path=/stt/<LOCALE>

# TTS - any neural voice
helm install <RELEASE> speech-container/speech-container -n speech \
  -f examples/tts-en.yaml \
  --set secretRef.enabled=true \
  --set image.tag=<VERSION>-amd64-<LOCALE>-<VOICE>neural \
  --set ingress.path=/tts/<LOCALE>
```

### Example 14 — Bulk install many languages
```bash
# STT for English, Hindi, Tamil, Telugu, Marathi
declare -A STT_LANGS=(
  [en]="5.3.0-amd64-en-us"
  [hi]="5.3.0-amd64-hi-in"
  [ta]="5.3.0-amd64-ta-in"
  [te]="5.3.0-amd64-te-in"
  [mr]="5.3.0-amd64-mr-in"
)

for lang in "${!STT_LANGS[@]}"; do
  helm install stt-$lang speech-container/speech-container -n speech \
    -f examples/stt-en.yaml \
    --set secretRef.enabled=true \
    --set image.tag=${STT_LANGS[$lang]} \
    --set ingress.path=/stt/$lang
done
```

> ⚠️ Verify each image tag exists on MCR before installing — `docker pull <repo>:<tag>` from a workstation with MCR access is the fastest way. Container won't start if the tag is invalid.

---

## Verifying the install

```bash
# 1. Check release status
helm list -n speech

# 2. Check pod placement and resources
kubectl get pods -n speech -o wide
kubectl describe pod -n speech -l app.kubernetes.io/instance=stt-en | grep -A 5 "Requests\|Limits"

# 3. Probe the container endpoint
kubectl port-forward -n speech svc/stt-en-speech-container 5001:5000 &
curl http://localhost:5001/ready    # → "OK"
curl http://localhost:5001/status   # → JSON status

# 4. Quick STT test (English)
curl -X POST "http://localhost:5001/speech/recognition/conversation/cognitiveservices/v1?language=en-US" \
  -H "Content-Type: audio/wav" \
  --data-binary "@sample.wav"
```

---

## Upgrading & rolling back

```bash
# Refresh repo
helm repo update osshaikh

# Upgrade (preserves existing values)
helm upgrade stt-en speech-container/speech-container -n speech \
  -f examples/stt-en.yaml \
  --set secretRef.enabled=true

# Upgrade while keeping current values (only change tag)
helm upgrade stt-en speech-container/speech-container -n speech \
  --reuse-values --set image.tag=5.4.0-amd64-en-us

# View history
helm history stt-en -n speech

# Rollback to previous revision
helm rollback stt-en 1 -n speech
```

---

## Uninstalling

```bash
helm uninstall stt-en stt-hi tts-en tts-hi -n speech
kubectl delete namespace speech     # optional cleanup
```

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Pod stuck `Pending` | Insufficient CPU on tainted pool | Scale pool: `az aks nodepool scale ... --node-count N`, or lower `resources.requests.cpu` |
| Pod `CrashLoopBackOff`, log `Eula must be accepted` | `args.eula` missing or not `accept` | Re-install with `--set args.eula=accept` |
| Pod `CrashLoopBackOff`, log `Billing endpoint…validation failed` | Wrong billing URL or expired key | Verify Secret content; rotate key in portal |
| Pod log `Container does not have a valid disconnected container license` | Disconnected commitment not active on Speech resource | Purchase commitment tier in Azure portal |
| Image pull fails `ImagePullBackOff` | Firewall blocks `mcr.microsoft.com` | Whitelist MCR endpoints (see [Network](#4-network--firewall-whitelisting)) |
| `helm install` errors `args.billing is required` | Forgot `--set secretRef.enabled=true` AND no inline billing | Either enable secretRef or pass `--set args.billing=...` |
| Pod runs but `/ready` returns 503 for ~60s | Speech model still loading from disk | Wait 60–90s; increase readiness probe `initialDelaySeconds` if needed |
| HPA stays at 1 replica under load | Metrics-server missing / wrong target | `kubectl top pods -n speech`; verify metrics-server installed |
| Multiple pods on same node despite split-pool | Soft affinity fell back because target pool full | Scale STT/TTS pool, or check for taint mismatch |

---

## Support & contributing

- Issues: https://github.com/Osshaikh/speechcontainer/issues
- Maintainer: Owais Shaikh (`osshaikh@microsoft.com`)
- License: MIT (chart) / Microsoft EULA (container images)
