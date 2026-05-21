# Security Policy

## Reporting a vulnerability

If you discover a security issue in this Helm chart **please do not open a public GitHub issue.** Instead, contact the maintainer privately via GitHub:

1. Go to https://github.com/Osshaikh
2. Open a private vulnerability advisory via GitHub Security tab on the repo
3. Include reproduction steps, affected chart version, and impact assessment

You'll receive an acknowledgement within 7 business days, and an initial assessment within 14 days.

## Scope

This chart packages and deploys Microsoft-published container images. Security issues in scope:

- **In scope:** Helm template logic, default values, RBAC manifests, NetworkPolicy templates, secret handling, and documentation that could lead users to insecure configurations.
- **Out of scope:** Vulnerabilities in the underlying `mcr.microsoft.com/azure-cognitive-services/speechservices/*` images themselves — report those directly to Microsoft via [aka.ms/secure-at-microsoft](https://aka.ms/secure-at-microsoft) or [MSRC](https://msrc.microsoft.com).

## Supported versions

| Chart version | Supported |
|---|---|
| 1.1.x | ✅ Active — receives fixes |
| 1.0.x | ⚠️ Critical fixes only |
| < 1.0 | ❌ Unsupported |

## Hardening recommendations

When deploying this chart in production:

- **Never** put `args.apikey` inline in values committed to Git. Use `secretRef.enabled=true` and source the secret from an external vault (Azure Key Vault, AWS Secrets Manager, GCP Secret Manager, or HashiCorp Vault).
- Run pods as a non-root user (the chart respects `securityContext` overrides).
- Apply a `NetworkPolicy` that allows egress only to `<resource>.cognitiveservices.azure.com:443` and your ingress source.
- Use a private container registry (e.g. ACR mirror) for air-gapped clusters.
- Enable audit logging on your Kubernetes API server and Key Vault to track secret access.
