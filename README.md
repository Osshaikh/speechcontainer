# speech-container

[![Lint chart](https://github.com/Osshaikh/speechcontainer/actions/workflows/lint.yml/badge.svg)](https://github.com/Osshaikh/speechcontainer/actions/workflows/lint.yml)
[![Release chart](https://github.com/Osshaikh/speechcontainer/actions/workflows/release.yml/badge.svg)](https://github.com/Osshaikh/speechcontainer/actions/workflows/release.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Artifact Hub](https://img.shields.io/badge/Artifact%20Hub-speech--container-417598)](https://artifacthub.io)

Helm chart for deploying **Azure AI Speech containers** (Speech-to-Text and Neural Text-to-Speech) on Kubernetes, with a tested path for **AKS behind Gateway API** (AKS app routing).

The containers run in **connected mode**: audio and text are processed inside your cluster, and usage is reported to your Azure AI Speech resource for billing. Disconnected (air-gapped) mode isn't supported by this chart; see the chart README, Appendix A. The chart uses standard Kubernetes APIs and also runs on EKS, GKE, OpenShift and vanilla Kubernetes.

---

## Quick start

```bash
HOST=speech.contoso.com
helm repo add speech-container https://osshaikh.github.io/speechcontainer/
helm repo update
helm pull speech-container/speech-container --version 1.4.4 --untar && cd speech-container

kubectl create namespace speech
kubectl create secret generic speech-credentials -n speech \
  --from-literal=billing="<your Speech resource endpoint>" \
  --from-literal=apikey="<your key>"

# Shared Gateway: public HTTPS (needs TLS Secret speech-tls) or examples/gateway-internal.yaml (private IP, HTTP)
sed "s/speech.contoso.com/$HOST/" examples/gateway-public.yaml | kubectl apply -n speech -f -

for rel in stt-hi stt-en tts-hi tts-en; do
  helm upgrade --install $rel speech-container/speech-container -n speech --version 1.4.4 \
    -f examples/$rel.yaml -f examples/values-gateway-route.yaml \
    --set secretRef.enabled=true --set gatewayApi.hostname=$HOST \
    --wait --timeout 20m
done
```

Step-by-step guide (prerequisites, TLS and DNS, Key Vault, tests through the Gateway, more languages, operations) → **[charts/speech-container/README.md](charts/speech-container/README.md)**.

Voice-workload capacity planning (per-pod throughput, sizing for a target call volume, reference table up to 5M calls/month) → **[Capacity planning](#capacity-planning)** further down this README.

## What's in this repo

```
speechcontainer/
├── charts/
│   └── speech-container/         # the Helm chart
│       ├── Chart.yaml
│       ├── values.yaml
│       ├── values.schema.json    # rejects unknown or mistyped values
│       ├── README.md             # full install + ops guide
│       ├── templates/
│       └── examples/             # STT/TTS values (en-US, hi-IN, ta-IN), route overlays, public + internal Gateway manifests
├── CHANGELOG.md
├── CONTRIBUTING.md
├── SECURITY.md
├── CODE_OF_CONDUCT.md
└── LICENSE                       # MIT
```

## Supported workloads

| Workload | Locales validated | Image |
|---|---|---|
| Speech-to-Text (STT) | en-US, hi-IN, ta-IN (any BCP-47 locale supported by MCR) | `mcr.microsoft.com/azure-cognitive-services/speechservices/speech-to-text` |
| Neural Text-to-Speech (TTS) | en-US (AvaNeural), hi-IN (SwaraNeural), ta-IN (PallaviNeural) — any voice from MCR works | `mcr.microsoft.com/azure-cognitive-services/speechservices/neural-text-to-speech` |

**Image references:**
- STT tags: https://mcr.microsoft.com/product/azure-cognitive-services/speechservices/speech-to-text/tags
- TTS tags: https://mcr.microsoft.com/product/azure-cognitive-services/speechservices/neural-text-to-speech/tags
- TTS voice gallery (preview): https://speech.microsoft.com/portal/voicegallery
- Microsoft Learn: https://learn.microsoft.com/azure/ai-services/speech-service/speech-container-howto

Want a different locale (Telugu, Marathi, Bengali, etc.)? See the **"Adding additional language containers"** section in the [chart README](charts/speech-container/README.md#adding-additional-language-containers).

## Platform compatibility

| Platform | Status | Notes |
|---|---|---|
| **Azure Kubernetes Service (AKS)** | ✅ Validated | Recommended platform; native integrations for Key Vault, ACR, Workload Identity |
| **Amazon EKS** | ✅ Compatible | Use IRSA + AWS Secrets Manager for credentials |
| **Google GKE** | ✅ Compatible | Use Workload Identity + GCP Secret Manager |
| **OpenShift** | ✅ Compatible | May need SCC adjustments for non-root pods |
| **Vanilla / kubeadm** | ✅ Compatible | Bring your own ingress + storage class |
| **kind / k3d / minikube** | ⚠️ Dev only | For testing; resource floors below production minimums |

## Prerequisites at a glance

1. **Azure AI Speech resource** (S0) with key authentication enabled: its endpoint is the billing URL
2. **Kubernetes cluster** ≥ 1.30 with four node pools — Hindi STT, other-language STT, Hindi TTS, other-language TTS (sized per the [Capacity planning](#capacity-planning) section below; fewer pools are supported via the chart's `nodePool` value)
3. **Network egress, permanently**, to the host of your billing URL (usage is reported every 10–15 minutes) and to `mcr.microsoft.com` / `*.data.mcr.microsoft.com` (or your ACR)
4. **On AKS:** Gateway API with app routing (`az aks update --enable-gateway-api --enable-app-routing-istio`), a hostname, a TLS certificate and a DNS record
5. **Helm** ≥ 3.10 and **kubectl** matching your cluster version

---

## Capacity planning

Use these throughput figures (validated by Microsoft Speech engineering, confirmed against in-field deployments) to size your cluster for a target call volume. The model is **platform-neutral** — applies whether you deploy on AKS, EKS, GKE, OpenShift, or vanilla Kubernetes.

### Per-container resource requirements

Microsoft Learn — container host sizing per pod:

| Workload | **Minimum** | **Recommended** | Notes |
|---|---|---|---|
| **STT** (Speech-to-Text) | **4 cores / 4 GB** | **8 cores / 8 GB** | + 4–8 GB headroom for speech model load at startup |
| **Neural TTS** | **6 cores / 12 GB** | **8 cores / 16 GB** | Larger voice models = more RAM; synthesis bursts at 16 GB |

The chart ships with **minimums** as the example request values; limits stay at the chart default `8c / 16Gi` so the container can burst to recommended sizing under load without rejection.

### Recommended node families

| Pool | Family | Sizing per node | Why | Density (chart-default requests) |
|---|---|---|---|---|
| **System** (`syspool`) | General purpose | 4 cores / 16 GB | Runs CoreDNS, ingress, addons | n/a |
| **STT Hindi** (`workload=stt-hi`) / **STT other** (`workload=stt-other`) | **Compute-optimized** | 16 cores / 32 GB | STT is CPU-bound | 2 pods/node (req 4c, limit 8c each; 3 fit by request but can't all burst) |
| **TTS Hindi** (`workload=tts-hi`) / **TTS other** (`workload=tts-other`) | **Memory-optimized** | 16 cores / 128 GB | Neural voices need RAM | 2 pods/node safe (req 6c / 12Gi each) — **1 node per 2 TTS pods** |

Hindi gets dedicated STT and TTS pools; every other language shares the "other" pool of its workload type.

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

| Monthly calls | Peak calls/hr (3×) | STT pods (req 4c/8Gi) | TTS pods (req 6c/12Gi) | Min STT nodes (total) | Min TTS nodes (total) |
|---|---|---|---|---|---|
| 10 k    | ~42   | 1 (+ 1 HA) | 1 (+ 1 HA) | 1 (compute-opt 16c)  | 1 (memory-opt 16c) |
| 100 k   | ~420  | 2          | 2          | 2 (compute-opt 16c)  | 2 (memory-opt 16c) |
| 500 k   | ~2,100| 2          | 4          | 2 (compute-opt 16c)  | 4 (memory-opt 16c) |
| 1 M     | ~4,200| 3          | 7          | 3 (compute-opt 16c)  | 7 (memory-opt 16c) |
| 5 M     | ~21 k | 11         | 35         | 11 (compute-opt 16c) | 35 (memory-opt 16c) |

> Node counts here are conservative: one pod per 16-core node. At the planning density above (2 pods per node), the same pods need about half as many nodes, but keep at least 2 nodes per pool.
> **Four-pool layout:** node totals are split between the Hindi and other-language pool of each workload type, according to your traffic mix. Each pool needs at least 1 node (2 for node-level HA), so the four-pool minimum is 2 STT + 2 TTS nodes even where the table shows 1. The chart spreads each release's replicas across nodes, but with one node per pool both replicas still share it, so plan 2 nodes per pool for production.
> Increase peak multiplier (× factor) if your traffic profile is spikier (e.g., 5× for retail flash events, 10× for emergency campaigns).

### Tunable assumptions in this model

| Variable | Default | Where to change |
|---|---|---|
| Average call duration | 30 s | Multiply formula by `(your_avg_seconds / 30)` |
| STT concurrency/core | 2 sessions | `concurrency.numberOfConcurrentRequest` (sets `DECODER_MAX_COUNT`, STT only) |
| TTS concurrency/8-core pod | 5 sessions | No container setting: cap concurrent requests in the client or gateway, and size replicas |
| Peak-to-average ratio | 3× | Depends on traffic shape (BFSI ≈ 2×, retail ≈ 3–5×) |
| HA replicas | +1 baseline | Maintain at least 2 pods per workload always |

---

## Contributing

Bug reports, feature requests, and PRs are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

MIT See [LICENSE](LICENSE).

## Acknowledgements

- Microsoft Azure AI Speech team for the Speech container images
- The Helm community for `chart-releaser-action`
