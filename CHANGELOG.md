# Changelog

All notable changes to the `speech-container` Helm chart are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
