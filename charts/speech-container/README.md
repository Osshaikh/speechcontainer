# speech-container — Azure AI Speech Disconnected Containers on Kubernetes

A production-ready Helm chart for deploying **Azure AI Speech disconnected containers** (Speech-to-Text and Neural Text-to-Speech) on **any conformant Kubernetes platform**, with first-class guidance for **Azure Kubernetes Service (AKS)**.

Replaces the abandoned `microsoft/cognitive-services-speech-onpremise` chart (v0.3.3, June 2021) with parameterised CPU/memory, modern Kubernetes APIs, taint+toleration scheduling, and secret-based credentials.

- **Chart repo**: `https://osshaikh.github.io/speechcontainer/`
- **Source**: `https://github.com/Osshaikh/speechcontainer`
- **App version**: STT 5.4.0 (en-US, hi-IN; STT versions differ per locale, for example ta-IN is still on 5.3.0) / TTS 4.9.0 (en-US AvaNeural, hi-IN SwaraNeural, ta-IN PallaviNeural). See [image references](#image--documentation-references) and the [tag lookup helper](#tag-lookup-helper-before-installing-a-new-locale).
- **Chart version**: 1.4.0
- **Helm**: 3.10+ (Helm 4.x also tested and supported)

---

## Table of Contents

1. [Platform compatibility](#platform-compatibility)
2. [Quickstart](#quickstart)
3. [Architecture overview](#architecture-overview)
4. [Capacity planning](#capacity-planning) (full model lives in the [root README](../../README.md#capacity-planning))
5. [Prerequisites](#prerequisites)
   - [Azure AI Speech resource](#1-azure-ai-speech-resource-billing-endpoint--api-key)
   - [Network / firewall whitelisting](#2-network--firewall-whitelisting)
   - [Node pools, taints & labels](#3-node-pools-taints--labels-four-pool-pattern)
   - [Speech credentials secret](#4-speech-credentials-secret)
   - [Azure Key Vault integration (AKS)](#azure-key-vault-integration-aks)
   - [Routing: Gateway API or Ingress](#5-routing-gateway-api-or-ingress)
6. [Installing the chart](#installing-the-chart)
7. [Configurable values reference](#configurable-values-reference)
8. [Install command examples](#install-command-examples)
9. [Adding additional language containers](#adding-additional-language-containers)
10. [Verifying the install](#verifying-the-install)
11. [Production operations](#production-operations)
12. [Upgrading & rolling back](#upgrading--rolling-back)
13. [Uninstalling](#uninstalling)
14. [Troubleshooting](#troubleshooting)

---

## Platform compatibility

The chart targets **standard Kubernetes APIs** (Deployment, Service, Ingress, Secret, HPA) and works on any conformant cluster. Tested matrix:

| Platform | Status | Notes |
|---|---|---|
| **Azure Kubernetes Service (AKS)** | ✅ Validated | Recommended platform; native integrations for Key Vault, ACR, Workload Identity |
| **Amazon EKS** | ✅ Compatible | Use ALB ingress + IAM Roles for Service Accounts (IRSA) for secret access |
| **Google GKE** | ✅ Compatible | Use GCE ingress + Workload Identity for Secret Manager |
| **Red Hat OpenShift 4.x** | ✅ Compatible | Pods already run non-root. Under the `restricted-v2` SCC, let OpenShift assign the UID: `--set podSecurityContext.runAsUser=null --set podSecurityContext.runAsGroup=null`. Use a `Route` instead of `Ingress` |
| **Vanilla Kubernetes / kubeadm** | ✅ Compatible | Bring your own ingress controller and storage class |
| **k3s / k3d / kind** (dev) | ⚠️ Works | Resource minimums (4c STT, 6c TTS) often exceed laptop capacity |

**Required versions:**
- Kubernetes ≥ **1.27**; ≥ **1.30** when `preStopSleepSeconds` > 0 (the examples set it), because the chart uses the native `preStop` sleep action
- Helm ≥ **3.10** (Helm 4.x also tested and supported)
- A Gateway API implementation (recommended on AKS: app routing with Gateway API) **or** an ingress controller, if clients outside the cluster call the containers. See [§5](#5-routing-gateway-api-or-ingress)

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
curl http://localhost:5001/ready    # → {"service":"speechtotext","ready":"ready","message":"Api Key is valid, no action needed."}
```

The examples create ClusterIP Services only. To reach the containers from outside the cluster, add a routing overlay such as `-f examples/approuting-gateway.yaml` (see [§5](#5-routing-gateway-api-or-ingress)). For taints, routing, capacity planning, and language-specific containers, read the rest of this guide.

---

## Architecture overview

```
┌──────────────────────────────────────────────────────────────────────────────┐
│                              Kubernetes Cluster                              │
│                                                                              │
│  ┌────────────┐ ┌────────────┐ ┌────────────┐ ┌────────────┐ ┌────────────┐  │
│  │system pool │ │STT Hindi   │ │STT other   │ │TTS Hindi   │ │TTS other   │  │
│  │            │ │=stt-hi     │ │=stt-other  │ │=tts-hi     │ │=tts-other  │  │
│  │CoreDNS     │ │            │ │en, ta, ... │ │            │ │en, ta, ... │  │
│  │Ingress /   │ │STT pod(s)  │ │STT pod(s)  │ │TTS pod(s)  │ │TTS pod(s)  │  │
│  │Gateway     │ │4c / 8Gi    │ │4c / 8Gi    │ │6c / 12Gi   │ │6c / 12Gi   │  │
│  │addons      │ │            │ │            │ │            │ │            │  │
│  └──────┬─────┘ └──────┬─────┘ └──────┬─────┘ └──────┬─────┘ └──────┬─────┘  │
│         │              │              │              │              │        │
│         └──────────────┴──────────────┼──────────────┴──────────────┘        │
│                                       │                                      │
│                                Speech Secret                                 │
│                    (billing URL + API key OR CSI-mounted                     │
│                 from Azure Key Vault / AWS Secrets Manager /                 │
│                GCP Secret Manager / external secret operator)                │
└───────────────────────────────────────┼──────────────────────────────────────┘
                                        │ outbound HTTPS
                                        ▼
                         ┌────────────────────────────┐
                         │  Azure AI Speech endpoint  │
                         │  (license / billing only)  │
                         └────────────────────────────┘
```

Pool labels/taints are `workload=<value>`; each release selects its pool with one value, `nodePool`.

**Why four pools?** STT is CPU-bound, TTS is memory-bound (neural voice models load ~10 GB), so each workload gets its own node family. Within each workload, Hindi gets a dedicated pool and every other language shares a second pool. A busy Hindi workload can't starve other languages of node capacity, and each pool scales and is costed independently.

> 💡 **AKS:** Pool names like `stthi`/`sttother`/`ttshi`/`ttsother` are conventions, not requirements — you can use any nodepool name. The chart only needs each pool's taint and label (`workload=stt-hi`, `workload=stt-other`, `workload=tts-hi`, `workload=tts-other`) to match the release's `nodePool` value. Fewer pools are supported too — see [§3](#3-node-pools-taints--labels-four-pool-pattern).

---

## Capacity planning

> 📊 **The full capacity planning model** — per-container resource requirements, recommended node families, per-pod throughput, sizing for a target call volume (worked example: 100k calls/month), reference sizing table up to 5M calls/month, and tunable assumptions — **lives in the repo root README → [Capacity planning](../../README.md#capacity-planning)**.
>
> It was moved out of the chart README to keep this guide focused on install/operate steps. The model itself is platform-neutral and applies whether you deploy on AKS, EKS, GKE, OpenShift, or vanilla Kubernetes.

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

> 💡 **Connected mode vs Disconnected mode** — the same chart works for both:
> - **Connected mode** (default): an S0 Speech resource with no commitment plan. The container "calls home" to Azure for periodic license checks. No special purchase required.
> - **Disconnected mode** (offline / air-gapped): requires an active **commitment tier** on the Speech resource purchased via the Azure Portal → Speech resource → **Commitment Tiers** → enable **Disconnected** mode. Self-service trial keys cannot run in disconnected mode — needs commitment tier or EA approval.
>
> Both modes use the same images, the same chart values, and the same `kubectl create secret`. Only the Speech resource configuration differs.

### 2. Network / firewall whitelisting

Disconnected containers need network access only at specific moments. Whitelist these on your egress firewall / NAT gateway / Azure Firewall / NSG.

| Endpoint | Protocol / Port | Purpose | When required |
|---|---|---|---|
| `mcr.microsoft.com` | HTTPS 443 | Container image registry — pulls `speech-to-text` and `neural-text-to-speech` manifests | **First pull only** (cache after). Skip entirely if you mirror to ACR — see callout below. |
| `*.data.mcr.microsoft.com` | HTTPS 443 | MCR blob backing store (actual image layers) | First pull only |
| `https://<resource>.cognitiveservices.azure.com/` ← **your Speech resource endpoint** (Azure portal → Speech resource → "Keys and Endpoint" → "Endpoint", e.g. `https://myspeechres.cognitiveservices.azure.com/`) | HTTPS 443 | (1) License/key validation on pod startup (`/billing` POST); (2) usage meter upload. **This is the URL you pass as the `Billing=` container arg / `billing` secret field.** | **Connected mode:** Every 10–15 minutes for meter telemetry. **Disconnected mode:** Every commitment renewal window (default 7 days, configurable up to monthly via the commitment tier). Pod refuses to start if unreachable on first boot in either mode. |
| `https://<region>.api.cognitive.microsoft.com/` ← e.g. `eastus.api.cognitive.microsoft.com`, `centralindia.api.cognitive.microsoft.com`, `swedencentral.api.cognitive.microsoft.com` | HTTPS 443 | **Some** STT model variants make region-scoped backend calls during initialization (depends on locale / model version). Also used by the container if you've enabled cloud-fallback or hybrid features. | Always allow for the **region your Speech resource lives in** — Azure portal → Speech resource → "Overview" → "Location". Safe to scope to just that one region. |
| Cluster API server (`*.<region>.azmk8s.io` on AKS) | HTTPS 443 | Standard Kubernetes control-plane egress | Always (handled by your AKS managed VNet by default) |

> 🔑 **Concrete example** — if your Speech resource is named `myspeechres` in `centralindia`, the two mandatory FQDNs to whitelist (besides MCR) are:
> ```
> https://myspeechres.cognitiveservices.azure.com/      ← resource endpoint (billing + license)
> https://centralindia.api.cognitive.microsoft.com/     ← regional service endpoint
> ```
> The resource endpoint URL is **exactly** the value you'll set as the `Billing` arg / `billing` secret field. Copy it straight from the portal's "Keys and Endpoint" blade — don't construct it manually.

**Minimum production firewall rule set** (after first image pull is cached in a private registry):
- `<resource>.cognitiveservices.azure.com:443` — outbound, always
- `<region>.api.cognitive.microsoft.com:443` — outbound, always
- (No MCR needed if you mirrored to ACR.)

### 3. Node pools, taints & labels (four-pool pattern)

The chart's example values files (1.3.0+) expect four dedicated node pools: Hindi STT, every other STT language, Hindi TTS, and every other TTS voice. Each pool carries a taint and a matching label. Any nodepool name works; the chart references taints/labels, not pool names.

| Pool | Runs | Required taint | Required label | Example files |
|---|---|---|---|---|
| Hindi STT | `hi-IN` STT | `workload=stt-hi:NoSchedule` | `workload=stt-hi` | `stt-hi.yaml` |
| Other STT | `en-US`, `ta-IN`, any other STT locale | `workload=stt-other:NoSchedule` | `workload=stt-other` | `stt-en.yaml`, `stt-ta.yaml` |
| Hindi TTS | `hi-IN` neural voices | `workload=tts-hi:NoSchedule` | `workload=tts-hi` | `tts-hi.yaml` |
| Other TTS | `en-US`, `ta-IN`, any other TTS voice | `workload=tts-other:NoSchedule` | `workload=tts-other` | `tts-en.yaml`, `tts-ta.yaml` |

**How the chart uses them:** each example sets a single value, `nodePool` (for example `nodePool: stt-hi`). The chart turns it into:
- a **toleration** for `workload=<nodePool>:NoSchedule`, which allows the pod to *land* on the tainted pool
- a **node affinity** for the pool label. By default it's soft (`preferredDuringSchedulingIgnoredDuringExecution`, weight 100): the pod *prefers* that pool but falls back to any untainted node if the pool is full or down. Set `nodePoolAffinity: required` to make it hard: the pod never leaves the pool and stays `Pending` instead.

The taint keeps other workloads off the speech pools. The affinity decides whether speech pods may leave their pool.

> ⚠️ **Keep speech pods off the system pool.** With soft affinity, a speech pod that doesn't fit its pool can land on any *untainted* node, including system nodes running CoreDNS and the Gateway. For production, either set `nodePoolAffinity: required` (and enable the cluster autoscaler on speech pools so pods don't wait), or taint the system pool `CriticalAddonsOnly=true:NoSchedule`. Before tainting, check that every other workload (including your Gateway or ingress pods) tolerates it or has another pool to run on.

**High availability across nodes.** The chart spreads each release's replicas across nodes by default (`topologySpread`, `kubernetes.io/hostname`, `ScheduleAnyway`). Spreading only helps if the pool has **at least 2 nodes**; with one node, both replicas still share it and a node failure or upgrade takes the language down. For zone resilience set `topologySpread.topologyKey=topology.kubernetes.io/zone` on a zonal pool.

**Fewer pools?** Set `nodePool` per release instead of relying on the examples' values:

| Layout | `nodePool` for STT releases | `nodePool` for TTS releases |
|---|---|---|
| Four pools (examples' default) | `stt-hi` (Hindi) / `stt-other` | `tts-hi` (Hindi) / `tts-other` |
| Two pools (chart 1.2.x layout) | `stt` | `tts` |
| One shared pool | `speech` (or layer `examples/prod-overrides.yaml`) | `speech` |
| No dedicated pools | `""` (schedule on any node) | `""` |

#### Platform-specific commands

> 💡 **AKS:**
> ```bash
> az aks nodepool add \
>   --cluster-name <aks-name> --resource-group <rg> \
>   --name stthi \
>   --node-vm-size <compute-optimized-16c> \
>   --node-count 1 \
>   --node-taints "workload=stt-hi:NoSchedule" \
>   --labels "workload=stt-hi" --mode User
>
> az aks nodepool add \
>   --cluster-name <aks-name> --resource-group <rg> \
>   --name sttother \
>   --node-vm-size <compute-optimized-16c> \
>   --node-count 1 \
>   --node-taints "workload=stt-other:NoSchedule" \
>   --labels "workload=stt-other" --mode User
>
> az aks nodepool add \
>   --cluster-name <aks-name> --resource-group <rg> \
>   --name ttshi \
>   --node-vm-size <memory-optimized-16c> \
>   --node-count 1 \
>   --node-taints "workload=tts-hi:NoSchedule" \
>   --labels "workload=tts-hi" --mode User
>
> az aks nodepool add \
>   --cluster-name <aks-name> --resource-group <rg> \
>   --name ttsother \
>   --node-vm-size <memory-optimized-16c> \
>   --node-count 1 \
>   --node-taints "workload=tts-other:NoSchedule" \
>   --labels "workload=tts-other" --mode User
> ```
> Size each pool's node count for its own languages and traffic (see [Capacity planning](../../README.md#capacity-planning)). Already have pools with different labels? Change them in place, without recreating nodes: `az aks nodepool update ... --name <pool> --labels workload=stt-other --node-taints workload=stt-other:NoSchedule`.

> 💡 **EKS:** Add taint+label via `eksctl create nodegroup --node-labels=workload=stt-hi --node-taints=workload=stt-hi:NoSchedule` (repeat per pool) or under `nodeGroups[].taints` in your eksctl YAML.

> 💡 **GKE:** `gcloud container node-pools create stt-hi-pool --node-labels=workload=stt-hi --node-taints=workload=stt-hi:NoSchedule` (repeat per pool).

> 💡 **Vanilla / kubeadm / OpenShift:** Apply via `kubectl taint nodes <node> workload=stt-hi:NoSchedule` and `kubectl label nodes <node> workload=stt-hi` — or via your node configuration tooling.

If your nodepools use a different taint key or value, override on install (see [Example 6](#example-6--custom-taint-key-or-value)).

### 4. Speech credentials secret

The chart expects an opaque Kubernetes Secret with the billing URL + API key. The pod reads both into environment variables from the Secret, so `kubectl describe pod` shows only the Secret reference, not the values.

> ⚠️ **The API key is still visible inside the pod and on the node.** The container takes its settings as command-line arguments, so the chart passes `Billing=$(BILLING_ENDPOINT)` and `ApiKey=$(BILLING_APIKEY)`, which Kubernetes expands before the process starts. Anyone who can `kubectl exec` into the pod or log in to the node can read the key from the process command line (`/proc/1/cmdline`, `ps`), and runtime audit tools may log it. Restrict `pods/exec` and node access, and rotate the key regularly.

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

<a id="azure-key-vault-integration-aks"></a>
<details>
<summary><b>Azure Key Vault integration via Secrets Store CSI Driver (AKS)</b></summary>

For AKS clusters, Azure Key Vault is the recommended way to store the Speech billing URL and API key. The chart renders a `SecretProviderClass` and mounts it into the pod with the Secrets Store CSI Driver. The driver reads both values from Key Vault and syncs them into the Kubernetes Secret named by `secretRef.name`, which the container reads at startup. Credentials never live in your Helm values, Git, or CI logs.

> ⚠️ **The synced Secret exists only while a pod mounts the volume.** That's why the chart mounts the CSI volume into every speech pod (at `/mnt/secrets-store`, read-only). If you delete all pods, the Secret disappears until the next pod starts.

Two ways for the CSI driver to authenticate to Key Vault:

| `secretProviderClass.identity` | Identity | Setup | Use when |
|---|---|---|---|
| `addon` (default) | The AKS add-on's user-assigned managed identity (`azurekeyvaultsecretsprovider-<cluster>`) | One role assignment | Quickest path; every pod that uses a SecretProviderClass on the cluster can use this identity |
| `workload` | Your own managed identity, federated to the release's ServiceAccount (Microsoft Entra Workload ID) | Identity + federated credential per ServiceAccount | You want Key Vault access limited to the speech pods |

**Option A: add-on identity (default)**

```bash
# 1. Enable the Key Vault provider for Secrets Store CSI Driver (once per cluster)
az aks enable-addons --addons azure-keyvault-secrets-provider \
  --name <aks-name> --resource-group <rg>

# 2. Create the Key Vault and store both values
az keyvault create --name <kv-name> --resource-group <rg> --location <region> \
  --enable-rbac-authorization true
az keyvault secret set --vault-name <kv-name> --name speech-billing \
  --value "https://<resource>.cognitiveservices.azure.com/"
az keyvault secret set --vault-name <kv-name> --name speech-apikey \
  --value "<your-speech-key>"

# 3. Let the add-on identity read secrets from the vault
ADDON_CLIENT_ID=$(az aks show -n <aks-name> -g <rg> \
  --query addonProfiles.azureKeyvaultSecretsProvider.identity.clientId -o tsv)
ADDON_OBJECT_ID=$(az aks show -n <aks-name> -g <rg> \
  --query addonProfiles.azureKeyvaultSecretsProvider.identity.objectId -o tsv)
az role assignment create \
  --assignee-object-id "$ADDON_OBJECT_ID" --assignee-principal-type ServicePrincipal \
  --role "Key Vault Secrets User" \
  --scope "$(az keyvault show -n <kv-name> -g <rg> --query id -o tsv)"
TENANT_ID=$(az account show --query tenantId -o tsv)

# 4. Install. Give each release its own synced Secret name (see note below).
helm upgrade --install stt-en speech-container/speech-container -n speech \
  -f examples/stt-en.yaml \
  --set secretRef.enabled=true \
  --set secretRef.name=stt-en-credentials \
  --set secretProviderClass.enabled=true \
  --set secretProviderClass.keyVaultName=<kv-name> \
  --set secretProviderClass.tenantId="$TENANT_ID" \
  --set secretProviderClass.clientId="$ADDON_CLIENT_ID"
```

**Option B: Workload Identity**

```bash
# 1. Enable the add-on (as above) plus the OIDC issuer and Workload Identity
az aks update --name <aks-name> --resource-group <rg> \
  --enable-oidc-issuer --enable-workload-identity

# 2. Create a managed identity and grant it "Key Vault Secrets User" on the vault
az identity create -g <rg> -n speech-mi
CLIENT_ID=$(az identity show -g <rg> -n speech-mi --query clientId -o tsv)
PRINCIPAL_ID=$(az identity show -g <rg> -n speech-mi --query principalId -o tsv)
az role assignment create --assignee-object-id "$PRINCIPAL_ID" \
  --assignee-principal-type ServicePrincipal --role "Key Vault Secrets User" \
  --scope "$(az keyvault show -n <kv-name> -g <rg> --query id -o tsv)"

# 3. Federate it to the release's ServiceAccount. The chart names the
#    ServiceAccount <release>-speech-container (or serviceAccount.name).
OIDC=$(az aks show -n <aks-name> -g <rg> --query oidcIssuerProfile.issuerUrl -o tsv)
az identity federated-credential create --name stt-en-fed \
  --identity-name speech-mi --resource-group <rg> \
  --issuer "$OIDC" --audience api://AzureADTokenExchange \
  --subject "system:serviceaccount:speech:stt-en-speech-container"

# 4. Install
helm upgrade --install stt-en speech-container/speech-container -n speech \
  -f examples/stt-en.yaml \
  --set secretRef.enabled=true \
  --set secretRef.name=stt-en-credentials \
  --set secretProviderClass.enabled=true \
  --set secretProviderClass.identity=workload \
  --set secretProviderClass.keyVaultName=<kv-name> \
  --set secretProviderClass.tenantId="$TENANT_ID" \
  --set secretProviderClass.clientId="$CLIENT_ID"
```

With `identity=workload` the chart adds the `azure.workload.identity/client-id` annotation to the ServiceAccount it creates and the `azure.workload.identity/use: "true"` label to the pod. Using your own ServiceAccount (`serviceAccount.create=false`, `serviceAccount.name=...`)? Annotate it yourself and federate that name instead.

**Key Vault values**

| Key | Default | Notes |
|---|---|---|
| `secretProviderClass.enabled` | `false` | Mount the CSI volume. Requires `secretRef.enabled=true` |
| `secretProviderClass.create` | `true` | Render a SecretProviderClass in this release. Set `false` to use one you manage |
| `secretProviderClass.name` | `""` | Name of the SecretProviderClass. Default `<release>-speech-container`; required when `create=false` |
| `secretProviderClass.keyVaultName` | `""` | Key Vault name (required when `create=true`) |
| `secretProviderClass.tenantId` | `""` | Microsoft Entra tenant ID of the vault (required when `create=true`) |
| `secretProviderClass.identity` | `addon` | `addon` or `workload` |
| `secretProviderClass.clientId` | `""` | Client ID of the add-on identity (`addon`) or your managed identity (`workload`) |
| `secretProviderClass.billingSecretName` | `speech-billing` | Key Vault secret holding the billing URL; synced to `secretRef.billingKey` |
| `secretProviderClass.apiKeySecretName` | `speech-apikey` | Key Vault secret holding the API key; synced to `secretRef.apiKeyKey` |
| `secretProviderClass.mountPath` | `/mnt/secrets-store` | Where the CSI volume is mounted (read-only) |

> 💡 **One synced Secret per release.** Each release with `create=true` renders its own SecretProviderClass. If several of them sync the *same* Secret name, they all write to one object and uninstalling one release can affect the others. Give each release its own `secretRef.name` (as above), or apply one shared SecretProviderClass yourself and install every release with `secretProviderClass.create=false` and `secretProviderClass.name=<shared-name>`.

> 💡 **Rotation:** the container reads the billing URL and key only at startup. After rotating them in Key Vault, restart the pods (`kubectl rollout restart deployment -n speech <release>-speech-container`).

</details>

### 5. Routing: Gateway API or Ingress

The examples create a ClusterIP Service per release and leave external routing **off**. Add one overlay per release to expose it on a shared hostname, with one path per language (`/stt/<locale>`, `/tts/<locale>`):

| Route | Overlay | Notes |
|---|---|---|
| **AKS app routing with Gateway API** (recommended on AKS) | `examples/approuting-gateway.yaml` | Managed Istio-based Gateway (`gatewayClassName: approuting-istio`). TLS terminates at the Gateway listener |
| **Application Gateway for Containers** | `examples/agc-overrides.yaml` | Azure-managed L7 load balancer, WAF option |
| **NGINX Ingress** | `--set ingress.enabled=true` | Only if you already run an NGINX controller. Upstream ingress-nginx maintenance ended in March 2026; AKS supports its app routing NGINX with critical security patches through November 2026. Prefer Gateway API for new clusters |
| **LoadBalancer per release** | `examples/internal-lb.yaml` or `--set service.type=LoadBalancer` | One IP per language, no path routing |

Use **one** of `ingress.enabled` and `gatewayApi.enabled` per release. The chart fails at template time if both are on.

<a id="routing-with-aks-app-routing-gateway-api"></a>
#### Routing with AKS app routing (Gateway API)

One-time cluster setup:

```bash
# 1. Enable Gateway API and the app routing Istio implementation
az aks update --resource-group <rg> --name <aks-name> \
  --enable-gateway-api --enable-app-routing-istio

# 2. TLS certificate for the hostname, in the Gateway namespace
kubectl create secret tls speech-tls -n speech --cert=speech.crt --key=speech.key
```

```yaml
# 3. One shared Gateway for every speech release (gateway.yaml)
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: speech-gateway
  namespace: speech
spec:
  gatewayClassName: approuting-istio
  # Private IP instead of a public one:
  # infrastructure:
  #   annotations:
  #     service.beta.kubernetes.io/azure-load-balancer-internal: "true"
  listeners:
    - name: https
      hostname: speech.contoso.com
      port: 443
      protocol: HTTPS
      tls:
        mode: Terminate
        certificateRefs:
          - kind: Secret
            name: speech-tls
      allowedRoutes:
        namespaces:
          from: Same
```

```bash
kubectl apply -f gateway.yaml
kubectl get gateway speech-gateway -n speech      # PROGRAMMED=True, ADDRESS=<IP>
```

Install each release with the overlay. The example sets the path; you set the hostname:

```bash
for rel in stt-en stt-hi tts-en tts-hi; do
  helm upgrade --install $rel speech-container/speech-container -n speech \
    --version 1.4.0 \
    -f examples/$rel.yaml \
    -f examples/approuting-gateway.yaml \
    --set secretRef.enabled=true \
    --set gatewayApi.hostname=speech.contoso.com
done
kubectl get httproute -n speech
```

Each HTTPRoute matches the hostname and the language path, strips the path prefix before forwarding (`URLRewrite`, `ReplacePrefixMatch: /`), and allows 3600 s per request for long STT WebSocket sessions.

- **Hostnames:** requests with any other `Host` header get 404. To accept more names (for example a private DNS name next to the public one), add them under `gatewayApi.hostnames`; every name must also be accepted by the Gateway listener (use a listener per name, a wildcard listener, or omit the listener `hostname`).
- **Client URLs:** with path routing, pass the full URL to the Speech SDK `endpoint` parameter. The SDK `host` parameter doesn't accept a path. See [Calling the containers](#calling-the-containers).

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
ls speech-container/examples/   # stt-en.yaml, stt-hi.yaml, stt-ta.yaml, tts-en.yaml, tts-hi.yaml, tts-ta.yaml, approuting-gateway.yaml, agc-overrides.yaml, internal-lb.yaml, prod-overrides.yaml
```

---

## Configurable values reference

All values configurable via `--set`, `--set-json`, or `-f values.yaml`. The chart ships a `values.schema.json`: misspelled or unknown keys, and invalid choices such as `mode: asr`, fail at install time instead of being silently ignored.

### Image
| Key | Default | Notes |
|---|---|---|
| `image.registry` | `mcr.microsoft.com` | Point at your ACR mirror if you mirror images |
| `image.repository` | `""` | Empty = derived from `mode` (`…/speech-to-text` or `…/neural-text-to-speech`) |
| `image.tag` | `5.4.0-amd64-en-us` | Locale (STT) or voice (TTS) specific; examples pin 5.4.0 STT (ta-IN 5.3.0) and 4.9.0 TTS |
| `image.pullPolicy` | `IfNotPresent` | |
| `image.pullSecrets` | `[]` | Pull secrets for a private registry, e.g. `[{name: acr-pull}]` |
| `imagePullSecrets` | `[]` | Same as `image.pullSecrets` (standard Helm key); both lists are merged |

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
| `secretProviderClass.*` | disabled | Sync the Secret from Azure Key Vault; see [Key Vault integration](#azure-key-vault-integration-aks) |

### Resources (the most important knobs)
| Key | Chart default | STT example | TTS example |
|---|---|---|---|
| `resources.requests.cpu` | `8` | **`4`** | **`6`** |
| `resources.requests.memory` | `8Gi` | **`8Gi`** | **`12Gi`** |
| `resources.limits.cpu` | `8` | **`8`** | inherited (8) |
| `resources.limits.memory` | `16Gi` | **`16Gi`** | inherited (16Gi); use `24Gi` for multilingual voices |

STT concurrency (passed as the `DECODER_MAX_COUNT` env var, **STT only**):
| Key | Chart default | STT examples |
|---|---|---|
| `concurrency.numberOfConcurrentRequest` | `8` | `5` (hi-IN, 4-core request) / `8` (en-US, ta-IN) |

TTS has no server-side concurrency setting, so the chart doesn't set `DECODER_MAX_COUNT` on TTS pods. Microsoft recommends fewer than 5 concurrent requests per 8-core TTS container: cap concurrency at the gateway or in the client and size replicas for the peak.

### Scheduling
| Key | Default | Notes |
|---|---|---|
| `nodePool` | `""` | Target pool: adds toleration `<nodePoolKey>=<nodePool>:NoSchedule` + node affinity for label `<nodePoolKey>=<nodePool>`. Examples set `stt-hi` / `stt-other` / `tts-hi` / `tts-other`. Empty = any node |
| `nodePoolKey` | `workload` | Taint/label key used by `nodePool` |
| `nodePoolAffinity` | `preferred` | `preferred` (fall back to other untainted nodes) or `required` (never leave the pool) |
| `topologySpread.enabled` | `true` | Spread replicas of a release across `topologySpread.topologyKey` |
| `topologySpread.topologyKey` | `kubernetes.io/hostname` | Use `topology.kubernetes.io/zone` to spread across zones |
| `topologySpread.maxSkew` | `1` | |
| `topologySpread.whenUnsatisfiable` | `ScheduleAnyway` | `DoNotSchedule` makes the spread mandatory |
| `topologySpreadConstraints` | `[]` | Extra constraints, added to the generated one |
| `tolerations` | `[]` | Extra tolerations, **added** to the `nodePool` toleration |
| `affinity` | `{}` | When non-empty, **replaces** the affinity generated from `nodePool` |
| `nodeSelector` | `{}` | Hard pin to a node (avoid in prod) |
| `priorityClassName` | `""` | |

### Rollout, shutdown and disruption
| Key | Chart default | Examples | Notes |
|---|---|---|---|
| `strategy` | `RollingUpdate`, `maxSurge: 1`, `maxUnavailable: 0` | `maxSurge: 0`, `maxUnavailable: 1` | The default needs room for one extra pod. On a full dedicated pool the surge pod stays `Pending` and the rollout never finishes; the examples replace one pod at a time instead |
| `terminationGracePeriodSeconds` | `30` | STT `330` / TTS `45` | Maximum time Kubernetes waits before killing the container |
| `preStopSleepSeconds` | `0` | STT `300` / TTS `15` | Keeps a terminating pod serving its open sessions (it no longer receives new ones). Must be less than `terminationGracePeriodSeconds`; needs Kubernetes 1.30+ |
| `podDisruptionBudget.enabled` | `true` | `true` | Created only when the release keeps ≥ 2 replicas (`autoscaling.minReplicas`, or `replicaCount` without HPA) |
| `podDisruptionBudget.minAvailable` | `1` | `1` | |

### Probes
| Key | Default | Notes |
|---|---|---|
| `startupProbe.enabled` | `true` | `GET /ready` every 10 s, up to 60 failures (10 min) for model load. Liveness and readiness don't run until it passes |
| `readinessProbe.path` | `/ready` | Removes the pod from the Service until the model is loaded |
| `livenessProbe.type` | `tcpSocket` | Restarts the container only if port 5000 stops accepting connections. `httpGet` probes `livenessProbe.path` (`/status`, which reports API key validation) instead |
| `*.initialDelaySeconds` | `0` | The startup probe covers model load. If you disable it, set `initialDelaySeconds` (for example 120) on liveness and readiness |

### Service & Ingress
| Key | Default | Notes |
|---|---|---|
| `service.type` | `ClusterIP` | Use `LoadBalancer` to expose directly |
| `service.port` | `5000` | Speech container HTTP port |
| `service.targetPort` | `5000` | |
| `service.annotations` | `{}` | For example the internal load balancer annotation |
| `ingress.enabled` | `false` (chart and examples) | Per-release NGINX Ingress |
| `ingress.className` | `nginx` | |
| `ingress.host` | `speech.bfl.internal` (chart) / `speech.example.com` (examples) | |
| `ingress.path` | `""` | Set in examples, e.g. `/stt/en-US`, `/tts/hi-IN` |
| `ingress.tls.enabled` | `false` | Set `true` + `secretName` for TLS |

### Gateway API (HTTPRoute)
| Key | Default | Notes |
|---|---|---|
| `gatewayApi.enabled` | `false` | Render an HTTPRoute. Turned on by `approuting-gateway.yaml` / `agc-overrides.yaml` |
| `gatewayApi.parentRef.name` / `.namespace` / `.sectionName` | `""` | The Gateway (and listener) to attach to |
| `gatewayApi.hostname` | `""` | Hostname to match; must be accepted by the Gateway listener |
| `gatewayApi.hostnames` | `[]` | Extra hostnames, added to `gatewayApi.hostname` |
| `gatewayApi.path` | `""` | Path prefix, set in examples (`/stt/<locale>`, `/tts/<locale>`); stripped before forwarding |
| `gatewayApi.timeouts.request` / `.backendRequest` | `3600s` | Long STT WebSocket sessions |

### Autoscaling (HPA)
| Key | Default | Notes |
|---|---|---|
| `autoscaling.enabled` | `true` | |
| `autoscaling.minReplicas` | `2` | |
| `autoscaling.maxReplicas` | `6` | Keep within what the pool can schedule (max nodes × pods per node). Higher values only create `Pending` pods |
| `autoscaling.targetCPUUtilizationPercentage` | `75` | CPU is a proxy for STT session load; see [Production operations](#production-operations) |

### Security
| Key | Default | Notes |
|---|---|---|
| `podSecurityContext` | `runAsNonRoot: true`, `runAsUser: 65532`, `runAsGroup: 65532`, `seccompProfile: RuntimeDefault` | The STT and TTS images run as the built-in `nonroot` user (UID/GID 65532) |
| `containerSecurityContext` | `allowPrivilegeEscalation: false`, `capabilities.drop: [ALL]`, `readOnlyRootFilesystem: false` | |
| `serviceAccount.create` | `true` | |
| `serviceAccount.automountServiceAccountToken` | `false` | Speech pods don't call the Kubernetes API, so no token is mounted |

### Misc
| Key | Default | Notes |
|---|---|---|
| `replicaCount` | `2` | Ignored if HPA enabled |
| `env.extra` | `[]` | Inject extra env vars |
| `podLabels` | `{}` | Additional pod labels |
| `podAnnotations` | `{}` | Additional pod annotations |
| `nameOverride` / `fullnameOverride` | `""` | |

---

## Install command examples

### Example 1 — Quickstart STT (English)
```bash
helm install stt-en speech-container/speech-container \
  -n speech --create-namespace \
  -f examples/stt-en.yaml \
  --set secretRef.enabled=true
```
**Result**: two 4c/8Gi STT pods (16Gi limit) on the non-Hindi STT pool (`workload=stt-other`), spread across nodes, ClusterIP Service `stt-en-speech-container`. Add `-f examples/approuting-gateway.yaml` to publish it at `https://<hostname>/stt/en-US`.

### Example 2 — Quickstart TTS (Hindi)
```bash
helm install tts-hi speech-container/speech-container \
  -n speech \
  -f examples/tts-hi.yaml \
  --set secretRef.enabled=true
```
**Result**: two 6c/12Gi TTS pods on the Hindi TTS pool (`workload=tts-hi`). Add `-f examples/approuting-gateway.yaml` to publish it at `https://<hostname>/tts/hi-IN`.

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

### Example 4a — Hindi STT with custom Secret reference + custom CPU/memory

End-to-end production install for a Hindi (hi-IN) STT release:
- Credentials pulled from a Secret named `bfl-speech-creds` with non-default keys (`BILLING_URL` / `COG_KEY`)
- Per-pod CPU/memory tuned (Microsoft Learn: STT needs 4 GB plus 4-8 GB for the speech model; here we request 6 CPU / 8 GB with a 14 GB limit)
- Service kept as ClusterIP for in-cluster apps; flip to `service.type=LoadBalancer` if a public IP is needed

**Pre-req:** create the Secret once:
```bash
kubectl create secret generic bfl-speech-creds -n speech \
  --from-literal=BILLING_URL="https://<your-speech-resource>.cognitiveservices.azure.com/" \
  --from-literal=COG_KEY="<your-S0-key>"
```

**Install:**
```bash
helm install stt-hi speech-container/speech-container -n speech \
  --version 1.4.0 \
  --set mode=stt \
  --set image.tag=5.4.0-amd64-hi-in \
  --set secretRef.enabled=true \
  --set secretRef.name=bfl-speech-creds \
  --set secretRef.billingKey=BILLING_URL \
  --set secretRef.apiKeyKey=COG_KEY \
  --set resources.requests.cpu=6 \
  --set resources.requests.memory=8Gi \
  --set resources.limits.cpu=8 \
  --set resources.limits.memory=14Gi \
  --set concurrency.numberOfConcurrentRequest=8 \
  --set service.type=ClusterIP \
  --set ingress.enabled=false
```

### Example 4b — Hindi TTS (Neural voice) with custom Secret reference + custom CPU/memory

Same Secret as 4a (or a different one). Neural TTS needs more RAM than STT (Microsoft Learn: 6 CPU / 12 GB minimum, 8 CPU / 16 GB recommended); this example sets requests at 8/12 with limits at 8/16. TTS has no `concurrency` setting: limit concurrent requests per pod in the client or gateway.

```bash
helm install tts-hi speech-container/speech-container -n speech \
  --version 1.4.0 \
  --set mode=tts \
  --set image.tag=4.9.0-amd64-hi-in-swaraneural \
  --set secretRef.enabled=true \
  --set secretRef.name=bfl-speech-creds \
  --set secretRef.billingKey=BILLING_URL \
  --set secretRef.apiKeyKey=COG_KEY \
  --set resources.requests.cpu=8 \
  --set resources.requests.memory=12Gi \
  --set resources.limits.cpu=8 \
  --set resources.limits.memory=16Gi \
  --set service.type=ClusterIP \
  --set ingress.enabled=false
```

> **Other Hindi TTS voices** (swap the suffix; check the tag exists with the [tag lookup helper](#tag-lookup-helper-before-installing-a-new-locale)): `hi-in-madhurneural`, `hi-in-rehaanneural`, `hi-in-aaravneural`, `hi-in-ananyaneural`, `hi-in-kavyaneural`, `hi-in-kunalneural`, `hi-in-arjunneural`.

**Verify both come up Running:**
```bash
kubectl get pods -n speech -l 'app.kubernetes.io/instance in (stt-hi,tts-hi)' -w
```

**Confirm Secret was wired in correctly (values are never exposed):**
```bash
kubectl describe pod -n speech -l app.kubernetes.io/instance=stt-hi | findstr -i "billing apikey"
# Expect:
#   Billing:  <set to the key 'BILLING_URL' in secret 'bfl-speech-creds'>  Optional: false
#   ApiKey:   <set to the key 'COG_KEY'     in secret 'bfl-speech-creds'>  Optional: false
```

### Example 5 — Fewer pools (two pools, or one shared pool)
Two pools labelled/tainted `workload=stt` and `workload=tts` (the chart 1.2.x layout):
```bash
helm install stt-hi speech-container/speech-container -n speech \
  -f examples/stt-hi.yaml \
  --set nodePool=stt \
  --set secretRef.enabled=true
```
Use `--set nodePool=tts` for TTS releases.

One speech pool labelled/tainted `workload=speech`:
```bash
helm install stt-en speech-container/speech-container -n speech \
  -f examples/stt-en.yaml \
  -f examples/prod-overrides.yaml \
  --set secretRef.enabled=true
```
`prod-overrides.yaml` sets `nodePool: speech`, so STT and TTS share one pool.

### Example 6 — Custom taint key or value
If your nodepool taint and label are `dedicated=speech-prod`:
```bash
helm install stt-en speech-container/speech-container -n speech \
  -f examples/stt-en.yaml \
  --set secretRef.enabled=true \
  --set nodePoolKey=dedicated \
  --set nodePool=speech-prod
```
The chart generates the matching toleration and node affinity. Add `--set nodePoolAffinity=required` to keep the pods on that pool. Need different placement logic? Set `affinity` directly; a non-empty `affinity` replaces the generated one, while the `nodePool` toleration is kept.

### Example 7 — Disable HPA, fix replica count
```bash
helm install stt-en speech-container/speech-container -n speech \
  -f examples/stt-en.yaml \
  --set secretRef.enabled=true \
  --set autoscaling.enabled=false \
  --set replicaCount=3
```

### Example 8 — Expose via LoadBalancer (no Gateway or Ingress)
```bash
helm install stt-en speech-container/speech-container -n speech \
  -f examples/stt-en.yaml \
  --set secretRef.enabled=true \
  --set service.type=LoadBalancer
```

### Example 8a — Expose via INTERNAL LoadBalancer (private IP, VNet-routable only)

Use when consumers live in the **same VNet** as the AKS cluster (or peered VNets / on-prem via VPN/ExpressRoute) but should NOT be reachable from the public internet. Layer the bundled `internal-lb.yaml` overlay on top of any language example:

```bash
# Hindi TTS reachable from any VM in the AKS VNet at a private IP
helm install tts-hi speech-container/speech-container -n speech \
  -f examples/tts-hi.yaml \
  -f examples/internal-lb.yaml \
  --set secretRef.enabled=true \
  --set secretRef.name=speech-credentials
```

After install, capture the assigned private IP (from the AKS node subnet, e.g. `10.224.0.45`):

```bash
kubectl get svc -n speech tts-hi-speech-container
# NAME                      TYPE           EXTERNAL-IP    PORT(S)
# tts-hi-speech-container   LoadBalancer   10.224.0.45    5000:31xxx/TCP
```

From a VM anywhere in the VNet or peered VNet:
```bash
curl http://10.224.0.45:5000/ready
```

> **Why not just use `--set service.annotations.service\.beta\.kubernetes\.io/azure-load-balancer-internal=true`?** Because `--set` parses unquoted `true` as a boolean and Kubernetes annotations require strings, so you hit `cannot unmarshal bool into … type string`. The overlay file pins the value as the string `"true"` and is the simplest path. (If you must use a flag, switch to `--set-string`.)

### Example 9 — TLS-enabled NGINX ingress with cert-manager
For clusters that already run an NGINX ingress controller (see [§5](#5-routing-gateway-api-or-ingress)):
```bash
helm install tts-en speech-container/speech-container -n speech \
  -f examples/tts-en.yaml \
  --set secretRef.enabled=true \
  --set ingress.enabled=true \
  --set ingress.tls.enabled=true \
  --set ingress.tls.secretName=tts-tls \
  --set ingress.host=speech.example.com \
  --set 'ingress.annotations.cert-manager\.io/cluster-issuer=letsencrypt-prod'
```

### Example 10 — Install all 4 (STT en/hi + TTS en/hi) behind AKS app routing
```bash
for rel in stt-en stt-hi tts-en tts-hi; do
  helm upgrade --install $rel speech-container/speech-container -n speech \
    -f examples/$rel.yaml \
    -f examples/approuting-gateway.yaml \
    --set secretRef.enabled=true \
    --set gatewayApi.hostname=speech.contoso.com
done
```

---

## Adding additional language containers

The chart is language-agnostic — to deploy any locale Microsoft publishes on MCR, override `image.repository` + `image.tag` at install time. You can reuse the STT or TTS example file for scheduling/resources and just swap the image.

### Image & documentation references

Browse available image tags and the official catalog of supported locales/voices:

| Resource | Link |
|---|---|
| **STT image (all tags)** | https://mcr.microsoft.com/product/azure-cognitive-services/speechservices/speech-to-text/tags |
| **TTS image (all tags)** | https://mcr.microsoft.com/product/azure-cognitive-services/speechservices/neural-text-to-speech/tags |
| **MCR catalog (search "speech")** | https://mcr.microsoft.com/en-us/catalog?search=speech |
| **Microsoft Learn — Speech container how-to** | https://learn.microsoft.com/azure/ai-services/speech-service/speech-container-howto |
| **Supported STT locales & TTS voices** | https://learn.microsoft.com/azure/ai-services/speech-service/language-support |
| **Full TTS voice gallery (sample audio)** | https://speech.microsoft.com/portal/voicegallery |
| **Disconnected container commitment tiers** | https://learn.microsoft.com/azure/ai-services/containers/disconnected-containers |

### Image naming pattern

| Workload | Repository | Tag pattern |
|---|---|---|
| **STT** | `mcr.microsoft.com/azure-cognitive-services/speechservices/speech-to-text` | `<version>-amd64-<locale>` (e.g. `5.4.0-amd64-hi-in`, `5.3.0-amd64-ta-in`) |
| **TTS** | `mcr.microsoft.com/azure-cognitive-services/speechservices/neural-text-to-speech` | `<version>-amd64-<locale>-<voice>neural` (e.g. `4.9.0-amd64-ta-in-pallavineural`) |

Locale codes follow BCP-47: `en-US`, `hi-IN`, `ta-IN`, `te-IN`, `mr-IN`, `bn-IN`, `gu-IN`, `kn-IN`, `ml-IN`, `pa-IN`, `ur-IN`, etc.

> 💡 **Tip:** Open the MCR tags page for STT or TTS above to see every locale + version Microsoft has published. The TTS voice gallery lets you hear samples before picking a `<voice>neural` to deploy.

> ⚠️ **TTS versions — check before adding a locale.** The examples pin TTS **4.9.0** (en-US AvaNeural, hi-IN SwaraNeural, ta-IN PallaviNeural, all verified on MCR). Older lines (4.6.0, 4.7.0) don't cover every voice; for example there is no 4.6.0 tag for most Indic locales. Run the [tag lookup helper](#tag-lookup-helper-before-installing-a-new-locale) for your voice before installing, or you'll hit `ImagePullBackOff`.

> ⚠️ **STT version is per-locale — DO NOT assume one version covers all languages.** STT versions are **not synchronized across locales**. As of this writing:
>
> | STT version | Locales currently on this version |
> |---|---|
> | **5.4.0** | en-US, hi-IN, te-IN, ml-IN, pa-IN, ur-IN |
> | **5.3.0** | ta-IN, mr-IN, bn-IN, gu-IN |
> | Preview only | kn-IN (no GA tag yet — `5.0.x-preview` is the latest) |
>
> Microsoft bumps individual locales independently as model improvements ship, so this table will drift. **Always run the [Tag lookup helper](#tag-lookup-helper-before-installing-a-new-locale) for your target locale before `helm install`** — a single hardcoded version copied from another language will frequently hit `ImagePullBackOff`. Example: `5.3.0-amd64-te-in` does **not** exist; Telugu STT went straight from `3.10.0` to `5.4.0`.

### Tag lookup helper (before installing a new locale)

Always confirm the exact tag exists on MCR before running `helm install`. This curl + jq snippet hits the MCR v2 registry API (no Docker needed, no workstation pull):

```bash
# TTS — list every tag for a locale (change mr-in to your target)
TOKEN=$(curl -s "https://mcr.microsoft.com/oauth2/token?service=mcr.microsoft.com&scope=repository:azure-cognitive-services/speechservices/neural-text-to-speech:pull" | jq -r .access_token)
curl -s -H "Authorization: Bearer $TOKEN" \
  "https://mcr.microsoft.com/v2/azure-cognitive-services/speechservices/neural-text-to-speech/tags/list?n=5000" \
  | jq -r '.tags[]' | grep -i mr-in | sort -u

# STT — same idea, different repo
TOKEN=$(curl -s "https://mcr.microsoft.com/oauth2/token?service=mcr.microsoft.com&scope=repository:azure-cognitive-services/speechservices/speech-to-text:pull" | jq -r .access_token)
curl -s -H "Authorization: Bearer $TOKEN" \
  "https://mcr.microsoft.com/v2/azure-cognitive-services/speechservices/speech-to-text/tags/list?n=5000" \
  | jq -r '.tags[]' | grep -i mr-in | sort -u
```

The output is the definitive source of truth — copy the tag you need straight into `--set image.tag=...`.

### Example 11 — Tamil STT
Use the ready-made `examples/stt-ta.yaml`:
```bash
helm install stt-ta speech-container/speech-container -n speech \
  -f examples/stt-ta.yaml \
  --set secretRef.enabled=true
```
**Result**: Tamil STT pods (5.3.0; no 5.4.0 ta-IN image yet) on the non-Hindi STT pool (`workload=stt-other`), path `/stt/ta-IN` once you add a routing overlay. Repository is auto-derived from `mode: stt` (no need to pass `image.repository`).

Alternatively, override the tag on top of the English values:
```bash
helm install stt-ta speech-container/speech-container -n speech \
  -f examples/stt-en.yaml \
  --set secretRef.enabled=true \
  --set image.tag=5.3.0-amd64-ta-in \
  --set gatewayApi.path=/stt/ta-IN
```

### Example 12 — Tamil TTS (Pallavi neural voice)
Use the ready-made `examples/tts-ta.yaml`:
```bash
helm install tts-ta speech-container/speech-container -n speech \
  -f examples/tts-ta.yaml \
  --set secretRef.enabled=true
```
**Result**: Tamil TTS pods on the non-Hindi TTS pool (`workload=tts-other`), path `/tts/ta-IN` once you add a routing overlay. Repository auto-derived from `mode: tts`.

Alternatively, override the tag on top of the English values:
```bash
helm install tts-ta speech-container/speech-container -n speech \
  -f examples/tts-en.yaml \
  --set secretRef.enabled=true \
  --set image.tag=4.9.0-amd64-ta-in-pallavineural \
  --set gatewayApi.path=/tts/ta-IN
```

### Example 13 — Generic "add any language" pattern
Substitute `<LOCALE>`, `<VERSION>`, `<VOICE>`, `<RELEASE>`:
```bash
# STT - any language
helm install <RELEASE> speech-container/speech-container -n speech \
  -f examples/stt-en.yaml \
  --set secretRef.enabled=true \
  --set image.tag=<VERSION>-amd64-<LOCALE> \
  --set gatewayApi.path=/stt/<LOCALE>

# TTS - any neural voice
helm install <RELEASE> speech-container/speech-container -n speech \
  -f examples/tts-en.yaml \
  --set secretRef.enabled=true \
  --set image.tag=<VERSION>-amd64-<LOCALE>-<VOICE>neural \
  --set gatewayApi.path=/tts/<LOCALE>
```
Add `-f examples/approuting-gateway.yaml --set gatewayApi.hostname=<hostname>` (or another routing option) to publish the path. Using NGINX Ingress instead? Set `ingress.path` too. These reuse the English examples, so the pods land on the non-Hindi `stt-other` / `tts-other` pools. For Hindi, start from `stt-hi.yaml` / `tts-hi.yaml`, or add `--set nodePool=stt-hi` / `--set nodePool=tts-hi`.

### Example 14 — Bulk install many languages
```bash
# STT — verified tags as of chart 1.4.0. Always re-check with the Tag lookup
# helper above before running; STT versions are NOT synchronized across locales.
declare -A STT_LANGS=(
  [en]="5.4.0-amd64-en-us"
  [hi]="5.4.0-amd64-hi-in"
  [ta]="5.3.0-amd64-ta-in"      # ta/mr/bn/gu still on 5.3.0
  [mr]="5.3.0-amd64-mr-in"
  [bn]="5.3.0-amd64-bn-in"
  [te]="5.4.0-amd64-te-in"      # te jumped 3.10 → 5.4; no 5.3.0-te-in tag exists
)

for lang in "${!STT_LANGS[@]}"; do
  pool=$([ "$lang" = hi ] && echo stt-hi || echo stt-other)
  helm install stt-$lang speech-container/speech-container -n speech \
    -f examples/stt-en.yaml \
    --set secretRef.enabled=true \
    --set image.tag=${STT_LANGS[$lang]} \
    --set nodePool=$pool \
    --set gatewayApi.path=/stt/$lang
done

# TTS — en/hi/ta/mr verified on 4.9.0; check te/bn with the tag lookup helper
declare -A TTS_LANGS=(
  [en]="4.9.0-amd64-en-us-avaneural"
  [hi]="4.9.0-amd64-hi-in-swaraneural"
  [ta]="4.9.0-amd64-ta-in-pallavineural"
  [mr]="4.9.0-amd64-mr-in-aarohineural"
  [te]="4.7.0-amd64-te-in-shrutineural"
  [bn]="4.7.0-amd64-bn-in-tanishaaneural"
)

for lang in "${!TTS_LANGS[@]}"; do
  pool=$([ "$lang" = hi ] && echo tts-hi || echo tts-other)
  helm install tts-$lang speech-container/speech-container -n speech \
    -f examples/tts-en.yaml \
    --set secretRef.enabled=true \
    --set image.tag=${TTS_LANGS[$lang]} \
    --set nodePool=$pool \
    --set gatewayApi.path=/tts/$lang
done
```
Add `-f examples/approuting-gateway.yaml --set gatewayApi.hostname=<hostname>` to each command to publish the paths.

> ⚠️ **Verify each tag exists on MCR before installing.** Use the [tag lookup helper](#tag-lookup-helper-before-installing-a-new-locale) snippet above — it's faster and more reliable than `docker pull`, and it catches typos before you hit `ImagePullBackOff`.

> 📦 **Capacity reminder for multi-language deployments.** Each language = one extra pod on its pool. Every non-Hindi language shares the `stt-other` / `tts-other` pool, so that pool grows with the number of languages. With chart defaults (6 CPU / 12 GiB TTS request) and a 16-core memory-optimized node, **only 2 TTS pods fit per node**, and every example runs **2 replicas** per language. Planning for 4 non-Hindi TTS languages (8 pods)? Provision **at least 4 nodes in the `tts-other` pool before installing** (or enable the cluster autoscaler), otherwise the extra pods sit in `Pending` with `FailedScheduling: Insufficient cpu` (the `workload=tts-other:NoSchedule` taint keeps other pools' nodes for their own workloads). Rule of thumb: **`ceil(TTS pods on the pool / 2)` nodes per TTS pool**, same math for STT. Each image also needs node disk (STT en-US is ~6.4 GB, TTS 1–2 GB): many languages on one pool means bigger OS disks or more nodes.

---

## Verifying the install

```bash
# 1. Check release status
helm list -n speech

# 2. Check pod placement and resources (replicas should be on different nodes)
kubectl get pods -n speech -o wide
kubectl describe pod -n speech -l app.kubernetes.io/instance=stt-en | grep -A 5 "Requests\|Limits"

# 3. Probe the container endpoints
kubectl port-forward -n speech svc/stt-en-speech-container 5001:5000 &
curl http://localhost:5001/ready    # → {"service":"speechtotext","ready":"ready","message":"Api Key is valid, no action needed."}
kubectl port-forward -n speech svc/tts-en-speech-container 5002:5000 &
curl http://localhost:5002/ready    # → {"service":"neuraltexttospeechonprem","ready":"ready",...}

# 4. Quick TTS test (English, AvaNeural): plain HTTP POST
curl -X POST "http://localhost:5002/cognitiveservices/v1" \
  -H "Content-Type: application/ssml+xml" \
  -H "X-Microsoft-OutputFormat: riff-24khz-16bit-mono-pcm" \
  --data '<speak version="1.0" xml:lang="en-US"><voice name="en-US-AvaNeural">Hello from disconnected Azure Speech.</voice></speak>' \
  --output sample-output.wav

# List supported voices on this TTS container:
curl http://localhost:5002/cognitiveservices/voices/list
```

**STT needs a WebSocket client.** The STT 5.x container serves recognition over WebSocket only; a plain `curl -X POST` to the recognition path fails (405/404). Use the Speech SDK (`pip install azure-cognitiveservices-speech`) and transcribe the WAV you just synthesized:

```python
import azure.cognitiveservices.speech as speechsdk

# Through port-forward: the SDK `host` parameter takes the bare container address
cfg = speechsdk.SpeechConfig(host="ws://localhost:5001")
cfg.speech_recognition_language = "en-US"
audio = speechsdk.audio.AudioConfig(filename="sample-output.wav")
result = speechsdk.SpeechRecognizer(speech_config=cfg, audio_config=audio).recognize_once()
print(result.reason, result.text)   # ResultReason.RecognizedSpeech Hello from disconnected Azure Speech.
```

<a id="calling-the-containers"></a>
### Calling the containers

| Exposure | STT (Speech SDK) | TTS |
|---|---|---|
| Port-forward or LoadBalancer IP | `SpeechConfig(host="ws://<ip>:5000")` | `SpeechConfig(host="http://<ip>:5000")` or `POST http://<ip>:5000/cognitiveservices/v1` |
| Gateway / Ingress with path routing | `SpeechConfig(endpoint="wss://<hostname>/stt/<locale>/speech/recognition/conversation/cognitiveservices/v1?language=<locale>")` | `POST https://<hostname>/tts/<locale>/cognitiveservices/v1` |

The SDK `host` parameter accepts only scheme, host and port, so it can't carry the `/stt/<locale>` path; use `endpoint` with the full URL when routing by path. No subscription key is needed on these calls: the container authenticates to Azure for billing, not the client to the container. Protect the route itself (private load balancer, network policy, or an API gateway in front).

---

## Production operations

**Graceful drain for live calls.** When a pod is removed (scale-in, rollout, node upgrade), it leaves the Service endpoints, so no new sessions reach it, and then runs its `preStop` sleep while open sessions finish. The examples use 300 s for STT (grace period 330 s) and 15 s for TTS (grace period 45 s). Set `preStopSleepSeconds` to your longest normal call. Sessions still open when the grace period ends are cut, and clients should reconnect.

**Rollouts on full pools.** The chart default (`maxSurge: 1`, `maxUnavailable: 0`) needs room for one extra pod. The examples use `maxSurge: 0`, `maxUnavailable: 1`, so `helm upgrade`, secret rotation and `kubectl rollout restart` work on a pool with no spare capacity, at the cost of one replica fewer during the rollout. If you enable the cluster autoscaler on the speech pools (`az aks nodepool update --enable-cluster-autoscaler --min-count 2 --max-count N`), you can go back to surging. Change the strategy through Helm values; don't `kubectl patch` chart-owned objects, because the next `helm upgrade` conflicts with or reverts the patch.

**Disruption budget.** Each release with 2 or more replicas gets a PodDisruptionBudget (`minAvailable: 1`), so node drains and AKS upgrades evict one replica at a time.

**Autoscaling.** The HPA scales on CPU (75 %). That tracks STT load reasonably, but the real STT limit is the decoder count per pod (`DECODER_MAX_COUNT`): once every decoder is busy, extra sessions wait for a free one and latency rises, even if CPU stays below the target. Size `minReplicas` for normal peak sessions (`sessions ÷ decoders per pod`) and keep `maxReplicas` within what the pool can schedule (max nodes × pods per node) and within your regional vCPU quota. For session-based scaling, use custom metrics with KEDA or the Prometheus adapter.

**TTS warm-up.** A TTS pod reports ready before its first synthesis, and that first request is slow (we measured ~11 s, against ~1.5 s for later requests). After a scale-out or rollout, send one short SSML request to each new pod (for example from a Job or your deployment pipeline) before it takes live traffic.

**Weekly TTS restart.** Microsoft recommends restarting TTS containers weekly. Schedule `kubectl rollout restart deployment/<release>-speech-container -n speech` for each TTS release (CronJob with a ServiceAccount allowed to patch deployments, or your pipeline). It works on full pools with the example rollout strategy.

**Memory and disk.**
- Neural voices fit in a 16Gi limit; **multilingual voices need 24 GB**, so set `resources.limits.memory=24Gi` for those.
- Images are large (STT en-US ~6.4 GB, TTS 1–2 GB) and pull in 20 s–1.5 min. Size node OS disks for every image on the pool. Mirror the images to Azure Container Registry, and use ACR artifact streaming or a pre-pull DaemonSet if scale-out time matters.

**Security defaults.** Pods run as the image's `nonroot` user (UID/GID 65532) with `seccompProfile: RuntimeDefault`, all capabilities dropped, privilege escalation off and no ServiceAccount token, which passes the Kubernetes "restricted" Pod Security Standard. The API key is still visible in the container's command line; see [§4](#4-speech-credentials-secret).

> 💡 **Note on `appVersion`**: `Chart.yaml` `appVersion: "5.4.0"` tracks the **STT** image line. The `app.kubernetes.io/version` label on each release is taken from the image tag it actually runs (for example `4.9.0` for a TTS release), so inventory and monitoring show the real version.

---

## Upgrading & rolling back

```bash
# Refresh repo
helm repo update speech-container

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

> ⚠️ **Upgrading from 1.3.x to 1.4.0:** 1.4.0 changes several defaults (non-root security context, TCP liveness probe, startup probe, PodDisruptionBudget, topology spread, `maxReplicas: 6`, no ServiceAccount token) and the examples no longer enable NGINX Ingress. Re-apply your example file plus a routing overlay (or `--set ingress.enabled=true`) rather than `--reuse-values`, and read the [CHANGELOG](../../CHANGELOG.md) first.

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
| Image pull fails `ImagePullBackOff` | Firewall blocks `mcr.microsoft.com` | Whitelist MCR endpoints (see [Network](#2-network--firewall-whitelisting)) |
| `helm install` errors `args.billing is required` | Forgot `--set secretRef.enabled=true` AND no inline billing | Either enable secretRef or pass `--set args.billing=...` |
| `helm install` errors `additional properties '…' not allowed` | Misspelled or unsupported key (the chart validates values against `values.schema.json`) | Fix the key name; see the [values reference](#configurable-values-reference) |
| Pod runs but `/ready` returns 503 for a few minutes | Speech model still loading from disk | Normal; the startup probe allows up to 10 min. On slow nodes raise `startupProbe.failureThreshold` |
| `CreateContainerConfigError`, `secret "…" not found` with Key Vault enabled | The CSI driver couldn't sync the Secret (identity has no access, wrong vault/tenant/client ID) | `kubectl describe pod` and `kubectl get events -n speech` show the CSI mount error; check the role assignment and `secretProviderClass.*` values |
| `kubectl rollout restart` / `helm upgrade` never finishes; new pod `Pending` with `Insufficient cpu` | Rollout strategy surges one extra pod on a full pool | Use the examples' `maxSurge: 0` / `maxUnavailable: 1`, or enable the cluster autoscaler on the pool |
| HTTPRoute returns 404 | Request `Host` header doesn't match `gatewayApi.hostname`/`hostnames`, or the path is missing the `/stt/<locale>` prefix | Call the exact hostname; add extra names under `gatewayApi.hostnames` |
| HPA stays at 1 replica under load | Metrics-server missing / wrong target | `kubectl top pods -n speech`; verify metrics-server installed |
| Both replicas of a release on one node | The pool has one node, or `topologySpread.whenUnsatisfiable=ScheduleAnyway` let the scheduler pack them | Give the pool at least 2 nodes; set `topologySpread.whenUnsatisfiable=DoNotSchedule` to make spreading mandatory |
| Speech pod on a system or other non-speech node | Soft affinity fell back because the target pool was full | Scale the pool, set `nodePoolAffinity=required`, or taint the system pool `CriticalAddonsOnly=true:NoSchedule` |
| Pod lands on (or stays `Pending` off) the wrong pool after upgrading from chart 1.2.x | Examples now target `stt-hi`/`stt-other`/`tts-hi`/`tts-other`; pools still labelled `workload=stt`/`workload=tts` | Relabel/retaint the pools (see [§3](#3-node-pools-taints--labels-four-pool-pattern)), or set `nodePool=stt` / `nodePool=tts` |

---

## Support & contributing

- Issues: https://github.com/Osshaikh/speechcontainer/issues
- Maintainer: Owais Shaikh (`osshaikh@microsoft.com`)
- License: MIT (chart) / Microsoft EULA (container images)
