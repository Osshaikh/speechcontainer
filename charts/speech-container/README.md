# speech-container — Azure AI Speech containers on Kubernetes

Helm chart for running **Azure AI Speech containers** (Speech-to-Text and Neural Text-to-Speech) on Kubernetes, with a tested path for **Azure Kubernetes Service (AKS) behind Gateway API** (AKS app routing, `approuting-istio`).

The containers run in **connected mode**: audio and text are processed inside your cluster and aren't sent to Azure, and each container reports usage to your Azure AI Speech resource for billing every 10–15 minutes. Disconnected (air-gapped) mode is a separate offering: see [Appendix A](#appendix-a--disconnected-mode).

- **Chart repo**: `https://osshaikh.github.io/speechcontainer/`
- **Source**: `https://github.com/Osshaikh/speechcontainer`
- **Chart version**: 1.4.2
- **Images**: STT 5.4.0 (en-US, hi-IN; versions differ per locale, for example ta-IN is on 5.3.0) / TTS 4.9.0 (en-US AvaNeural, hi-IN SwaraNeural, ta-IN PallaviNeural)
- **Requires**: Kubernetes ≥ 1.30, Helm ≥ 3.10 (Helm 4 supported), Azure CLI

---

## Table of Contents

1. [What you deploy](#what-you-deploy)
2. [Prerequisites](#prerequisites)
3. [Deploy (AKS + Gateway API)](#deploy-aks--gateway-api)
4. [Credentials from Azure Key Vault](#credentials-from-azure-key-vault)
5. [Calling the containers](#calling-the-containers)
6. [Adding more languages](#adding-more-languages)
7. [Configurable values reference](#configurable-values-reference)
8. [Production operations](#production-operations)
9. [Upgrading & rolling back](#upgrading--rolling-back)
10. [Uninstalling](#uninstalling)
11. [Troubleshooting](#troubleshooting)
12. Appendices: [A. Disconnected mode](#appendix-a--disconnected-mode) · [B. Other ways to expose the containers](#appendix-b--other-ways-to-expose-the-containers) · [C. Other node-pool layouts](#appendix-c--other-node-pool-layouts) · [D. Many languages at once](#appendix-d--many-languages-at-once) · [E. Other Kubernetes platforms](#appendix-e--other-kubernetes-platforms)

---

## What you deploy

```
┌──────────────────────────────────────────────────────────────────────────────┐
│                              Kubernetes Cluster                              │
│                                                                              │
│  ┌────────────┐ ┌────────────┐ ┌────────────┐ ┌────────────┐ ┌────────────┐  │
│  │system pool │ │STT Hindi   │ │STT other   │ │TTS Hindi   │ │TTS other   │  │
│  │            │ │=stt-hi     │ │=stt-other  │ │=tts-hi     │ │=tts-other  │  │
│  │CoreDNS     │ │            │ │en, ta, ... │ │            │ │en, ta, ... │  │
│  │app routing │ │STT pod(s)  │ │STT pod(s)  │ │TTS pod(s)  │ │TTS pod(s)  │  │
│  │Gateway     │ │4c / 8Gi    │ │4c / 8Gi    │ │6c / 12Gi   │ │6c / 12Gi   │  │
│  │addons      │ │            │ │            │ │            │ │            │  │
│  └──────┬─────┘ └──────┬─────┘ └──────┬─────┘ └──────┬─────┘ └──────┬─────┘  │
│         │              │              │              │              │        │
│         └──────────────┴──────────────┼──────────────┴──────────────┘        │
│                                       │                                      │
│                                Speech Secret                                 │
│             (billing URL + API key: Kubernetes Secret, or synced             │
│            from Azure Key Vault by the Secrets Store CSI Driver)             │
│                                                                              │
└───────────────────────────────────────┼──────────────────────────────────────┘
                                        │ outbound HTTPS
                                        ▼
                         ┌────────────────────────────┐
                         │  Azure AI Speech endpoint  │
                         │ usage report every 10-15 m │
                         └────────────────────────────┘
```

Four Helm releases of this chart, one per language and workload, behind one shared Gateway:

| Release | Values file | Image tag | Node pool (`nodePool`) | Route |
|---|---|---|---|---|
| `stt-hi` | `examples/stt-hi.yaml` | `5.4.0-amd64-hi-in` | `stt-hi` | `https://<host>/stt/hi-IN` |
| `stt-en` | `examples/stt-en.yaml` | `5.4.0-amd64-en-us` | `stt-other` | `https://<host>/stt/en-US` |
| `tts-hi` | `examples/tts-hi.yaml` | `4.9.0-amd64-hi-in-swaraneural` | `tts-hi` | `https://<host>/tts/hi-IN` |
| `tts-en` | `examples/tts-en.yaml` | `4.9.0-amd64-en-us-avaneural` | `tts-other` | `https://<host>/tts/en-US` |

Each release runs 2–6 replicas (HPA), spread across the nodes of its pool, with a PodDisruptionBudget, graceful drain for live calls, and a non-root security context. Every release also takes `-f examples/values-gateway-route.yaml`, which creates an HTTPRoute for its path on the shared hostname.

**Why four pools?** STT is CPU-bound and TTS is memory-bound, so each workload gets its own node family. Within each workload, Hindi gets a dedicated pool and every other language shares a second pool, so busy Hindi traffic can't starve other languages, and each pool scales and is costed on its own.

**Capacity planning** (per-pod throughput, sizing for a target call volume, reference table up to 5M calls/month) is in the [root README](../../README.md#capacity-planning).

---

## Prerequisites

### 1. AKS cluster

This guide assumes the cluster already has Gateway API with app routing, and the four speech node pools. Check:

```bash
kubectl get gatewayclass approuting-istio      # ACCEPTED=True
kubectl get nodes -L workload                  # nodes labelled stt-hi, stt-other, tts-hi, tts-other
kubectl version                                # server ≥ v1.30
```

| Pool | Runs | Taint | Label |
|---|---|---|---|
| Hindi STT | `hi-IN` STT | `workload=stt-hi:NoSchedule` | `workload=stt-hi` |
| Other STT | `en-US` and every other STT locale | `workload=stt-other:NoSchedule` | `workload=stt-other` |
| Hindi TTS | `hi-IN` neural voices | `workload=tts-hi:NoSchedule` | `workload=tts-hi` |
| Other TTS | `en-US` and every other TTS voice | `workload=tts-other:NoSchedule` | `workload=tts-other` |

Each example sets `nodePool` (for example `stt-hi`) and `nodePoolAffinity: required`. The chart turns them into a toleration for the pool's taint and a **required** node affinity for its label, so speech pods never land on the system pool or another pool. If a pool is full, new pods wait as `Pending`. For production:

- Give each pool **at least 2 nodes**. The chart spreads replicas across nodes, but on a 1-node pool both replicas share it, and a node failure or upgrade takes that language down.
- **Enable the cluster autoscaler on the speech pools** (`az aks nodepool update ... --enable-cluster-autoscaler --min-count 2 --max-count <n>`), so HPA scale-out gets nodes instead of `Pending` pods.
- To let pods fall back to other untainted nodes when their pool is full, add `--set nodePoolAffinity=preferred`. Then also taint the system pool `CriticalAddonsOnly=true:NoSchedule` so they can't land there; first check that every other workload, including the Gateway pods, tolerates the taint or has another pool to run on.

<details>
<summary>Commands to set up the cluster, if it isn't ready yet</summary>

```bash
# Gateway API with the app routing Istio implementation
az aks update -g <rg> -n <aks> --enable-gateway-api --enable-app-routing-istio

# Four pools (any pool names work; the chart only needs the taint and label)
az aks nodepool add -g <rg> --cluster-name <aks> --name stthi    --mode User \
  --node-vm-size <compute-optimized-16c> --node-count 2 \
  --node-taints workload=stt-hi:NoSchedule    --labels workload=stt-hi
az aks nodepool add -g <rg> --cluster-name <aks> --name sttother --mode User \
  --node-vm-size <compute-optimized-16c> --node-count 2 \
  --node-taints workload=stt-other:NoSchedule --labels workload=stt-other
az aks nodepool add -g <rg> --cluster-name <aks> --name ttshi    --mode User \
  --node-vm-size <memory-optimized-16c> --node-count 2 \
  --node-taints workload=tts-hi:NoSchedule    --labels workload=tts-hi
az aks nodepool add -g <rg> --cluster-name <aks> --name ttsother --mode User \
  --node-vm-size <memory-optimized-16c> --node-count 2 \
  --node-taints workload=tts-other:NoSchedule --labels workload=tts-other
```

Size each pool's node count for its languages and traffic ([Capacity planning](../../README.md#capacity-planning)). To fix the taint or label of an existing pool in place: `az aks nodepool update ... --name <pool> --labels workload=stt-other --node-taints workload=stt-other:NoSchedule`.

</details>

### 2. Azure AI Speech resource

The containers authenticate to a regular Azure AI Speech resource with its **endpoint** (the billing URL) and an **API key**. A standard `S0` resource is enough for connected mode; commitment tiers are optional pricing plans.

```bash
az cognitiveservices account create -n <speech-name> -g <rg> -l <region> \
  --kind SpeechServices --sku S0 --custom-domain <speech-name> --yes

az cognitiveservices account show -n <speech-name> -g <rg> \
  --query "{endpoint:properties.endpoint, keysDisabled:properties.disableLocalAuth}"
# endpoint     -> the billing URL, https://<speech-name>.cognitiveservices.azure.com/
# keysDisabled -> must be false or empty: the containers can't use a resource with key auth disabled

ENDPOINT=$(az cognitiveservices account show -n <speech-name> -g <rg> --query properties.endpoint -o tsv)
KEY=$(az cognitiveservices account keys list -n <speech-name> -g <rg> --query key1 -o tsv)
```

- `--custom-domain` gives the resource its own host, `<speech-name>.cognitiveservices.azure.com`. Without it, the endpoint is the shared regional host `https://<region>.api.cognitive.microsoft.com/`. Either works as the billing URL; use exactly what `properties.endpoint` returns.
- In the portal: **Create a resource** → **Speech** → pricing tier `S0`; then **Keys and Endpoint** for the endpoint and **Key 1**.
- If Azure Policy disables key authentication on Azure AI services accounts, request an exemption for this resource. The containers need the key.

### 3. Network egress

In connected mode the containers need outbound HTTPS **all the time**, not just at startup. Allow from the speech node pools:

| Destination | Port | Why |
|---|---|---|
| The host of your billing URL (`properties.endpoint` above) | TCP 443 | API key validation at startup, then usage reporting every 10–15 minutes |
| `mcr.microsoft.com`, `*.data.mcr.microsoft.com` (or your ACR, if you mirror the images) | TCP 443 | Image pulls |
| AKS required outbound endpoints | as documented | Cluster operation: [Outbound network and FQDN rules for AKS](https://learn.microsoft.com/azure/aks/outbound-rules-control-egress) |

If a running container can't reach the billing endpoint, it keeps running but stops serving requests until the connection is restored; after 10 failed attempts (10–15 minutes apart) it stops serving entirely. A new pod that can't reach it never becomes ready.

### 4. Hostname, TLS certificate and DNS

- **One hostname** for all languages, for example `speech.contoso.com`. Each language is a path under it.
- **A TLS certificate for that hostname** (PEM certificate with full chain, plus its key) that your clients trust: from your organization's CA for internal clients, or from a public CA. A self-signed certificate is fine for a test, but every client then has to trust it explicitly.
- **A DNS record** pointing the hostname at the Gateway's IP. You get the IP in [Step 3](#step-3-create-the-gateway). Use a private DNS zone if the Gateway uses an internal load balancer.

---

## Deploy (AKS + Gateway API)

Set these once, in the shell you deploy from; every command below uses them:

```bash
NS=speech                          # namespace for the releases and the Gateway
HOST=speech.contoso.com            # your hostname; must match the certificate
CHART_VERSION=1.4.2
SPEECH_NAME=your-speech-resource   # Azure AI Speech resource (Prerequisites §2)
SPEECH_RG=your-resource-group

ENDPOINT=$(az cognitiveservices account show -n "$SPEECH_NAME" -g "$SPEECH_RG" --query properties.endpoint -o tsv)
KEY=$(az cognitiveservices account keys list -n "$SPEECH_NAME" -g "$SPEECH_RG" --query key1 -o tsv)
: "${ENDPOINT:?ENDPOINT is empty: check SPEECH_NAME and SPEECH_RG}" "${KEY:?KEY is empty: is key authentication disabled?}"
```

The last line stops with an error if either value is empty; an empty billing URL or key would otherwise only show up later, as pods crash-looping with `Api Key is invalid`.

### Step 1. Get the chart and its example files

```bash
helm repo add speech-container https://osshaikh.github.io/speechcontainer/
helm repo update
helm pull speech-container/speech-container --version $CHART_VERSION --untar
cd speech-container
ls examples/    # stt-*.yaml, tts-*.yaml, values-gateway-route.yaml, gateway.yaml, ...
```

The rest of this guide runs from this directory. Installing with the same `--version` keeps the chart and its example files in step.

### Step 2. Namespace and Speech credentials

**2a. Namespace** (always):

```bash
kubectl create namespace $NS
```

**2b. Credentials Secret** (skip if you use Azure Key Vault):

```bash
kubectl create secret generic speech-credentials -n $NS \
  --from-literal=billing="$ENDPOINT" \
  --from-literal=apikey="$KEY"
```

The four releases read this Secret (`--set secretRef.enabled=true`; default name `speech-credentials`, keys `billing` and `apikey`).

- **Different Secret name or keys?** Add them to the install command in Step 4, for example `--set secretRef.name=bfl-speech-creds --set secretRef.billingKey=BILLING_URL --set secretRef.apiKeyKey=COG_KEY`.
- **Credentials in Azure Key Vault?** Skip 2b, do Step 3, then follow [Credentials from Azure Key Vault](#credentials-from-azure-key-vault) in place of Step 4.

### Step 3. Create the Gateway

```bash
# TLS certificate for $HOST (see Prerequisites §4)
kubectl create secret tls speech-tls -n $NS --cert=speech.crt --key=speech.key

# The shared Gateway: examples/gateway.yaml with your hostname, in $NS
sed "s/speech.contoso.com/$HOST/" examples/gateway.yaml | kubectl apply -n $NS -f -
kubectl wait --for=condition=Programmed gateway/speech-gateway -n $NS --timeout=5m

GW_IP=$(kubectl get gateway speech-gateway -n $NS -o jsonpath='{.status.addresses[0].value}')
echo "$GW_IP"
```

Now create the DNS record `$HOST → $GW_IP`.

`examples/gateway.yaml` is a Kubernetes manifest (apply it with `kubectl`); `examples/values-gateway-route.yaml` is the Helm values file that attaches each release to it. For a private IP, uncomment the manifest's `infrastructure.annotations` block before applying. The Gateway goes into `$NS`, next to the releases (its listener only accepts routes from its own namespace). The route file attaches by name (`speech-gateway`) and listener (`https`); if you change those, change both files.

### Step 4. Install the four releases

```bash
for rel in stt-hi stt-en tts-hi tts-en; do
  helm upgrade --install $rel speech-container/speech-container -n $NS --version $CHART_VERSION \
    -f examples/$rel.yaml \
    -f examples/values-gateway-route.yaml \
    --set secretRef.enabled=true \
    --set gatewayApi.hostname=$HOST \
    --wait --timeout 20m
done
```

- `examples/$rel.yaml` sets the image, resources, node pool (required affinity), replicas, drain settings and route path for that language.
- `examples/values-gateway-route.yaml` is a Helm values file (pass it with `-f`, don't `kubectl apply` it). It turns on the HTTPRoute and attaches it to `speech-gateway`. The install fails if `gatewayApi.hostname` is missing, rather than creating a route that answers 404.
- `--wait --timeout 20m`: the first pull of a large image plus model load can take several minutes, and the startup probe allows up to 10. Helm's default 5-minute timeout is too short.

### Step 5. Check pods and routes

```bash
kubectl get pods -n $NS -o wide          # 8 pods Running and Ready, 2 per release, on their pools
kubectl get httproute -n $NS             # stt-hi, stt-en, tts-hi, tts-en
kubectl get httproute -n $NS -o jsonpath='{range .items[*]}{.metadata.name}{": "}{range .status.parents[0].conditions[*]}{.type}={.status}{" "}{end}{"\n"}{end}'
# every route: Accepted=True ResolvedRefs=True
kubectl get pdb,hpa -n $NS
```

### Step 6. Test through the Gateway

These tests use `curl --resolve`, so they work before DNS is in place. If the certificate isn't from a CA your machine already trusts, add `--cacert <your-ca.crt>` (or `-k` for a self-signed test certificate).

**Readiness of every language:**

```bash
for path in stt/hi-IN stt/en-US tts/hi-IN tts/en-US; do
  curl -s --resolve "$HOST:443:$GW_IP" "https://$HOST/$path/ready"; echo
done
# STT: {"service":"speechtotext","ready":"ready","message":"Api Key is valid, no action needed."}
# TTS: {"service":"neuraltexttospeechonprem","ready":"ready",...}
```

**TTS (plain HTTPS POST):**

```bash
curl -s --resolve "$HOST:443:$GW_IP" -X POST "https://$HOST/tts/hi-IN/cognitiveservices/v1" \
  -H "Content-Type: application/ssml+xml" \
  -H "X-Microsoft-OutputFormat: riff-16khz-16bit-mono-pcm" \
  --data '<speak version="1.0" xml:lang="hi-IN"><voice name="hi-IN-SwaraNeural">नमस्ते, आपकी कॉल हमारे लिए महत्वपूर्ण है।</voice></speak>' \
  -o tts-hi.wav

curl -s --resolve "$HOST:443:$GW_IP" -X POST "https://$HOST/tts/en-US/cognitiveservices/v1" \
  -H "Content-Type: application/ssml+xml" \
  -H "X-Microsoft-OutputFormat: riff-16khz-16bit-mono-pcm" \
  --data '<speak version="1.0" xml:lang="en-US"><voice name="en-US-AvaNeural">Hello, your call is important to us.</voice></speak>' \
  -o tts-en.wav
```

Both files should play as speech. The first request to each TTS pod is slow (see [Step 7](#step-7-warm-up-the-tts-pods)).

**STT (Speech SDK over WebSocket), transcribing the files you just synthesized:**

STT is WebSocket only, so a plain `curl` POST doesn't work; use the Speech SDK (`pip install azure-cognitiveservices-speech`). The SDK needs `$HOST` to resolve (the DNS record, or an `/etc/hosts` entry pointing at `$GW_IP`), and the client must trust the certificate: the SDK uses the operating system's trust store (on Linux, OpenSSL: see [Configure OpenSSL for Linux](https://learn.microsoft.com/azure/ai-services/speech-service/how-to-configure-openssl-linux)).

```python
# stt_check.py    usage: python stt_check.py speech.contoso.com
import sys
import azure.cognitiveservices.speech as speechsdk

host = sys.argv[1]
for locale, wav in [("hi-IN", "tts-hi.wav"), ("en-US", "tts-en.wav")]:
    endpoint = (f"wss://{host}/stt/{locale}/speech/recognition/"
                f"conversation/cognitiveservices/v1?language={locale}")
    cfg = speechsdk.SpeechConfig(endpoint=endpoint)   # `host=` can't carry the /stt/<locale> path
    cfg.speech_recognition_language = locale
    audio = speechsdk.audio.AudioConfig(filename=wav)
    result = speechsdk.SpeechRecognizer(speech_config=cfg, audio_config=audio).recognize_once()
    print(locale, result.reason, result.text)
    if result.reason == speechsdk.ResultReason.Canceled:
        print("   ", result.cancellation_details.error_details)
```

Expected for both locales: `ResultReason.RecognizedSpeech` and the text you synthesized.

### Step 7. Warm up the TTS pods

Each TTS pod reports ready before its first synthesis, and that first request takes ~11 s (later ones ~1.5 s). Requests through the Gateway are load-balanced, so warm each pod directly, after every install, scale-out or rollout:

```bash
for rel in tts-hi tts-en; do
  if [ $rel = tts-hi ]; then lang=hi-IN voice=hi-IN-SwaraNeural; else lang=en-US voice=en-US-AvaNeural; fi
  for pod in $(kubectl get pods -n $NS -l app.kubernetes.io/instance=$rel -o name); do
    kubectl port-forward -n $NS $pod 15000:5000 >/dev/null & pf=$!; sleep 3
    curl -s -o /dev/null -w "$pod %{http_code} %{time_total}s\n" \
      -X POST http://localhost:15000/cognitiveservices/v1 \
      -H "Content-Type: application/ssml+xml" -H "X-Microsoft-OutputFormat: riff-16khz-16bit-mono-pcm" \
      --data "<speak version=\"1.0\" xml:lang=\"$lang\"><voice name=\"$voice\">Warm up.</voice></speak>"
    kill $pf; wait $pf 2>/dev/null    # release local port 15000 before the next pod
  done
done
```

---

## Credentials from Azure Key Vault

Instead of the Secret from Step 2, the chart can sync the billing URL and API key from Azure Key Vault. It renders a `SecretProviderClass` and mounts it into each pod with the Secrets Store CSI Driver; the driver reads both values from the vault and syncs them into the Kubernetes Secret named by `secretRef.name`, which the container reads at startup. Credentials never live in your Helm values, Git, or CI logs.

> ⚠️ **The synced Secret exists only while a pod mounts the volume.** The chart mounts the CSI volume into every speech pod (at `/mnt/secrets-store`, read-only). If you delete all pods, the Secret disappears until the next pod starts.

| `secretProviderClass.identity` | Identity | Use when |
|---|---|---|
| `addon` (default) | The AKS add-on's managed identity (`azurekeyvaultsecretsprovider-<cluster>`) | Quickest path; any pod on the cluster that uses a SecretProviderClass can use this identity |
| `workload` | Your own managed identity, federated to each release's ServiceAccount (Microsoft Entra Workload ID) | Vault access limited to the speech pods |

**One-time setup (both options):**

```bash
az aks enable-addons --addons azure-keyvault-secrets-provider -g <rg> -n <aks>
az keyvault create -n <kv-name> -g <rg> -l <region> --enable-rbac-authorization true
az keyvault secret set --vault-name <kv-name> --name speech-billing --value "$ENDPOINT"
az keyvault secret set --vault-name <kv-name> --name speech-apikey  --value "$KEY"
KV_ID=$(az keyvault show -n <kv-name> -g <rg> --query id -o tsv)
TENANT_ID=$(az account show --query tenantId -o tsv)
```

**Option A: add-on identity.** These commands replace Step 4 of the deploy (and Step 2b); Steps 1, 2a, 3 and 5–7 are unchanged.

```bash
ADDON_CLIENT_ID=$(az aks show -n <aks> -g <rg> \
  --query addonProfiles.azureKeyvaultSecretsProvider.identity.clientId -o tsv)
ADDON_OBJECT_ID=$(az aks show -n <aks> -g <rg> \
  --query addonProfiles.azureKeyvaultSecretsProvider.identity.objectId -o tsv)
az role assignment create --assignee-object-id "$ADDON_OBJECT_ID" \
  --assignee-principal-type ServicePrincipal --role "Key Vault Secrets User" --scope "$KV_ID"

for rel in stt-hi stt-en tts-hi tts-en; do
  helm upgrade --install $rel speech-container/speech-container -n $NS --version $CHART_VERSION \
    -f examples/$rel.yaml \
    -f examples/values-gateway-route.yaml \
    --set gatewayApi.hostname=$HOST \
    --set secretRef.enabled=true \
    --set secretRef.name=$rel-credentials \
    --set secretProviderClass.enabled=true \
    --set secretProviderClass.keyVaultName=<kv-name> \
    --set secretProviderClass.tenantId=$TENANT_ID \
    --set secretProviderClass.clientId=$ADDON_CLIENT_ID \
    --wait --timeout 20m
done
```

**Option B: Workload Identity.** Also replaces Steps 2b and 4.

```bash
az aks update -g <rg> -n <aks> --enable-oidc-issuer --enable-workload-identity
az identity create -g <rg> -n speech-mi
CLIENT_ID=$(az identity show -g <rg> -n speech-mi --query clientId -o tsv)
PRINCIPAL_ID=$(az identity show -g <rg> -n speech-mi --query principalId -o tsv)
az role assignment create --assignee-object-id "$PRINCIPAL_ID" \
  --assignee-principal-type ServicePrincipal --role "Key Vault Secrets User" --scope "$KV_ID"
OIDC=$(az aks show -n <aks> -g <rg> --query oidcIssuerProfile.issuerUrl -o tsv)

for rel in stt-hi stt-en tts-hi tts-en; do
  # The chart's ServiceAccount for a release is <release>-speech-container
  az identity federated-credential create --name $rel-fed --identity-name speech-mi -g <rg> \
    --issuer "$OIDC" --audience api://AzureADTokenExchange \
    --subject "system:serviceaccount:$NS:$rel-speech-container"

  helm upgrade --install $rel speech-container/speech-container -n $NS --version $CHART_VERSION \
    -f examples/$rel.yaml \
    -f examples/values-gateway-route.yaml \
    --set gatewayApi.hostname=$HOST \
    --set secretRef.enabled=true \
    --set secretRef.name=$rel-credentials \
    --set secretProviderClass.enabled=true \
    --set secretProviderClass.identity=workload \
    --set secretProviderClass.keyVaultName=<kv-name> \
    --set secretProviderClass.tenantId=$TENANT_ID \
    --set secretProviderClass.clientId=$CLIENT_ID \
    --wait --timeout 20m
done
```

With `identity=workload` the chart annotates the ServiceAccount it creates with `azure.workload.identity/client-id` and labels the pods `azure.workload.identity/use: "true"`. Using your own ServiceAccount (`serviceAccount.create=false`, `serviceAccount.name=...`)? Annotate it yourself and federate that name instead.

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

> 💡 **One synced Secret per release.** Each release with `create=true` renders its own SecretProviderClass. If several of them synced the *same* Secret name, they'd all write one object, and uninstalling one release could affect the others. That's why the commands above use `secretRef.name=$rel-credentials`. Alternatively, apply one shared SecretProviderClass yourself and install every release with `secretProviderClass.create=false` and `secretProviderClass.name=<shared-name>`.

> 💡 **Rotation:** the container reads the billing URL and key only at startup. After rotating them in Key Vault, restart the pods (`kubectl rollout restart deployment -n $NS <release>-speech-container`).

> ⚠️ **The API key is visible inside the pod and on the node.** The container takes its settings as command-line arguments, so the chart passes `Billing=$(BILLING_ENDPOINT)` and `ApiKey=$(BILLING_APIKEY)`, which Kubernetes expands before the process starts. `kubectl describe pod` shows only the Secret reference, but anyone who can `kubectl exec` into the pod or log in to the node can read the key from the process command line (`/proc/1/cmdline`, `ps`), and runtime audit tools may log it. Restrict `pods/exec` and node access, and rotate the key regularly. This applies to both the plain Secret and Key Vault.

---

## Calling the containers

| Exposure | STT (Speech SDK) | TTS |
|---|---|---|
| Port-forward or LoadBalancer IP | `SpeechConfig(host="ws://<ip>:5000")` | `SpeechConfig(host="http://<ip>:5000")` or `POST http://<ip>:5000/cognitiveservices/v1` |
| Gateway / Ingress with path routing | `SpeechConfig(endpoint="wss://<hostname>/stt/<locale>/speech/recognition/conversation/cognitiveservices/v1?language=<locale>")` | `POST https://<hostname>/tts/<locale>/cognitiveservices/v1` |

The SDK `host` parameter accepts only scheme, host and port, so it can't carry the `/stt/<locale>` path; use `endpoint` with the full URL when routing by path. No subscription key is needed on these calls: the container authenticates to Azure for billing, not the client to the container. Protect the route itself (private load balancer, network policy, or an API gateway in front).


---

## Adding more languages

Each extra language is one more release: reuse an example file for scheduling and resources, and override the image tag and route path.

### Image references

| Resource | Link |
|---|---|
| **STT image tags** | https://mcr.microsoft.com/product/azure-cognitive-services/speechservices/speech-to-text/tags |
| **TTS image tags** | https://mcr.microsoft.com/product/azure-cognitive-services/speechservices/neural-text-to-speech/tags |
| **Speech container how-to** | https://learn.microsoft.com/azure/ai-services/speech-service/speech-container-howto |
| **Supported locales and voices** | https://learn.microsoft.com/azure/ai-services/speech-service/language-support |
| **Voice gallery (samples)** | https://speech.microsoft.com/portal/voicegallery |

| Workload | Repository | Tag pattern |
|---|---|---|
| **STT** | `mcr.microsoft.com/azure-cognitive-services/speechservices/speech-to-text` | `<version>-amd64-<locale>`, e.g. `5.4.0-amd64-hi-in` |
| **TTS** | `mcr.microsoft.com/azure-cognitive-services/speechservices/neural-text-to-speech` | `<version>-amd64-<locale>-<voice>neural`, e.g. `4.9.0-amd64-ta-in-pallavineural` |

> ⚠️ **STT versions differ per locale.** Microsoft updates STT locales independently. As of chart 1.4.2:
>
> | STT version | Locales |
> |---|---|
> | **5.4.0** | en-US, hi-IN, te-IN, ml-IN, pa-IN, ur-IN |
> | **5.3.0** | ta-IN, mr-IN, bn-IN, gu-IN |
> | none | kn-IN (no STT container image) |
>
> TTS is more uniform: 4.9.0 covers en-US AvaNeural and the Indic voices used here (hi-IN, ta-IN, te-IN, mr-IN, bn-IN). Always check your exact tag with the helper below; copying a version from another language often ends in `ImagePullBackOff`.

### Tag lookup helper

MCR lists tags anonymously; no token or Docker needed.

Both snippets list every tag for one locale (change `mr-in`). They query STT; for TTS replace `speech-to-text` with `neural-text-to-speech`.

```bash
# bash
repo=azure-cognitive-services/speechservices/speech-to-text
curl -s "https://mcr.microsoft.com/v2/$repo/tags/list?n=10000" \
  | jq -r '.tags[]' | grep -i -- '-mr-in' | sort -V
```

```powershell
# PowerShell
$repo = 'azure-cognitive-services/speechservices/speech-to-text'
(Invoke-RestMethod "https://mcr.microsoft.com/v2/$repo/tags/list?n=10000").tags |
  Where-Object { $_ -like '*-mr-in*' } | Sort-Object
```

### Example: add Tamil STT and TTS

```bash
for rel in stt-ta tts-ta; do
  helm upgrade --install $rel speech-container/speech-container -n $NS --version $CHART_VERSION \
    -f examples/$rel.yaml \
    -f examples/values-gateway-route.yaml \
    --set secretRef.enabled=true \
    --set gatewayApi.hostname=$HOST \
    --wait --timeout 20m
done
```

`stt-ta.yaml` (5.3.0, the latest ta-IN STT image) and `tts-ta.yaml` (PallaviNeural 4.9.0) run on the shared `stt-other` / `tts-other` pools and publish `/stt/ta-IN` and `/tts/ta-IN`.

### Example: any other language

```bash
# STT, Marathi
helm upgrade --install stt-mr speech-container/speech-container -n $NS --version $CHART_VERSION \
  -f examples/stt-en.yaml -f examples/values-gateway-route.yaml \
  --set secretRef.enabled=true --set gatewayApi.hostname=$HOST \
  --set image.tag=5.3.0-amd64-mr-in \
  --set gatewayApi.path=/stt/mr-IN \
  --wait --timeout 20m

# TTS, Marathi (AarohiNeural)
helm upgrade --install tts-mr speech-container/speech-container -n $NS --version $CHART_VERSION \
  -f examples/tts-en.yaml -f examples/values-gateway-route.yaml \
  --set secretRef.enabled=true --set gatewayApi.hostname=$HOST \
  --set image.tag=4.9.0-amd64-mr-in-aarohineural \
  --set gatewayApi.path=/tts/mr-IN \
  --wait --timeout 20m
```

Starting from the English examples puts the pods on the non-Hindi `stt-other` / `tts-other` pools. For another Hindi voice, start from `tts-hi.yaml` instead (it targets `tts-hi`). To install many languages in one go, see [Appendix D](#appendix-d--many-languages-at-once).

> 📦 **Capacity:** every language adds 2 pods (the examples' minimum) to its pool. Plan **2 pods per 16-core node** for both STT and TTS: a TTS pod requests 6 cores, and an STT pod requests 4 but can burst to its 8-core limit (3 STT pods fit by request, but then can't all burst). Four non-Hindi TTS languages = 8 pods = at least 4 nodes in `tts-other`, or enable the cluster autoscaler; otherwise the extra pods stay `Pending` with `Insufficient cpu`. Each image also needs node disk (STT en-US ~6.4 GB, TTS 1–2 GB).

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
| `secretProviderClass.*` | disabled | Sync the Secret from Azure Key Vault; see [Key Vault integration](#credentials-from-azure-key-vault) |

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

### Service
| Key | Default | Notes |
|---|---|---|
| `service.type` | `ClusterIP` | Keep `ClusterIP` behind the Gateway. `LoadBalancer` exposes the release directly ([Appendix B](#appendix-b--other-ways-to-expose-the-containers)) |
| `service.port` | `5000` | Speech container HTTP port |
| `service.targetPort` | `5000` | |
| `service.annotations` | `{}` | For example the internal load balancer annotation |

NGINX Ingress values (`ingress.*`) are in [Appendix B](#nginx-ingress).

### Gateway API (HTTPRoute)
| Key | Default | Notes |
|---|---|---|
| `gatewayApi.enabled` | `false` | Render an HTTPRoute. Turned on by `examples/values-gateway-route.yaml` |
| `gatewayApi.parentRef.name` / `.namespace` / `.sectionName` | `""` | The Gateway (and listener) to attach to |
| `gatewayApi.hostname` | `""` | **Required** when `gatewayApi.enabled` (or set `hostnames`). Must be accepted by the Gateway listener |
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

## Production operations

**Graceful drain for live calls.** When a pod is removed (scale-in, rollout, node upgrade), it leaves the Service endpoints, so no new sessions reach it, and then runs its `preStop` sleep while open sessions finish. The examples use 300 s for STT (grace period 330 s) and 15 s for TTS (grace period 45 s). Set `preStopSleepSeconds` to your longest normal call. Sessions still open when the grace period ends are cut, and clients should reconnect.

**Rollouts on full pools.** The chart default (`maxSurge: 1`, `maxUnavailable: 0`) needs room for one extra pod. The examples use `maxSurge: 0`, `maxUnavailable: 1`, so `helm upgrade`, secret rotation and `kubectl rollout restart` work on a pool with no spare capacity, at the cost of one replica fewer during the rollout. If you enable the cluster autoscaler on the speech pools (`az aks nodepool update --enable-cluster-autoscaler --min-count 2 --max-count N`), you can go back to surging. Change the strategy through Helm values; don't `kubectl patch` chart-owned objects, because the next `helm upgrade` conflicts with or reverts the patch.

**Disruption budget.** Each release with 2 or more replicas gets a PodDisruptionBudget (`minAvailable: 1`), so node drains and AKS upgrades evict one replica at a time.

**Autoscaling.** The HPA scales on CPU (75 %). That tracks STT load reasonably, but the real STT limit is the decoder count per pod (`DECODER_MAX_COUNT`): once every decoder is busy, extra sessions wait for a free one and latency rises, even if CPU stays below the target. Size `minReplicas` for normal peak sessions (`sessions ÷ decoders per pod`) and keep `maxReplicas` within what the pool can schedule (max nodes × pods per node) and within your regional vCPU quota. For session-based scaling, use custom metrics with KEDA or the Prometheus adapter.

**TTS warm-up.** A TTS pod reports ready before its first synthesis, and that first request is slow (we measured ~11 s, against ~1.5 s for later requests). After a scale-out or rollout, send one short SSML request to each new pod before it takes live traffic: see [Step 7](#step-7-warm-up-the-tts-pods).

**Weekly TTS restart.** Microsoft recommends restarting TTS containers weekly. Schedule `kubectl rollout restart deployment/<release>-speech-container -n speech` for each TTS release (CronJob with a ServiceAccount allowed to patch deployments, or your pipeline). It works on full pools with the example rollout strategy.

**Memory and disk.**
- Neural voices fit in a 16Gi limit; **multilingual voices need 24 GB**, so set `resources.limits.memory=24Gi` for those.
- Images are large (STT en-US ~6.4 GB, TTS 1–2 GB) and pull in 20 s–1.5 min. Size node OS disks for every image on the pool. Mirror the images to Azure Container Registry, and use ACR artifact streaming or a pre-pull DaemonSet if scale-out time matters.

**Security defaults.** Pods run as the image's `nonroot` user (UID/GID 65532) with `seccompProfile: RuntimeDefault`, all capabilities dropped, privilege escalation off and no ServiceAccount token, which passes the Kubernetes "restricted" Pod Security Standard. The API key is still visible in the container's command line; see the warning at the end of [Credentials from Azure Key Vault](#credentials-from-azure-key-vault).

> 💡 **Note on `appVersion`**: `Chart.yaml` `appVersion: "5.4.0"` tracks the **STT** image line. The `app.kubernetes.io/version` label on each release is taken from the image tag it actually runs (for example `4.9.0` for a TTS release), so inventory and monitoring show the real version.

---

## Upgrading & rolling back

```bash
helm repo update speech-container
helm pull speech-container/speech-container --version <new-version> --untar   # matching example files
# File names changed in 1.4.2: approuting-gateway.yaml -> values-gateway-route.yaml,
# gateway-approuting.yaml -> gateway.yaml

# Re-apply the same files and flags as the install, with the new version
helm upgrade stt-hi speech-container/speech-container -n $NS --version <new-version> \
  -f examples/stt-hi.yaml -f examples/values-gateway-route.yaml \
  --set secretRef.enabled=true --set gatewayApi.hostname=$HOST \
  --wait --timeout 30m

helm history stt-hi -n $NS
helm rollback stt-hi <revision> -n $NS
```

Re-apply your files rather than using `--reuse-values`, so new chart defaults take effect. Upgrades replace one pod at a time, and each STT pod drains live calls for up to 5 minutes, so allow a longer timeout than for the install. Coming from chart 1.3.x or earlier? Read the [CHANGELOG](../../CHANGELOG.md) upgrade notes first.

---

## Uninstalling

```bash
helm uninstall stt-hi stt-en tts-hi tts-en -n $NS
kubectl delete gateway speech-gateway -n $NS       # the shared Gateway and its load balancer
kubectl delete secret speech-tls speech-credentials -n $NS
kubectl delete namespace $NS                       # optional
```

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `helm install` fails: `gatewayApi.hostname or gatewayApi.hostnames is required` | `--set gatewayApi.hostname` missing | Add `--set gatewayApi.hostname=$HOST` |
| `helm install` fails: `args.billing is required` | `--set secretRef.enabled=true` missing | Add it |
| `helm install` fails: `additional properties '…' not allowed` | Misspelled or unsupported key (values are checked against `values.schema.json`) | Fix the key; see the [values reference](#configurable-values-reference) |
| `helm install --wait` times out | First image pull and model load take longer than the timeout | Use `--timeout 20m` (30m for upgrades) |
| Pod `Pending`, `Insufficient cpu` or `didn't match Pod's node affinity` | Pool full (pods may not leave their pool), or no node carries the pool label | Add nodes or enable the cluster autoscaler on that pool; check `kubectl get nodes -L workload` |
| Upgrade or `kubectl rollout restart` never finishes; new pod `Pending` | Rollout surges an extra pod on a full pool | Keep the examples' `maxSurge: 0` / `maxUnavailable: 1`, or enable the cluster autoscaler |
| `ImagePullBackOff` | Tag doesn't exist for that locale or voice, or egress to MCR blocked | Check the tag with the [tag lookup helper](#tag-lookup-helper); check [egress](#3-network-egress) |
| STT pod log: `Subscription validation failed with status 'Invalid'. Api Key is invalid` | Wrong API key, or key and billing URL from different resources | Check that both values in the Secret (or Key Vault) come from the same Speech resource |
| TTS pod crashes: log mentions `CloudKeyAccessor` / `RSACryptoServiceProvider.Decrypt`, then `Aborted (core dumped)` | Same as above: the key can't be validated | Same fix as above |
| Key rejected although it's correct | Key authentication disabled on the Speech resource (`disableLocalAuth: true`, often set by Azure Policy) | `az cognitiveservices account show ... --query properties.disableLocalAuth`; re-enable key auth or get a policy exemption |
| `/ready` returns 503 for a few minutes after start | Model still loading | Normal; the startup probe allows 10 minutes. Raise `startupProbe.failureThreshold` on slow nodes |
| Pods were serving, then every request fails; pods still Running | Billing endpoint unreachable (firewall change, DNS, outage) | Restore egress to the billing URL host; see [Network egress](#3-network-egress) |
| `CreateContainerConfigError`, `secret "…" not found`, with Key Vault | CSI driver couldn't sync the Secret (no vault access; wrong vault, tenant or client ID) | `kubectl describe pod` and `kubectl get events -n $NS` show the mount error; check the role assignment and the `secretProviderClass.*` values |
| Gateway not `Programmed` | TLS Secret `speech-tls` missing or in another namespace; app routing Gateway API not enabled | `kubectl describe gateway speech-gateway -n $NS`; `kubectl get gatewayclass approuting-istio` |
| Route not `Accepted` | Gateway in a different namespace from the releases, `parentRef` name or `sectionName` doesn't match, or the listener doesn't accept the hostname | Apply `examples/gateway.yaml` with `-n $NS`; keep it and `examples/values-gateway-route.yaml` in step; use the listener's hostname |
| HTTPS returns 404 | Request `Host` doesn't match `gatewayApi.hostname`, or the path lacks `/stt/<locale>` / `/tts/<locale>` | Call `https://$HOST/<stt or tts>/<locale>/...`; add extra names under `gatewayApi.hostnames` |
| `curl` works with `-k` but fails without it; the SDK can't connect | Client doesn't trust the certificate | Install your CA in the client's trust store (or use `--cacert`); see [Step 6](#step-6-test-through-the-gateway) |
| First TTS request per pod takes ~11 s | Voice model not warmed up | [Step 7](#step-7-warm-up-the-tts-pods) |
| HPA stays at minimum under load | metrics-server missing, or load is decoder-bound rather than CPU-bound | `kubectl top pods -n $NS`; see [Production operations](#production-operations) |
| Both replicas of a release on one node | Pool has one node (spreading is best-effort) | Give the pool at least 2 nodes; `topologySpread.whenUnsatisfiable=DoNotSchedule` makes it mandatory |
| Speech pod on a system or other non-speech node | `nodePoolAffinity=preferred` fell back because the pool was full | Use the examples' `required`, or taint the system pool |

---

## Appendix A — Disconnected mode

Disconnected containers run with **no connection to Azure**, for air-gapped environments. They're a separate offering:

- You must [apply for access](https://aka.ms/csdisconnectedcontainers), be approved, and buy a commitment plan for disconnected containers.
- Each container first runs once with `DownloadLicense=True` and a license volume (`Mounts:License`) to download a license file, which has an expiry date. From then on it runs with that license mounted and writes usage records to an output volume (`Mounts:Output`), with no network access to Azure.
- Details: [Use containers in disconnected environments](https://learn.microsoft.com/azure/ai-services/containers/disconnected-containers).

**This chart doesn't support disconnected mode.** It has no license-download step and no license or output volumes, so it runs the containers in connected mode only. Supporting disconnected mode would need those volumes (for example persistent volumes), a license-download Job before the Deployment starts, and a process to renew licenses and collect the usage records.

---

## Appendix B — Other ways to expose the containers

The main path uses AKS app routing with Gateway API. Use **one** exposure method per release; the chart fails if both `ingress.enabled` and `gatewayApi.enabled` are on.

### Application Gateway for Containers

Same HTTPRoute as the main path, attached to an AGC Gateway. Set up the ALB Controller, the `ApplicationLoadBalancer` and the Gateway per the Microsoft Learn Application Gateway for Containers quickstart, then install each release with `-f examples/agc-overrides.yaml --set gatewayApi.hostname=$HOST` in place of `examples/values-gateway-route.yaml`.

<a id="nginx-ingress"></a>
### NGINX Ingress

Only if the cluster already runs an NGINX ingress controller. Upstream ingress-nginx maintenance ended in March 2026; AKS supports its app routing NGINX with critical security patches through November 2026. Prefer Gateway API for new clusters.

```bash
helm upgrade --install stt-en speech-container/speech-container -n $NS --version $CHART_VERSION \
  -f examples/stt-en.yaml \
  --set secretRef.enabled=true \
  --set ingress.enabled=true \
  --set ingress.host=$HOST \
  --set ingress.path=/stt/en-US \
  --set ingress.tls.enabled=true \
  --set ingress.tls.secretName=speech-tls
# cert-manager: add --set 'ingress.annotations.cert-manager\.io/cluster-issuer=<issuer>'
```

| Key | Default | Notes |
|---|---|---|
| `ingress.enabled` | `false` | Per-release NGINX Ingress |
| `ingress.className` | `nginx` | |
| `ingress.host` | `""` | Required when enabled |
| `ingress.path` | `""` | Required when enabled, e.g. `/stt/en-US`; stripped before forwarding |
| `ingress.proxyReadTimeout` / `ingress.proxySendTimeout` | `3600` | Long STT WebSocket sessions |
| `ingress.proxyBodySize` | `10m` | TTS SSML payloads |
| `ingress.tls.enabled` / `ingress.tls.secretName` | `false` / `""` | |
| `ingress.annotations` | `{}` | Extra controller annotations |

### LoadBalancer per release

One IP per language, with no path routing and no TLS at the platform. Clients use the SDK `host` parameter (`ws://<ip>:5000` for STT, `http://<ip>:5000` for TTS).

```bash
# Private IP in the cluster VNet
helm upgrade --install tts-hi speech-container/speech-container -n $NS --version $CHART_VERSION \
  -f examples/tts-hi.yaml -f examples/internal-lb.yaml \
  --set secretRef.enabled=true
kubectl get svc -n $NS tts-hi-speech-container     # EXTERNAL-IP is the private IP

# Public IP: use --set service.type=LoadBalancer instead of the internal-lb.yaml overlay
```

Don't combine `internal-lb.yaml` with a Gateway overlay: that gives the release two entry points.

---

## Appendix C — Other node-pool layouts

- **Two pools** (`workload=stt` and `workload=tts`): add `--set nodePool=stt` to STT releases and `--set nodePool=tts` to TTS releases.
- **One shared pool** (`workload=speech`): add `-f examples/prod-overrides.yaml` (sets `nodePool: speech`).
- **No dedicated pools:** `--set nodePool=""` schedules on any node.
- **Different taint key or value**, for example `dedicated=speech-prod`: `--set nodePoolKey=dedicated --set nodePool=speech-prod`. The chart generates the matching toleration and affinity. Setting `affinity` directly replaces the generated affinity; the `nodePool` toleration is kept.
- **Fixed replica count** (no HPA): `--set autoscaling.enabled=false --set replicaCount=3`.

---

## Appendix D — Many languages at once

Works in bash and zsh; one line per release (`release tag pool path`):

```bash
while read -r rel tag pool path; do
  helm upgrade --install "$rel" speech-container/speech-container -n "$NS" --version "$CHART_VERSION" \
    -f "examples/${rel%%-*}-en.yaml" -f examples/values-gateway-route.yaml \
    --set secretRef.enabled=true --set gatewayApi.hostname="$HOST" \
    --set image.tag="$tag" --set nodePool="$pool" --set gatewayApi.path="$path" \
    --wait --timeout 20m
done <<'EOF'
stt-te 5.4.0-amd64-te-in                stt-other /stt/te-IN
stt-mr 5.3.0-amd64-mr-in                stt-other /stt/mr-IN
stt-bn 5.3.0-amd64-bn-in                stt-other /stt/bn-IN
tts-te 4.9.0-amd64-te-in-shrutineural   tts-other /tts/te-IN
tts-mr 4.9.0-amd64-mr-in-aarohineural   tts-other /tts/mr-IN
tts-bn 4.9.0-amd64-bn-in-tanishaaneural tts-other /tts/bn-IN
EOF
```

`${rel%%-*}-en.yaml` picks `stt-en.yaml` or `tts-en.yaml` as the base. Tags verified on MCR for chart 1.4.2; check new ones with the [tag lookup helper](#tag-lookup-helper). Size the pools first (see the capacity note in [Adding more languages](#adding-more-languages)).

---

## Appendix E — Other Kubernetes platforms

The chart uses standard Kubernetes APIs (Deployment, Service, HTTPRoute or Ingress, HPA, PDB) and runs on any conformant cluster; only AKS is tested end to end.

| Platform | Notes |
|---|---|
| **Amazon EKS** | Taint and label node groups with `eksctl` (`--node-labels`, `--node-taints`). Secrets: AWS Secrets Manager via the Secrets Store CSI Driver AWS provider, or External Secrets Operator, syncing a Secret that `secretRef.name` points at |
| **Google GKE** | `gcloud container node-pools create ... --node-labels=workload=stt-hi --node-taints=workload=stt-hi:NoSchedule`. Secrets: Secret Manager via the CSI Driver GCP provider |
| **Red Hat OpenShift 4.x** | Pods already run non-root. Under the `restricted-v2` SCC, let OpenShift assign the UID: `--set podSecurityContext.runAsUser=null --set podSecurityContext.runAsGroup=null`. Expose with a `Route` |
| **Vanilla / kubeadm** | `kubectl taint nodes <node> workload=stt-hi:NoSchedule` and `kubectl label nodes <node> workload=stt-hi`; bring your own Gateway API implementation or ingress controller |
| **kind / k3d** (dev only) | Resource requests (4 cores STT, 6 cores TTS) usually exceed laptop capacity |

The `secretProviderClass.*` values target the Azure Key Vault provider. On other platforms, create or sync the Secret yourself and point `secretRef.name` at it.

---

## Support & contributing

- Issues: https://github.com/Osshaikh/speechcontainer/issues
- Maintainer: Owais Shaikh (`osshaikh@microsoft.com`)
- License: MIT (chart) / Microsoft EULA (container images)
