# Changelog

All notable changes to the `speech-container` Helm chart are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.2.3] - 2026

### Changed — Documentation reorganization
- **Moved "Capacity planning" section from chart README to repo root README.** The full model (per-container resource requirements, recommended node families, per-pod throughput, sizing for a target call volume, reference sizing table up to 5M calls/month, tunable assumptions) now lives in the root `README.md` as a top-level section. The chart README retains a short pointer back to it. Rationale: capacity planning is platform-neutral and one of the first things a customer/architect evaluating the chart needs — surfacing it at the repo root makes it visible to anyone landing on the GitHub project page without having to open the chart subfolder.
- **Removed Section B (Client-side SDK egress) from §2 "Network / firewall whitelisting".** The section was niche (only relevant if callers use the Speech SDK rather than raw REST) and the SDK-issued-token flow is documented thoroughly by Microsoft Learn upstream. Removing it keeps §2 focused on the mandatory container-pod egress that 100% of deployments need. The §2 anchor and TOC entry are unchanged so external links don't break.
- **Removed "two categories" preamble and "A) Container pod egress (mandatory)" subheading** from §2 since there is now only one category. Section content (FQDN table, concrete example, minimum firewall rule set, ACR mirroring callout, Azure Firewall/NSG Service Tag callout) is preserved verbatim.

### Why
Both reorganizations are part of polishing the repo for client-facing review — making the high-value sizing model discoverable at the repo root, and trimming the firewall section to only the rules every deployment actually needs.

## [1.2.2] - 2026

### Fixed — AGC §5b TLS Secret prerequisite was missing
- **Added step 6: "Create the TLS Secret that the HTTPS listener will reference"** before the Gateway creation step. The prior README referenced `certificateRefs.name: speech-tls` in the Gateway listener but never told the reader how to create that Secret, so the Gateway would silently sit at `PROGRAMMED=False` with an `InvalidCertificateRef` reason.
- **Three TLS options documented** so users can pick by environment:
  - **Option A (dev/test)** — `openssl` self-signed cert + `kubectl create secret tls` one-liner.
  - **Option B (production)** — cert-manager `Certificate` resource using a `ClusterIssuer` (Let's Encrypt or other ACME), with automatic rotation.
  - **Option C (production, Azure-native)** — Azure Key Vault cert projected via the Secrets Store CSI driver, syncing into a `kubernetes.io/tls` Secret.
- **Added TLS prerequisite reminder callout** below the Gateway block clarifying the smoke-test fallback (switch to HTTP listener, add HTTPS later as a Secret + listener change with no chart edit needed) and the DNS/SNI hostname matching requirement.
- **Renumbered subsequent step** from 6 → 7 (Gateway creation now follows TLS Secret creation).

### Why
A peer following §5b end-to-end hit `PROGRAMMED=False` on the Gateway because the `speech-tls` Secret reference had no creation instructions anywhere in the README. The fix makes §5b genuinely production-grade by spelling out cert lifecycle ownership (manual, cert-manager, or Key Vault) explicitly.

## [1.2.1] - 2026

### Fixed — AGC §5b aligned with official Microsoft Quickstart
- **Removed misleading `kubectl apply ... gateway-api/standard-install.yaml` step** from §5b "One-time cluster setup". The Microsoft `alb-controller` Helm chart bundles the Gateway API Standard channel CRDs and applies them as part of `helm install`. A separate CRD install is only required for non-AGC Gateway API implementations (Istio, Envoy Gateway, Cilium, NGINX Gateway Fabric).
- **Added the missing managed identity + federated credential setup** that the official Microsoft Quickstart requires (resource provider registration, `az extension add --name alb`, `az identity create`, Reader role on the node resource group, federated credential bound to `system:serviceaccount:azure-alb-system:alb-controller-sa`).
- **Bumped ALB Controller chart version reference** from `1.0.0` to `1.10.28` (current at time of release) with a note pointing to MCR tags for users to check the latest.
- **Added `--set albController.namespace=$CONTROLLER_NAMESPACE`** to the helm install command, matching the official documentation pattern.
- **Added an explanatory callout** clarifying *why* the Gateway API CRDs don't need a separate install step on AGC.

### Why
A peer noticed the Microsoft official quickstart doesn't include the standalone Gateway API CRD install step, and asked why our README did. The step was a leftover from a generic Gateway API install pattern and was wrong specifically for AGC on AKS — the chart itself ships the CRDs.

## [1.2.0] - 2026

### Added — Gateway API support (Application Gateway for Containers on AKS)
- **New routing mode: Gateway API `HTTPRoute`** via the `gatewayApi.*` value block in `values.yaml`. Mutually exclusive with the legacy `ingress.enabled=true` (chart fails fast at template time if both are enabled, with a clear error message).
- **New template `templates/httproute.yaml`** — renders a Gateway API v1 `HTTPRoute` attached to a pre-existing parent Gateway, with:
  - `PathPrefix` match on `gatewayApi.path` (same per-release semantics as `ingress.path`)
  - `URLRewrite` filter (`ReplacePrefixMatch: /`) to strip the language prefix before forwarding — equivalent to nginx's `rewrite-target: /$2`
  - `timeouts.request` / `timeouts.backendRequest` for long-running STT streaming sessions (Gateway API v1.1+)
  - Backend ref to the chart's existing Service on its existing port
- **New example overlay `examples/agc-overrides.yaml`** — drop-in file that flips `ingress.enabled=false` and `gatewayApi.enabled=true`. Layer on top of any `stt-*.yaml` / `tts-*.yaml` example to deploy the same language container via AGC instead of nginx.

### Added — README §5 rewritten as "Ingress controller (or Gateway API)"
- Now presents both options side-by-side with a status table (nginx is "maintenance mode" / AGC is "recommended for AKS").
- **§5a NGINX Ingress** — existing install path, unchanged.
- **§5b Application Gateway for Containers (AGC) on AKS** — new section covering:
  - Why migrate (ingress-nginx EOL, Gateway API direction)
  - 5-step one-time cluster setup: Gateway API CRDs, register `Microsoft.ServiceNetworking` provider, install ALB Controller from MCR Helm registry, create `ApplicationLoadBalancer` CR, create parent `Gateway` resource with HTTPS listener
  - Per-release install commands using `-f examples/agc-overrides.yaml`
  - Verification (`kubectl get httproute`, curl through AGC frontend)
  - **Feature parity table** showing how each nginx capability (path rewrite, timeouts, body size, WebSocket, TLS, hostname multiplexing) maps to the HTTPRoute / Gateway model
  - Migration tip: run both controllers in parallel during cutover

### Why this matters
- `ingress-nginx` was placed in maintenance mode by the Kubernetes community and will be sunset. On AKS, Microsoft's strategic replacement is Application Gateway for Containers (AGC), which speaks Gateway API natively. This release lets the chart serve both worlds without forking: existing nginx users keep working unchanged; new AKS deployments can adopt AGC by adding a single `-f agc-overrides.yaml` overlay.

## [1.1.10] - 2026

### Changed
- **§"Network / firewall whitelisting" rewritten and expanded** (Prerequisite #2). Previous table was too thin to be actionable for security/network teams. New version splits egress into two clear categories:
  - **A) Container pod egress** (mandatory) — now includes the regional Cognitive Services endpoint (`<region>.api.cognitive.microsoft.com`) alongside the resource endpoint (`<resource>.cognitiveservices.azure.com`), with explicit protocol/port columns, expanded "When required" cadence text (10–15 min for connected mode telemetry, every 7+ days for disconnected commitment renewal), and a worked example showing exactly which two FQDNs to whitelist for a sample resource.
  - **B) Client-side egress** (only if callers use the Speech SDK) — documents the regional and resource-scoped `/sts/v1.0/issueToken` endpoints the SDK calls before hitting the container. Explicitly notes that raw REST/curl callers do not need this.
- Added a "Concrete example" callout showing the exact two URLs (resource endpoint + regional endpoint) for a sample `myspeechres` / `centralindia` deployment, and pointing users to the Azure portal "Keys and Endpoint" blade as the source of truth for the resource URL.
- Added an Azure Firewall / NSG guidance callout recommending **FQDN application rules** or the `CognitiveServicesManagement` Service Tag instead of brittle IP-based allowlists (Cognitive Services FQDNs sit behind Front Door, so IPs rotate).
- Updated ACR mirror example to use 5.4.0 (current STT line) instead of stale 5.3.0.

## [1.1.9] - 2026

### Fixed (blocking for Telugu STT and any future per-locale STT drift)
- **README Example 14 bulk install: Telugu STT tag corrected** `5.3.0-amd64-te-in` → `5.4.0-amd64-te-in`. The 5.3.0 tag does not exist on MCR — `te-IN` STT jumped straight from `3.10.0` to `5.4.0`. Following Example 14 verbatim caused guaranteed `ImagePullBackOff` for Telugu STT (peer-reported and verified live on `iitbombay-aks`).
- **All STT tags in Example 14 verified against MCR Registry v2 API** and pinned to actual published versions: en/hi/te use `5.4.0`; ta/mr/bn/gu use `5.3.0`.

### Added
- **New STT version-drift warning callout** in §"Adding additional language containers" — parallel to the existing TTS callout. Documents the actual STT-version-per-locale table (5.4.0 vs 5.3.0 vs preview-only) and reminds users that STT versions are **not synchronized**. Explicitly calls out the Telugu trap (no 5.3.0-te-in tag).
- Example 14 STT block now includes inline comments pointing back to the Tag lookup helper and noting which locales sit on which version line.

### Changed
- Header comment in Example 14 reworded from "STT line is 5.3.0 for all locales" → "STT versions are NOT synchronized across locales; always re-check with the Tag lookup helper before running".
- TTS comment clarified: "4.7.0 is the universal current line for every locale Microsoft publishes" — i.e., TTS and STT have different version-synchronization behaviors.
- Example 14 TTS block extended to include `bn-IN` (`4.7.0-amd64-bn-in-tanishaaneural`) so the example demonstrates the same locale set across both workloads.

### Fixed (cosmetic)
- **Quickstart `/ready` curl comment** now shows actual JSON payload (was `→ "OK"`). Brings Quickstart in sync with the Verifying section already fixed in 1.1.7.
- **TTS `/ready` JSON example** corrected: `"service":"texttospeech"` → `"service":"neuraltexttospeechonprem"` (matches the actual container response field; observed via live curl on chart 1.1.8 deployment).

## [1.1.8] - 2026

### Fixed (blocking for multi-language adopters)
- **All TTS examples and references standardized on `4.7.0`** (previously a mix of `4.6.0` and `4.7.0`). Validated against MCR: locales `ta-IN`, `mr-IN`, `te-IN`, `bn-IN`, `gu-IN`, `kn-IN`, `ml-IN`, `pa-IN`, `ur-IN` are published **only on the 4.7.0 line** — there is no `4.6.0` tag for them. The `4.7.0` line also covers all en-US and hi-IN voices, so it's now the safe universal default. Following the previous `4.6.0` pattern caused guaranteed `ImagePullBackOff` for any non-English/Hindi locale (peer-reported failure for Marathi `mr-IN` and Tamil `ta-IN`).
- `examples/tts-en.yaml`: `4.6.0-amd64-en-us-avaneural` → `4.7.0-amd64-en-us-avaneural`.
- `examples/tts-hi.yaml`: `4.6.0-amd64-hi-in-swaraneural` → `4.7.0-amd64-hi-in-swaraneural`.
- `values.yaml` example comments updated to 4.7.0 with a note that new locales ship only on 4.7.0.

### Added
- **Tag lookup helper** in §"Adding additional language containers" — curl + jq snippet against the MCR v2 registry API to list every published tag for a locale before installing. More reliable than `docker pull` and catches typos before `ImagePullBackOff`.
- **TTS version-stream warning callout** at the top of the image naming pattern section, explicitly listing which locales require 4.7.0 and warning against copying the legacy 4.6.0 pattern for new languages.
- **Multi-language capacity callout** under Example 14 bulk-install — explains that each language = one extra pod, and that with chart defaults only 2 TTS pods fit per 16-core node. Rule of thumb: `ceil(num_TTS_languages / 2)` ttspool nodes. Explains why pods stay `Pending` instead of escaping to other pools (taint `workload=tts:NoSchedule` blocks fallback by design).
- **Example 14 (bulk install) extended** with a parallel TTS loop covering en/hi/ta/te/mr on 4.7.0, demonstrating the universal TTS line in practice.

### Changed
- Header banner reworded: `5.3.0 (STT) / 4.6.0+ (TTS — varies)` → `5.3.0 (STT) / 4.7.0 (TTS — current; some legacy en-US/hi-IN voices also on 4.6.0)` with explicit list of locales that require 4.7.0.
- Default-values reference: `4.6.0-amd64-en-us-avaneural` → `4.7.0-amd64-en-us-avaneural` (matches the updated example file).
- Capacity-planning ttspool row now explicitly states "1 node per 2 language containers" so the multi-language sizing math is visible without scrolling to the troubleshooting section.
- `appVersion` note clarifies TTS line is now 4.7.0 (legacy 4.6.0 still exists for some en/hi voices).

## [1.1.7] - 2026

### Fixed (blocking)
- `examples/tts-ta.yaml` image tag corrected from non-existent `4.6.0-amd64-ta-in-pallavineural` to actual MCR-published `4.7.0-amd64-ta-in-pallavineural` (Tamil TTS is on a newer version stream than en-US/hi-IN). The previous tag caused `ImagePullBackOff` for any client following the README literally.
- All four en/hi example values files now use `host: speech.example.com` (previously `speech.bfl.internal`, a leftover from an internal customer engagement). Now consistent with Tamil examples and README narrative.
- README Example 12 (Tamil TTS) and "Image naming pattern" table updated to reference the correct `4.7.0` tag.

### Fixed (doc consistency)
- README header now reflects current chart version (was stuck at 1.1.4).
- Clarified Prerequisite #1 — same chart works for both **Connected mode** (S0 key, no commitment plan) and **Disconnected mode** (S0 + commitment tier). Previous wording incorrectly implied commitment is always required.
- `helm pull` walkthrough now lists all 7 example files (added `stt-ta.yaml`, `tts-ta.yaml`).
- "Verifying" section: `/ready` responses now show actual JSON payload (`{"service":"...","ready":"ready","message":"Api Key is valid, no action needed."}`) instead of the misleading `"OK"`.
- "Upgrading" section: `helm repo update osshaikh` → `helm repo update speech-container` (matches the repo alias used in the install instructions).
- Troubleshooting cross-reference to Network section: anchor `#4-network--firewall-whitelisting` → `#2-network--firewall-whitelisting` (was broken).
- TOC entry "Azure Key Vault integration (AKS)" now anchors to the actual `<details>` block inside the secret section, not the duplicate `#4-speech-credentials-secret` anchor.
- README "Required versions" now explicitly states Helm 4.x is also tested and supported (previous floor of 3.10 only).

## [1.1.6] - 2026

### Added
- "Image & documentation references" subsection in the chart README — direct links to MCR tag pages for STT and TTS, Microsoft Learn how-to, language-support catalog, TTS voice gallery, and disconnected containers commitment tier docs.
- Repo front-page README now includes the same key image links inline under "Supported workloads".

### Changed
- Repo README workload table: Tamil added to validated locales (matches new `examples/*-ta.yaml`); TTS voice example updated from JennyNeural to AvaNeural to match the actual default in `examples/tts-en.yaml`.

## [1.1.5] - 2026

### Added
- `examples/stt-ta.yaml` and `examples/tts-ta.yaml` — ready-to-use Tamil STT and Tamil TTS (PallaviNeural) values, with the same toleration / affinity / resource pattern as the en-US and hi-IN examples.
- TTS synthesis verification step in the README's "Verifying the install" section (curl POST with SSML payload to `/cognitiveservices/v1`).
- README note clarifying that `appVersion` tracks the STT image line; TTS has an independent version stream.

### Changed
- Examples 11 (Tamil STT) and 12 (Tamil TTS) in the README — dropped the redundant `--set image.repository=...` override. The chart's `_helpers.tpl` auto-derives the repository from `mode`, so only `image.tag` needs overriding. Now consistent with Example 13.

## [1.1.4] - 2026

### Changed
- STT example values now request `cpu: 4, memory: 4Gi` by default (Microsoft Learn minimum for STT).
- TTS example values now request `cpu: 6, memory: 12Gi` by default (Microsoft Learn minimum for TTS).
- Limits inherit chart default (`cpu: 8, memory: 16Gi`) — only requests changed.
- Example concurrency knobs aligned to CPU requests (STT=4, TTS=6).

### Notes
- Chart-level defaults in `values.yaml` remain at `8c / 8Gi` request, `8c / 16Gi` limit (unchanged).

## [1.1.3] - 2026

### Added
- Soft `nodeAffinity` (weight 100) baked into all four example values files so pods *prefer* matching workload pool but fall back gracefully.

## [1.1.2] - 2026

### Added
- Optional `secretRef.enabled` mode — sources `billing` and `apikey` from a Kubernetes Secret instead of inline `args`.

## [1.1.1] - 2026

### Changed
- Unified STT and TTS deployment template into a single chart (was two charts in 1.0.x).

## [1.1.0] - 2026

### Added
- `Ingress` template (per-release host-based routing).
- `HorizontalPodAutoscaler` template.
- `PodDisruptionBudget` template.
- `tolerations` value for split-pool scheduling.

## [1.0.2] - 2026

### Fixed
- `args.apikey` validation — fail-fast at lint time when neither inline key nor `secretRef` is set.

## [1.0.0] - 2026

### Added
- Initial chart release: STT + TTS containers via Deployment + Service.
- Microsoft Container Registry (MCR) image references for `speech-to-text` and `neural-text-to-speech`.

[1.1.4]: https://github.com/Osshaikh/speechcontainer/releases/tag/v1.1.4
