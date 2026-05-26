# speech-container — Azure AI Speech Disconnected Containers on Kubernetes

A production-ready Helm chart for deploying **Azure AI Speech disconnected containers** (Speech-to-Text and Neural Text-to-Speech) on **any conformant Kubernetes platform**, with first-class guidance for **Azure Kubernetes Service (AKS)**.

Replaces the abandoned `microsoft/cognitive-services-speech-onpremise` chart (v0.3.3, June 2021) with parameterised CPU/memory, modern Kubernetes APIs, taint+toleration scheduling, and secret-based credentials.

- **Chart repo**: `https://osshaikh.github.io/speechcontainer/`
- **Source**: `https://github.com/Osshaikh/speechcontainer`
- **App version**: 5.3.0 (STT) / 4.7.0 (TTS — current line; some legacy en-US/hi-IN voices also published on 4.6.0). New locales (ta-IN, mr-IN, te-IN, bn-IN, gu-IN, kn-IN, ml-IN, pa-IN, ur-IN, …) **ship only on 4.7.0** — always prefer 4.7.0 unless you have a specific reason to pin an older voice. See [image references](#image--documentation-references) and the [tag lookup helper](#tag-lookup-helper-before-installing-a-new-locale).
- **Chart version**: 1.1.7
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
   - [Node pools, taints & labels](#3-node-pools-taints--labels-split-pool-pattern)
   - [Speech credentials secret](#4-speech-credentials-secret)
   - [Azure Key Vault integration (AKS)](#azure-key-vault-integration-aks)
   - [Ingress controller](#5-ingress-controller-or-gateway-api)
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
- Helm ≥ **3.10** (Helm 4.x also tested and supported)
- An ingress controller **or** Gateway API implementation (chart examples assume `ingress-nginx`; **AGC** is recommended for AKS — see §5)

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

**No inbound from the public internet is required** unless you expose ingress externally.

> 💡 **AKS:** Mirror the Speech images into Azure Container Registry (ACR) for air-gapped clusters — `az acr import --source mcr.microsoft.com/azure-cognitive-services/speechservices/speech-to-text:5.4.0-amd64-en-us --name <acr> --image speechservices/speech-to-text:5.4.0-amd64-en-us`. Override `image.repository=<acr>.azurecr.io/speechservices/speech-to-text` at install time. After this, MCR egress is no longer required — only `<resource>.cognitiveservices.azure.com` and `<region>.api.cognitive.microsoft.com` remain.

> 🔒 **Azure Firewall / NSG users:** Cognitive Services FQDNs sit behind Front Door, so IP-based allowlists are brittle. Use **FQDN-based application rules** in Azure Firewall, or **Service Tags** (`CognitiveServicesManagement`) for NSG. The Service Tag covers both `*.cognitiveservices.azure.com` and `*.api.cognitive.microsoft.com` across all regions in a single rule.

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

<a id="azure-key-vault-integration-aks"></a>
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

### 5. Ingress controller (or Gateway API)

The chart supports **two mutually exclusive** routing layers per release:

| Layer | When to use | Status |
|---|---|---|
| **`Ingress`** (nginx, traefik, …) | Any K8s cluster with a legacy ingress controller. Works today on AKS, EKS, GKE, OpenShift, vanilla. | ⚠️ `ingress-nginx` is in **maintenance mode** — Kubernetes is moving to Gateway API. Fine to use today; plan migration. |
| **`HTTPRoute`** (Gateway API) | AKS + **Application Gateway for Containers (AGC)**, or any Gateway API implementation (Envoy Gateway, Cilium, Contour, etc.) | ✅ Recommended for new AKS deployments. AGC is Microsoft's strategic L7 for AKS and speaks Gateway API natively. |

Pick **one** per release: `ingress.enabled=true` **OR** `gatewayApi.enabled=true`. The chart fails fast at template time if you accidentally enable both.

---

#### 5a. Option 1 — NGINX Ingress (legacy, still works)

Install `ingress-nginx` once per cluster before installing the speech chart:

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

The `examples/stt-*.yaml` and `examples/tts-*.yaml` files default to `ingress.enabled=true`. No further configuration needed.

---

#### 5b. Option 2 — Application Gateway for Containers (AGC) on AKS

**One-time cluster setup** (do this once, not per language container). This follows the [official Microsoft Quickstart](https://learn.microsoft.com/azure/application-gateway/for-containers/quickstart-deploy-application-gateway-for-containers-alb-controller-helm) — refer to it for the latest ALB Controller chart version and any new prerequisites.

> 💡 **Why no `kubectl apply ... gateway-api/standard-install.yaml`?** The Microsoft `alb-controller` Helm chart **bundles the Gateway API Standard channel CRDs** and applies them as part of `helm install`. You only need a separate CRD install on non-AGC implementations (Istio, Envoy Gateway, Cilium, NGINX Gateway Fabric, etc.).

> 🔴 **CRITICAL — RBAC: the Reader role alone is NOT enough.** Many older guides (and earlier versions of this README) show only a Reader role assignment on the AKS node RG. With only that, `helm install` succeeds, controller pods come up Running, **but AGC never provisions** — the ApplicationLoadBalancer CR sits at `Deployment=InProgress` forever and the controller logs show `AuthorizationFailed: ... Microsoft.ServiceNetworking/trafficControllers/write`. You MUST also assign **AppGw for Containers Configuration Manager** (lets the controller create the traffic controller + associations) and **Network Contributor** scoped to the AGC subnet (lets the controller create the AGC frontend NIC in your subnet). Both are included in the snippet below.

> 🟠 **HIGH — Subnet delegation is required and is NOT done automatically.** AGC needs its association subnet pre-delegated to `Microsoft.ServiceNetworking/trafficControllers`. The ALB Controller does NOT auto-delegate. Without delegation, the controller logs `AppGwForContainersAssociationSubnetNotDelegatedToTrafficController`. Step 4 below delegates the subnet before the ALB CR is applied. The subnet must also be (a) **/24 or larger**, (b) **empty** of other workloads, and (c) **in the same VNet as the AKS cluster** (peered VNets are not supported).

> ⚠️ **Re-running after a failed install?** Several commands below are not idempotent (`az identity federated-credential create`, `az role assignment create` re-creates duplicates, `helm install` fails on existing release names). If you're cleaning up a partial install, delete the existing `azure-alb-identity` MI and its federated credential first, OR append `|| true` to the create commands.

> ⚠️ **Do NOT use ALB chart `1.0.0`.** That release has a malformed `values.schema.json` (`json-pointer ... imagePullSecret not found`) that breaks both `helm install` (when omitting the imagePullSecret flag) and `helm upgrade --reuse-values`. Always use a recent version — the snippet below pins `1.10.28` as a known-good baseline. Check the [latest tag list on MCR](https://mcr.microsoft.com/artifact/mar/application-lb/charts/alb-controller/tags) for newer releases.

```bash
# 0. Ensure the speech namespace exists (the ALB CR, TLS Secret, and Gateway all live in it)
kubectl create namespace speech --dry-run=client -o yaml | kubectl apply -f -

# 1. Register the required resource providers and install the alb CLI extension
az provider register --namespace Microsoft.ContainerService
az provider register --namespace Microsoft.Network
az provider register --namespace Microsoft.NetworkFunction
az provider register --namespace Microsoft.ServiceNetworking
az extension add --name alb

# Poll until Microsoft.ServiceNetworking is fully Registered (the others are usually already on for AKS clusters)
until [ "$(az provider show -n Microsoft.ServiceNetworking --query registrationState -o tsv)" = "Registered" ]; do
  echo "Waiting for Microsoft.ServiceNetworking registration..."; sleep 20;
done

# 2. Ensure your AKS cluster has OIDC issuer + Workload Identity enabled (skip if already on)
az aks update -g <rg> -n <aks-name> --enable-oidc-issuer --enable-workload-identity

# 3. Create a managed identity for ALB Controller and federate it to the AKS service account
RESOURCE_GROUP=<rg>
AKS_NAME=<aks-name>
IDENTITY_NAME=azure-alb-identity
CONTROLLER_NAMESPACE=azure-alb-system

mcRG=$(az aks show -g $RESOURCE_GROUP -n $AKS_NAME --query nodeResourceGroup -o tsv)
az identity create -g $RESOURCE_GROUP -n $IDENTITY_NAME
PRINCIPAL_ID=$(az identity show -g $RESOURCE_GROUP -n $IDENTITY_NAME --query principalId -o tsv)
CLIENT_ID=$(az identity show -g $RESOURCE_GROUP -n $IDENTITY_NAME --query clientId -o tsv)
sleep 60   # let Entra ID replicate before role assignment

az role assignment create --assignee-object-id $PRINCIPAL_ID --assignee-principal-type ServicePrincipal \
  --scope $(az group show -n $mcRG --query id -o tsv) \
  --role "acdd72a7-3385-48ef-bd42-f606fba81ae7"   # Reader (read AKS node RG resources)

# 🔴 CRITICAL — also grant the controller permission to CREATE/UPDATE the AGC traffic controller resource.
az role assignment create --assignee-object-id $PRINCIPAL_ID --assignee-principal-type ServicePrincipal \
  --scope $(az group show -n $mcRG --query id -o tsv) \
  --role "fbc52c3f-28ad-4303-a892-8a056630b8f1"   # AppGw for Containers Configuration Manager

AKS_OIDC=$(az aks show -g $RESOURCE_GROUP -n $AKS_NAME --query oidcIssuerProfile.issuerUrl -o tsv)
az identity federated-credential create --name $IDENTITY_NAME \
  --identity-name $IDENTITY_NAME --resource-group $RESOURCE_GROUP \
  --issuer "$AKS_OIDC" \
  --subject "system:serviceaccount:${CONTROLLER_NAMESPACE}:alb-controller-sa"

# 4. 🟠 Delegate the AGC association subnet to Microsoft.ServiceNetworking/trafficControllers,
#    and grant the MI Network Contributor on that subnet. Both are required for the AGC
#    frontend NIC to provision into the subnet. Replace <vnet> and <subnet> with your values.
VNET_NAME=<vnet-name>            # e.g. aks-vnet-xxxxxxxx (lives in the node RG by default)
SUBNET_NAME=<subnet-name>        # e.g. aks-appgateway — dedicated /24+ subnet for AGC

az network vnet subnet update -g $mcRG --vnet-name $VNET_NAME -n $SUBNET_NAME \
  --delegations "Microsoft.ServiceNetworking/trafficControllers"

SUBNET_ID=$(az network vnet subnet show -g $mcRG --vnet-name $VNET_NAME -n $SUBNET_NAME --query id -o tsv)

az role assignment create --assignee-object-id $PRINCIPAL_ID --assignee-principal-type ServicePrincipal \
  --scope $SUBNET_ID \
  --role "4d97b98b-1d4f-4787-a291-c67834d212e7"   # Network Contributor (scoped to AGC subnet only)

# 5. Install the ALB Controller via Helm (this also installs the Gateway API CRDs automatically)
#    Check the latest chart version at: https://mcr.microsoft.com/artifact/mar/application-lb/charts/alb-controller/tags
#    ⚠️ Do not use 1.0.0 — broken values.schema.json. 1.10.28 is the known-good baseline.
helm install alb-controller \
  oci://mcr.microsoft.com/application-lb/charts/alb-controller \
  --version 1.10.28 \
  --namespace $CONTROLLER_NAMESPACE --create-namespace \
  --set albController.namespace=$CONTROLLER_NAMESPACE \
  --set albController.podIdentity.clientID=$CLIENT_ID

# Verify controller is up and the GatewayClass is registered
kubectl get pods -n azure-alb-system
kubectl get gatewayclass azure-alb-external

# 6. Create an ApplicationLoadBalancer custom resource (provisions the actual AGC resource in Azure).
#    $SUBNET_ID was captured in step 4 above.
kubectl apply -f - <<EOF
apiVersion: alb.networking.azure.io/v1
kind: ApplicationLoadBalancer
metadata:
  name: speech-alb
  namespace: speech
spec:
  associations:
    - $SUBNET_ID
EOF

# Wait for the ALB CR to reach Deployment=True with reason=Succeeded (typically 3-5 minutes).
# If it stays at Deployment=InProgress, check `kubectl logs -n azure-alb-system -l app=alb-controller`
# for AuthorizationFailed (missing RBAC) or AppGwForContainersAssociationSubnetNotDelegated (missing
# delegation) — the two most common bring-up failures.

# 7. Create the TLS Secret that the HTTPS listener will reference
#    Choose ONE of the three options below (dev / cert-manager / Azure Key Vault).

# --- Option A (dev/test only): self-signed cert ---
# openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
#   -keyout tls.key -out tls.crt \
#   -subj "/CN=speech.example.com" \
#   -addext "subjectAltName=DNS:speech.example.com"
# kubectl create secret tls speech-tls --cert=tls.crt --key=tls.key -n speech

# --- Option B (production): cert-manager + Let's Encrypt (most common pattern) ---
# After installing cert-manager and configuring a ClusterIssuer (e.g. letsencrypt-prod
# with HTTP-01 or DNS-01 solver), create a Certificate resource — cert-manager will
# populate the Secret named below automatically and rotate it before expiry:
# kubectl apply -f - <<EOF
# apiVersion: cert-manager.io/v1
# kind: Certificate
# metadata:
#   name: speech-tls
#   namespace: speech
# spec:
#   secretName: speech-tls            # ← Secret name referenced by the Gateway below
#   issuerRef:
#     name: letsencrypt-prod
#     kind: ClusterIssuer
#   dnsNames:
#     - speech.example.com
# EOF

# --- Option C (production, Azure-native): Azure Key Vault cert via Secrets Store CSI driver ---
# Enable on AKS once:  az aks enable-addons -g <rg> -n <aks> --addons azure-keyvault-secrets-provider
# Then create a SecretProviderClass referencing your Key Vault cert and set
# secretObjects[].secretName=speech-tls so the cert is projected as a kubernetes.io/tls Secret.
# Reference docs: https://learn.microsoft.com/azure/aks/csi-secrets-store-driver

# Verify the Secret exists and is of type kubernetes.io/tls before creating the Gateway:
kubectl get secret speech-tls -n speech -o jsonpath='{.type}'   # → kubernetes.io/tls

# 8. Create the parent Gateway resource (HTTPS listener with TLS, hostname your DNS points at)
kubectl apply -f - <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: speech-gateway
  namespace: speech
  annotations:
    alb.networking.azure.io/alb-namespace: speech
    alb.networking.azure.io/alb-name: speech-alb
spec:
  gatewayClassName: azure-alb-external
  listeners:
    - name: https
      protocol: HTTPS
      port: 443
      hostname: speech.example.com
      tls:
        mode: Terminate
        certificateRefs:
          - kind: Secret
            name: speech-tls
      allowedRoutes:
        namespaces:
          from: Same
EOF

# Verify the Gateway provisions an Azure AGC frontend IP/FQDN
kubectl get gateway speech-gateway -n speech -o jsonpath='{.status.addresses[0].value}'
```

> 🔐 **TLS prerequisite reminder:** The HTTPS Gateway above will stay `PROGRAMMED=False` until the `speech-tls` Secret exists in the `speech` namespace (created in step 6). If you're just doing a quick smoke test and don't yet have a cert, switch the listener to `protocol: HTTP, port: 80` and drop the `tls:` block — then add HTTPS later as a Secret swap + listener change (no chart edit needed). After the Gateway shows `PROGRAMMED=True`, CNAME `speech.example.com` → the AGC frontend FQDN so the SNI in the TLS handshake matches the listener `hostname`.

> 📚 **Authoritative AGC install docs:** https://learn.microsoft.com/azure/application-gateway/for-containers/quickstart-deploy-application-gateway-for-containers-alb-controller — follow the workload identity / managed identity path that matches your AKS cluster's identity model.

**Per-release install** — layer the `agc-overrides.yaml` overlay on top of any language example:

> 💡 **Why does the Gujarati install reference `stt-en.yaml` / `tts-en.yaml`?** The `*-en.yaml` files are used as **base scheduling / resource templates** (CPU, memory, tolerations, affinity, HPA) — they're locale-agnostic. The locale-specific image is overridden at install time via `--set image.tag=...`. The chart does not ship a per-language example file; the `-en` files are simply the canonical STT/TTS base.

```bash
# Pull the chart locally to get all example files
helm pull speech-container/speech-container --untar
ls speech-container/examples/
# → agc-overrides.yaml is one of the files

# STT Gujarati via AGC
helm install stt-gu speech-container/speech-container -n speech \
  -f speech-container/examples/stt-en.yaml \
  -f speech-container/examples/agc-overrides.yaml \
  --set secretRef.enabled=true \
  --set image.tag=5.3.0-amd64-gu-in \
  --set gatewayApi.path=/stt/gu-IN

# TTS Gujarati via AGC
helm install tts-gu speech-container/speech-container -n speech \
  -f speech-container/examples/tts-en.yaml \
  -f speech-container/examples/agc-overrides.yaml \
  --set secretRef.enabled=true \
  --set image.tag=4.7.0-amd64-gu-in-dhwanineural \
  --set gatewayApi.path=/tts/gu-IN
```

The chart will render an `HTTPRoute` (instead of `Ingress`) that attaches to your `speech-gateway` and applies the same path-prefix → strip → backend logic. Verify:

```bash
kubectl get httproute -n speech
# NAME                          HOSTNAMES                 AGE
# stt-gu-speech-container       ["speech.example.com"]    2m
# tts-gu-speech-container       ["speech.example.com"]    1m

# Smoke-test before DNS is set up: use --resolve to point speech.example.com at the AGC frontend
AGC_FQDN=$(kubectl get gateway speech-gateway -n speech -o jsonpath='{.status.addresses[0].value}')
AGC_IP=$(dig +short $AGC_FQDN | head -1)
curl -k --resolve speech.example.com:443:$AGC_IP \
  https://speech.example.com/tts/gu-IN/cognitiveservices/voices/list

# (-k is needed only while you're using the Option A self-signed cert.
#  Once DNS is set up: CNAME speech.example.com → $AGC_FQDN, then drop --resolve and -k.)
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
ls speech-container/examples/   # stt-en.yaml, stt-hi.yaml, stt-ta.yaml, tts-en.yaml, tts-hi.yaml, tts-ta.yaml, prod-overrides.yaml, agc-overrides.yaml
```

---

## Configurable values reference

All values configurable via `--set`, `--set-json`, or `-f values.yaml`.

### Image
| Key | Default | Notes |
|---|---|---|
| `image.repository` | *(set per mode in examples)* | `mcr.microsoft.com/azure-cognitive-services/speechservices/speech-to-text` or `…/neural-text-to-speech` |
| `image.tag` | `5.3.0-amd64-en-us` (STT) / `4.7.0-amd64-en-us-avaneural` (TTS) | Locale-specific image tag |
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
| **STT** | `mcr.microsoft.com/azure-cognitive-services/speechservices/speech-to-text` | `<version>-amd64-<locale>` (e.g. `5.3.0-amd64-ta-in`) |
| **TTS** | `mcr.microsoft.com/azure-cognitive-services/speechservices/neural-text-to-speech` | `<version>-amd64-<locale>-<voice>neural` (e.g. `4.7.0-amd64-ta-in-pallavineural`) |

Locale codes follow BCP-47: `en-US`, `hi-IN`, `ta-IN`, `te-IN`, `mr-IN`, `bn-IN`, `gu-IN`, `kn-IN`, `ml-IN`, `pa-IN`, `ur-IN`, etc.

> 💡 **Tip:** Open the MCR tags page for STT or TTS above to see every locale + version Microsoft has published. The TTS voice gallery lets you hear samples before picking a `<voice>neural` to deploy.

> ⚠️ **TTS version stream — read this before adding any non-English/Hindi locale.** Microsoft publishes TTS images on **two parallel streams**: `4.6.0` (legacy — only some en-US and hi-IN voices) and `4.7.0` (current — all en-US, hi-IN, plus every Indic locale: `ta`, `mr`, `te`, `bn`, `gu`, `kn`, `ml`, `pa`, `ur`, …). **There is no `4.6.0` tag for ta-IN, mr-IN, te-IN, bn-IN, gu-IN, kn-IN, ml-IN, pa-IN, or ur-IN.** Always default to **`4.7.0`** for TTS unless you have a specific reason to pin an older en-US/hi-IN voice. Following an old `4.6.0` pattern for a new locale will cause `ImagePullBackOff`.

> ⚠️ **STT version is per-locale — DO NOT assume one version covers all languages.** Unlike TTS (where 4.7.0 is universal), STT versions are **not synchronized across locales**. As of this writing:
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
**Result**: Tamil STT pod on `sttpool`, ingress at `speech.example.com/stt/ta-IN`. Repository is auto-derived from `mode: stt` (no need to pass `image.repository`).

Alternatively, override the tag on top of the English values:
```bash
helm install stt-ta speech-container/speech-container -n speech \
  -f examples/stt-en.yaml \
  --set secretRef.enabled=true \
  --set image.tag=5.3.0-amd64-ta-in \
  --set ingress.path=/stt/ta-IN
```

### Example 12 — Tamil TTS (Pallavi neural voice)
Use the ready-made `examples/tts-ta.yaml`:
```bash
helm install tts-ta speech-container/speech-container -n speech \
  -f examples/tts-ta.yaml \
  --set secretRef.enabled=true
```
**Result**: Tamil TTS pod on `ttspool`, ingress at `speech.example.com/tts/ta-IN`. Repository auto-derived from `mode: tts`.

Alternatively, override the tag on top of the English values:
```bash
helm install tts-ta speech-container/speech-container -n speech \
  -f examples/tts-en.yaml \
  --set secretRef.enabled=true \
  --set image.tag=4.7.0-amd64-ta-in-pallavineural \
  --set ingress.path=/tts/ta-IN
```

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
# STT — verified tags as of chart 1.1.9. Always re-check with the Tag lookup
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
  helm install stt-$lang speech-container/speech-container -n speech \
    -f examples/stt-en.yaml \
    --set secretRef.enabled=true \
    --set image.tag=${STT_LANGS[$lang]} \
    --set ingress.path=/stt/$lang
done

# TTS — 4.7.0 is the universal current line for every locale Microsoft publishes
declare -A TTS_LANGS=(
  [en]="4.7.0-amd64-en-us-avaneural"
  [hi]="4.7.0-amd64-hi-in-swaraneural"
  [ta]="4.7.0-amd64-ta-in-pallavineural"
  [te]="4.7.0-amd64-te-in-shrutineural"
  [mr]="4.7.0-amd64-mr-in-aarohineural"
  [bn]="4.7.0-amd64-bn-in-tanishaaneural"
)

for lang in "${!TTS_LANGS[@]}"; do
  helm install tts-$lang speech-container/speech-container -n speech \
    -f examples/tts-en.yaml \
    --set secretRef.enabled=true \
    --set image.tag=${TTS_LANGS[$lang]} \
    --set ingress.path=/tts/$lang
done
```

> ⚠️ **Verify each tag exists on MCR before installing.** Use the [tag lookup helper](#tag-lookup-helper-before-installing-a-new-locale) snippet above — it's faster and more reliable than `docker pull`, and it catches typos before you hit `ImagePullBackOff`.

> 📦 **Capacity reminder for multi-language deployments.** Each language = one extra pod on `ttspool` (or `sttpool`). With chart defaults (6 CPU / 12 GiB TTS request) and a 16-core memory-optimized node, **only 2 TTS pods fit per node**. Planning for 4 TTS languages? Provision **at least 2 nodes in `ttspool` before installing**, otherwise the 3rd/4th pod will sit in `Pending` with `FailedScheduling: Insufficient cpu` (the `workload=tts:NoSchedule` taint prevents fallback to other pools by design). Rule of thumb: **`ceil(num_TTS_languages / 2)` ttspool nodes**, same math for STT.

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
curl http://localhost:5001/ready    # → {"service":"speechtotext","ready":"ready","message":"Api Key is valid, no action needed."}

# 4. Quick STT test (English)
curl -X POST "http://localhost:5001/speech/recognition/conversation/cognitiveservices/v1?language=en-US" \
  -H "Content-Type: audio/wav" \
  --data-binary "@sample.wav"

# 5. Quick TTS test (English, AvaNeural)
kubectl port-forward -n speech svc/tts-en-speech-container 5002:5000 &
curl http://localhost:5002/ready    # → {"service":"neuraltexttospeechonprem","ready":"ready","message":"Api Key is valid, no action needed."}

curl -X POST "http://localhost:5002/cognitiveservices/v1" \
  -H "Content-Type: application/ssml+xml" \
  -H "X-Microsoft-OutputFormat: riff-24khz-16bit-mono-pcm" \
  --data '<speak version="1.0" xml:lang="en-US"><voice name="en-US-AvaNeural">Hello from disconnected Azure Speech.</voice></speak>' \
  --output sample-output.wav

# Play sample-output.wav in any audio player — should hear synthesized speech.

# List supported voices on this TTS container:
curl http://localhost:5002/cognitiveservices/voices/list
```

> 💡 **Note on `appVersion`**: The `Chart.yaml` `appVersion: "5.3.0"` tracks the **STT** image line. TTS uses an independent version stream (currently `4.7.0`; some en-US/hi-IN voices are also still published on `4.6.0`). Each example file pins its own image tag — see the [image naming pattern](#image-naming-pattern) section for current versions per workload.

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
| Pod runs but `/ready` returns 503 for ~60s | Speech model still loading from disk | Wait 60–90s; increase readiness probe `initialDelaySeconds` if needed |
| HPA stays at 1 replica under load | Metrics-server missing / wrong target | `kubectl top pods -n speech`; verify metrics-server installed |
| Multiple pods on same node despite split-pool | Soft affinity fell back because target pool full | Scale STT/TTS pool, or check for taint mismatch |

---

## Support & contributing

- Issues: https://github.com/Osshaikh/speechcontainer/issues
- Maintainer: Owais Shaikh (`osshaikh@microsoft.com`)
- License: MIT (chart) / Microsoft EULA (container images)
