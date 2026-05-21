# Contributing to `speech-container`

Thanks for your interest! This chart aims to be a community-friendly, platform-neutral way to deploy Azure AI Speech (STT and TTS) disconnected containers on any Kubernetes platform.

## Ways to contribute

- **Bug reports** — open an issue with reproduction steps, chart version, K8s flavour (AKS / EKS / GKE / kind / etc.), and `helm get values <release>` output.
- **Feature requests** — open an issue describing the use case before sending a PR.
- **Pull requests** — small, focused changes are easiest to review. One concern per PR.

## Local development

```bash
git clone https://github.com/Osshaikh/speechcontainer.git
cd speechcontainer

# Lint the chart
helm lint charts/speech-container

# Render the templates (dry-run)
helm template test charts/speech-container \
  -f charts/speech-container/examples/stt-en.yaml \
  --set secretRef.enabled=true \
  --set secretRef.name=test-secret

# Install to a real cluster (e.g. kind)
kind create cluster --name speech-dev
helm install stt-en charts/speech-container -n speech --create-namespace \
  -f charts/speech-container/examples/stt-en.yaml \
  --set secretRef.enabled=true --set secretRef.name=speech-credentials
```

## PR checklist

- [ ] `helm lint charts/speech-container` passes
- [ ] `helm template` renders without error for all four example values files
- [ ] If templates changed, ran a manual install on at least one K8s flavour
- [ ] Bumped `Chart.yaml` `version` per SemVer (patch for bug fix, minor for new feature, major for breaking change)
- [ ] Updated `CHANGELOG.md` under the new version heading
- [ ] Updated the chart's `README.md` if the user-facing surface changed (values, install flags)

## Versioning

This chart follows [SemVer](https://semver.org):
- **MAJOR** — breaking change to values schema or behaviour
- **MINOR** — new optional values / new templates with safe defaults
- **PATCH** — bug fixes, docs, or non-behavioural template tweaks

## Release process (maintainers)

1. Update `charts/speech-container/Chart.yaml` `version` field
2. Update `CHANGELOG.md` with the new version section
3. Open PR; once merged, tag `git tag v1.x.y && git push --tags`
4. GitHub Actions (`release.yml`) auto-publishes the packaged chart to `gh-pages`

## Code of conduct

By participating you agree to abide by the [Code of Conduct](./CODE_OF_CONDUCT.md).
