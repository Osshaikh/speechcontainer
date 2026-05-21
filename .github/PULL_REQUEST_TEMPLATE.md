<!-- Thanks for your PR! Please confirm the following before submitting. -->

## What does this PR do?



## Type of change

- [ ] Bug fix (non-breaking)
- [ ] New feature (non-breaking, adds capability)
- [ ] Breaking change (alters existing values schema or template behaviour)
- [ ] Documentation update

## Checklist

- [ ] `helm lint charts/speech-container` passes
- [ ] `helm template` renders for all four example values (stt-en, stt-hi, tts-en, tts-hi)
- [ ] Bumped `charts/speech-container/Chart.yaml` `version` per SemVer
- [ ] Updated `CHANGELOG.md`
- [ ] Updated `charts/speech-container/README.md` if user-facing surface changed
- [ ] Tested on at least one Kubernetes platform (note which in the description)
