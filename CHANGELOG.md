# Changelog

All notable changes to the `speech-container` Helm chart are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
