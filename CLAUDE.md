# CLAUDE.md — Maintainer and AI Collaboration Guide

This file is for people and AI agents modifying the chart; it is not user documentation. User documentation lives in `README.md` and the comments in `values.yaml`.

## What This Repository Is

An open-source, generic Helm chart (`oci://ghcr.io/yupanzi/charts/dockerhelm`, MIT) that turns any Docker image into a production-grade Kubernetes workload. It is **intended for public users**: defaults must work out of the box on any cluster and must not contain organization-specific values (certificate ARNs, internal registries/domains, internal StorageClasses — placeholders only, e.g. `arn:aws:...:123456789012:...`).

## Core Mental Model

- **`workload.kind` is the top-level router**: it determines whether `deployment.yaml` or `statefulset.yaml` is rendered. The schema restricts it to an enum, so both can never be deployed at once.
- **Production-ready by default**: all zero-downtime features (PDB / topologySpread / podAntiAffinity / preStop / rolling 0 unavailable) are enabled by default and require an explicit `enabled: false` to disable.
- **Raw pass-through using native Kubernetes fields**: most fields are passed directly to the Kubernetes API with `toYaml`; do not invent new wrapper field names.
- **Fail fast on invalid configuration**: invalid combinations (Ingress without a Service, HPA without metrics, Ingress without a hostname) use template-level `fail` instead of silently producing broken manifests.
- **Escape hatches**: unmodeled podSpec fields go through `pod.extraSpec`, and arbitrary additional resources go through `extraObjects` (both rendered with `tpl`). A strict schema without escape hatches forces users to fork; do not remove these two mechanisms.

## File Responsibilities

```
templates/
├── _helpers.tpl           # Naming / labels / annotations / pullSecrets / affinity / pdbWillCreate / headlessServiceName / lifecycle
├── _podSpec.tpl           # Shared spec.template.spec fragment (Deployment / StatefulSet)
├── _container.tpl         # Container definition shared by the main and job containers (passes fields through; env/envFrom use tpl)
├── _job.tpl               # Job name / labels / metadata / pod template shared by jobs.yaml / cronjobs.yaml
├── jobs.yaml / cronjobs.yaml  # jobs.<key> (always Helm hooks) / cronJobs.<key>, same image as the main workload
├── deployment.yaml        # workload.kind == Deployment
├── statefulset.yaml       # workload.kind == StatefulSet (includes volumeClaimTemplates)
├── headless-service.yaml  # Governing headless Service for StatefulSet (always created)
├── extra-objects.yaml     # extraObjects escape hatch (rendered with tpl)
├── service.yaml / ingress.yaml / hpa.yaml / pdb.yaml / configmap.yaml / secret.yaml / serviceaccount.yaml / pvc.yaml
└── NOTES.txt              # Status summary after helm install
values.schema.json         # Rejects invalid fields during Helm validation
examples/                  # Use-case values examples (sidecar / stateful / loadbalancer / comprehensive)
.releaserc.json            # semantic-release plugins: version bump / changelog / OCI push / GitHub Release
package.json + lockfile    # Exact-pinned release toolchain (npm ci in the workflow; not part of the chart)
.github/workflows/         # ci.yml (lint+render+kubeconform+kind dry-run) / semantic-release.yml (auto release on master) / release.yml (manual-tag fallback)
```

## Critical Invariants (Preserve When Making Changes)

1. **PDB creation is controlled exclusively by the `dockerhelm.pdbWillCreate` helper**
   It is shared by `pdb.yaml` and `NOTES.txt`. Change thresholds only in the helper; **do not inline the condition separately in both files**. HPA deliberately uses minReplicas (conservative) rather than maxReplicas to prevent a drain deadlock after scale-down.

2. **`_podSpec.tpl` is shared by Deployment and StatefulSet**
   Changes to podSpec defaults should benefit both. StatefulSet differences belong only in the outer resource (`volumeClaimTemplates` / `serviceName` / strategy field name).

3. **Automatically created volume naming convention**
   `configMap.create=true` → volume name `config`; `secret.create=true` → `secret`; `persistence` → `.Values.persistence.name` (default `data`).
   A user's `container.volumeMounts` must use these names to mount the volumes. **Do not change these three names casually.**

4. **`dockerhelm.imagePullSecrets` returns a complete YAML block**
   It does not return a list. Callers use the `{{- $ips := include ... | trim -}}` + `{{ if $ips }}` pattern to handle whitespace. Registry matching is an **exact host-segment match** (to prevent look-alike domains and duplicate blocks); do not change it back to prefix matching.

5. **Render the type and rollingUpdate of `strategy` / `updateStrategy` separately**
   Helm's deep merge leaves the default `rollingUpdate` in place when a user changes `type` to `Recreate|OnDelete`; the API server rejects that combination. Do not remove the template guard that renders the child block only for RollingUpdate. CI has regression coverage for this.

6. **StatefulSet `serviceName` and the headless Service name share one source**
   Both come from the `dockerhelm.headlessServiceName` helper, ensuring that the governing Service always exists and the reference always matches.

7. **Checksum annotations hash only user data**
   `dockerhelm.podAnnotations` applies sha256 to `configMap.data` / `secret.data+stringData` (after `tpl`), **not** to the entire manifest. Otherwise a chart version bump would roll every pod.

8. **The schema must allow `global`**
   This Helm-reserved key is injected by a parent chart when used as a subchart. Omitting it while top-level `additionalProperties: false` is set breaks every umbrella-chart use case.

9. **Sprig `merge` mutates its first argument**
   Whenever merging a map from `.Values`, the first argument must be a `deepCopy` (see `dockerhelm.annotations` / `podAnnotations` / Ingress annotations).

10. **Job pods never carry `app.kubernetes.io/name`**
   The main Service / PDB / anti-affinity / topology spread select on name+instance; a leaked label routes Service traffic to a running migration pod. `dockerhelm.jobPodTemplate` `omit`s it even when commonLabels / pod.labels set it; CI has a regression check. Job pods therefore do not reuse `_podSpec.tpl` (it carries selector-based affinity); they share `dockerhelm.container` and `dockerhelm.serviceAccountFields` instead.

11. **Every `jobs.<key>` is a Helm hook, and hook Jobs never reference the chart-created ServiceAccount**
   A plain Job's pod template is immutable (the next upgrade that changes the image fails), so the template `fail`s without `helm.sh/hook`. pre-install hooks run before any release resource exists, so a reference to the chart-created ServiceAccount would leave the Job without pods until the hook times out (`dockerhelm.serviceAccountFields` decides this from the hook annotation). Job entries never inherit `container.env` (least privilege; Helm cannot merge lists).

12. **Container lifecycle goes through the `dockerhelm.lifecycle` helper**
   Kubernetes allows one handler per hook, while Helm deep-merges user handlers next to the default `preStop.sleep`. The helper drops that residual sleep when another preStop handler is present, fails when the user set two handlers on one hook, removes null handler keys (Helm keeps a user `null` when the default has no such key), and renders `exec: sleep N` on Kubernetes < 1.30 where the native sleep action is not on by default. Do not render `container.lifecycle` with a bare `toYaml`; CI has regression coverage.

## Change Checklist

| Change | Also check |
| ------ | ---------- |
| Add a values.yaml field | Add a schema constraint + demonstrate it once in the relevant example |
| Delete/rename a field | Mark the commit `feat!:` / `BREAKING CHANGE:` (semantic-release majors the version) + explain it in README (the schema rejects old fields) |
| Change a default | Keep README/values comments in sync; document upgrade-impacting behavior in release notes |
| Add a condition used across templates | Extract it into a helper (following `dockerhelm.pdbWillCreate`); do not inline it in multiple places |
| Modify `_podSpec.tpl` / `_container.tpl` | Validate both the Deployment and StatefulSet paths; `_container.tpl` also renders job containers, and a pod-level security or scheduling default probably belongs in `_job.tpl` too |
| Use a newer Kubernetes field | Check `kubeVersion` (>=1.25) and gate with `.Capabilities.KubeVersion` when needed (see pdb.yaml) |

## Known Pitfalls

- **Both branches of Go template `ternary` are evaluated** — it cannot short-circuit; do not write `ternary (riskyOp) safe cond`.
- **`include "..."` returns a string**, and an empty string is falsy. Helm has no true boolean output; `pdbWillCreate` uses an empty string / `"true"` to simulate one.
- **Helm validates values after deep-merging them with defaults** — schema `required` never takes effect for fields that have defaults; template-level `fail` guards prevent invalid configurations.
- **`persistence.existingClaim` also uses a volume mount in StatefulSet** (not volumeClaimTemplates) — this is implicit behavior for shared-volume use cases.
- **Fields rendered with tpl (env / configMap.data / secret.stringData / extraObjects)**: `{{` in user data is evaluated, as documented. When adding another tpl-rendered field, update the checksum calculation too (invariant 7).
- **Check PDB minAvailable/maxUnavailable for nil/empty string rather than truthiness** — `0` is a valid value (it freezes evictions).

## Validation (Also Run by CI)

```bash
# image.repository is required (the chart has no default image); provide a demo image for validation
# Write flags out in full instead of putting them in a string variable; zsh does not split unquoted variables
helm lint . --set image.repository=ghcr.io/acme/demo
helm template test . --set image.repository=ghcr.io/acme/demo > /dev/null
helm template test . -f examples/values-stateful.yaml > /dev/null
helm template test . -f examples/values-comprehensive.yaml > /dev/null
# With a kind/k3d cluster (catches API-server rejections that client validation cannot):
helm template test . -f examples/values-comprehensive.yaml | kubectl apply --dry-run=server -f -
```

At minimum, cover: default Deployment, StatefulSet + persistence, HPA + PDB (`autoscaling.enabled=true` and `minReplicas=2`), `strategy.type=Recreate` (confirm no stale rollingUpdate remains), jobs / cronJobs (comprehensive example; a Job without `helm.sh/hook` must fail), preStop resolution (default sleep / `--kube-version 1.29.0` exec fallback / a user `exec` handler), and the LoadBalancer example.

## Release

Automated by semantic-release, gated on CI: a push to master runs `ci.yml`; on success, `semantic-release.yml` analyzes Conventional Commits (`fix:` = patch, `feat:` = minor, `feat!:` / `BREAKING CHANGE:` = major), bumps `Chart.yaml`, writes `CHANGELOG.md`, tags `v<version>`, pushes the OCI chart to `ghcr.io/yupanzi/charts` and creates the GitHub Release. Never edit the `Chart.yaml` version or `CHANGELOG.md` by hand. Commits without a releasable type (`chore:`, `docs:`, ...) publish nothing — the run still ends green.

Manual fallback (`release.yml`): only while `semantic-release.yml` is disabled — set the `Chart.yaml` version, `git tag v<version>`, push the tag. Never re-tag a version semantic-release already published.

One-time setup after the first release: GHCR packages do not inherit repository visibility — make `ghcr.io/yupanzi/charts/dockerhelm` public in the package settings, or anonymous `helm pull` fails.
