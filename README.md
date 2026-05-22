# speech-container

[![Lint chart](https://github.com/Osshaikh/speechcontainer/actions/workflows/lint.yml/badge.svg)](https://github.com/Osshaikh/speechcontainer/actions/workflows/lint.yml)
[![Release chart](https://github.com/Osshaikh/speechcontainer/actions/workflows/release.yml/badge.svg)](https://github.com/Osshaikh/speechcontainer/actions/workflows/release.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Artifact Hub](https://img.shields.io/badge/Artifact%20Hub-speech--container-417598)](https://artifacthub.io)

Helm chart for deploying **Azure AI Speech disconnected containers** (Speech-to-Text and Neural Text-to-Speech) on any Kubernetes platform.

This chart works on **AKS, EKS, GKE, OpenShift, and vanilla Kubernetes**. Azure-specific integrations (Key Vault, ACR, Workload Identity) are clearly marked as **AKS callouts** in the documentation — the core deployment flow stays platform-neutral.

---

## Quick start

```bash
helm repo add speech-container https://osshaikh.github.io/speechcontainer
helm repo update

kubectl create namespace speech
kubectl create secret generic speech-credentials -n speech \
  --from-literal=billing="https://<your-resource>.cognitiveservices.azure.com/" \
  --from-literal=apikey="<your-key>"

helm install stt-en speech-container/speech-container -n speech \
  -f https://raw.githubusercontent.com/Osshaikh/speechcontainer/main/charts/speech-container/examples/stt-en.yaml \
  --set secretRef.enabled=true \
  --set secretRef.name=speech-credentials
```

Full installation guide, prerequisites (cluster sizing, network whitelisting, node pools), capacity planning for voice workloads, and `helm install` examples → **[charts/speech-container/README.md](charts/speech-container/README.md)**.

## What's in this repo

```
speechcontainer/
├── charts/
│   └── speech-container/         # the Helm chart
│       ├── Chart.yaml
│       ├── values.yaml
│       ├── README.md             # full install + ops guide
│       ├── templates/
│       └── examples/             # ready-to-use values for STT/TTS en-US, hi-IN
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

1. **Azure AI Speech resource** with disconnected commitment tier (S0 SKU + Commitment Tiers blade)
2. **Kubernetes cluster** ≥ 1.27 with two node pools (sized per the [Capacity Planning](charts/speech-container/README.md#capacity-planning) section)
3. **Network egress** to `mcr.microsoft.com` and `<your-resource>.cognitiveservices.azure.com`
4. **Helm** ≥ 3.10 and **kubectl** matching your cluster version

> 💡 **AKS users:** A dedicated "Running on AKS" walkthrough is embedded in the chart README — Azure CLI commands for nodepools, taints, ACR mirroring, and Key Vault integration are all included.

## Contributing

Bug reports, feature requests, and PRs are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

MIT See [LICENSE](LICENSE).

## Acknowledgements

- Microsoft Azure AI Speech team for the disconnected container images
- The Helm community for `chart-releaser-action`
