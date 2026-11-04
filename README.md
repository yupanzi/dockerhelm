# dockerhelm

[![CI](https://github.com/yupanzi/dockerhelm/actions/workflows/ci.yml/badge.svg)](https://github.com/yupanzi/dockerhelm/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](./LICENSE)

Generic Docker → Kubernetes Helm Chart. A single values.yaml turns any Docker image into a **zero-downtime**, production-grade workload (Deployment or StatefulSet).

## Why

Teams repeatedly reinvent production-grade configuration for `Deployment | StatefulSet | Service | Ingress | HPA | PDB` when moving applications to Kubernetes. This chart turns those practices into **defaults**: provide an image and replica count to get zero-downtime rolling updates, a PDB, topology spreading, and graceful shutdown.

## Design Principles

1. **Prefer native Kubernetes names** — fields follow the Kubernetes API wherever possible, so anyone familiar with PodSpec can use them without consulting extra documentation.
2. **Production-ready defaults** — aggressive rolling updates, a PDB, topology spreading, and preStop draining work out of the box.
3. **Pass through common fields; gate uncommon features explicitly** — no magic or hidden behavior. Use the `pod.extraSpec` / `extraObjects` escape hatches for anything not modeled by the chart.

## Quick Start (OCI)

```bash
helm install web oci://ghcr.io/yupanzi/charts/dockerhelm \
  --set image.repository=ghcr.io/acme/myapp \
  --set image.tag=v1.2.3 \
  --set workload.replicas=4 \
  --set 'container.ports[0].name=http' \
  --set 'container.ports[0].containerPort=8080' \
  --set service.enabled=true \
  --set ingress.enabled=true \
  --set ingress.hostname=myapp.example.com
```

The `http` port declared in `container.ports` is the named port referenced by the Service's default `targetPort`. If it is missing, Helm fails during installation instead of leaving you with a 503 after deployment.

Zero-downtime features (rolling updates / PDB / topology spread / preStop) are enabled by default and require no additional configuration.
The preStop drain uses the native `sleep` action, so images without a shell (distroless) work too; on Kubernetes < 1.30 the chart falls back to `exec: sleep`.
To install from local source, replace `oci://...` with the chart directory path.

`image.repository` is the only required field. The chart does not provide a default image; it deploys your project's own image. An empty `image.tag` falls back to `latest` (pin a version or use `image.digest` in production).

## Common Use Cases

| Use case | Key configuration |
| -------- | ----------------- |
| Stateless web service | The default; enable `service.enabled` + `ingress.enabled` |
| Stateful service (database/queue) | `workload.kind: StatefulSet` + `persistence.enabled` (automatically creates the governing headless Service) |
| Sidecar / init container | `extraContainers` / `initContainers` (raw pass-through) |
| Migrations / scheduled tasks (same image, other entrypoint) | `jobs` (Helm hooks, e.g. `pre-install,pre-upgrade`) / `cronJobs`; env is per entry, not inherited |
| Autoscaling | `autoscaling.enabled: true` (use `minReplicas >= 2` for zero-downtime protection) |
| AWS ALB integration | `ingress.className: alb` + `ingress.alb.autoConfigure: true` |
| TCP service behind a cloud load balancer (e.g. AWS NLB) | `service.type: LoadBalancer` + `service.loadBalancerClass` + `service.loadBalancerSourceRanges` |
| Arbitrary resources (NetworkPolicy, etc.) | `extraObjects` (rendered through `tpl`) |

See [`examples/`](./examples/) for complete examples.

## Security Notes

- Containers enable `allowPrivilegeEscalation: false` + `seccompProfile: RuntimeDefault` by default. Enable stricter PSS restricted settings (such as `runAsNonRoot`) in `container.securityContext` when the image supports them.
- The ServiceAccount does **not** mount an API token by default (`serviceAccount.automount: false`). Enable it explicitly if the application needs to access the Kubernetes API.
- **Do not store production secrets in values.** They will be stored in Git and the Helm release (`helm get values` exposes them in plaintext). Manage them with external-secrets / sealed-secrets and reference them from values (for example, `container.envFrom.secretRef`).

## Documentation Index

| I want to find... | See |
| ----------------- | --- |
| What a field does | [`values.yaml`](./values.yaml) (fully commented) |
| Field formats and allowed values | [`values.schema.json`](./values.schema.json) (enforced validation) |
| How to configure a complete use case | [`examples/`](./examples/) — sidecar / stateful / loadbalancer / comprehensive |
| Internal conventions for modifying this chart | [`CLAUDE.md`](./CLAUDE.md) (for maintainers) |

`values.schema.json` rejects invalid fields and values during `helm install`, before they reach the cluster. Invalid combinations (such as `ingress.enabled` without a Service) fail fast at the template layer.

## Local Validation

```bash
# image.repository is required because the chart has no default image; use any image for validation
helm lint . --set image.repository=ghcr.io/acme/demo
helm template test . --set image.repository=ghcr.io/acme/demo \
  | kubectl apply --dry-run=server -f -   # Requires a test cluster (kind/k3d)
```

CI renders all examples, validates them with kubeconform, and performs a server-side dry run against a kind cluster (lint runs against the chart itself).

## Release Process (Maintainers)

Releases are fully automated with semantic-release. Conventional Commits merged to `master` determine the next version (`fix:` = patch, `feat:` = minor, `feat!:` / `BREAKING CHANGE:` = major); the workflow bumps `Chart.yaml`, updates `CHANGELOG.md`, tags `v<version>`, pushes the chart to `oci://ghcr.io/yupanzi/charts/dockerhelm`, and creates a GitHub Release. See [`CLAUDE.md`](./CLAUDE.md) for the manual fallback.

## License

[MIT](./LICENSE)
