# Agent instructions

GitOps repo for Backstage's workloads on the shared `bnjns` EKS cluster, managed by Argo CD. See
[README.md](README.md) for layout and workflow.

## YAML style

- Use single quotes for string values, not double quotes.

```yaml
# good
value: 'Europe/London'
newTag: '4.0.17'

# bad
value: "Europe/London"
newTag: "4.0.17"
```

## App structure

- Every `Application` lives in the `backstage-argocd` namespace and uses `project: backstage`.
- Enable automated sync with `prune: true` and `selfHeal: true`.
- Always set `ServerSideApply=true`. Never set `CreateNamespace=true` or commit `Namespace` manifests: the
  namespaces are created by the cluster owner.

- **Helm apps**: define the chart in the Argo CD `Application` (chart repo, chart name, `targetRevision`); put
  configuration in `<group>/<app>/values.yaml`, referenced via `$values`.

```yaml
# apps/<group>/<app>.yaml (example)
sources:
  - repoURL: <chart-repo-url>
    chart: <chart-name>
    targetRevision: <version>
    helm:
      valueFiles:
        - $values/<group>/<app>/values.yaml
  - repoURL: https://github.com/backstage-technical-services/eks-k8s.git
    targetRevision: HEAD
    ref: values
```

- **Non-Helm apps**: use Kustomize. Manifests live under `<group>/<app>/` with a `kustomization.yaml`; the Argo CD
  `Application` points at that path.

```yaml
# apps/<group>/<app>.yaml (example)
source:
  repoURL: https://github.com/backstage-technical-services/eks-k8s.git
  targetRevision: HEAD
  path: <group>/<app>
```

- Pin container image versions in `kustomization.yaml` under `images.newTag`. In workload manifests, use `:unknown` as
  the tag so manifests applied without Kustomize fail instead of pulling `:latest`.

```yaml
# <group>/<app>/deployment.yaml (example)
image: ghcr.io/example/app:unknown

# <group>/<app>/kustomization.yaml (example)
images:
  - name: ghcr.io/example/app
    newTag: '1.2.3'
```

- Give every manifest an explicit `metadata.namespace` (`backstage` or `backstage-tailscale`).

Scaffolding a new app end-to-end: use the `add-app` skill.

## Labels

Label every object with `bnjns.uk/owner: 'backstage'` through Kustomize `labels:`. Never set `includeSelectors` or
`includeTemplates`: selectors on StatefulSets and Deployments are immutable, and pod template labels are written out
in the workload manifest.

```yaml
# <group>/<app>/kustomization.yaml
labels:
  - pairs:
      bnjns.uk/owner: 'backstage'
```

Helm apps and files rendered outside Kustomize set the label in the manifest or chart values.

## Scheduling

Every pod must run on the `backstage` node group, which is tainted for Backstage. Set both the node selector and the
toleration on every pod template:

```yaml
nodeSelector:
  bnjns.uk/owner: 'backstage'
tolerations:
  - key: 'bnjns.uk/reserved-for'
    operator: 'Equal'
    value: 'backstage'
    effect: 'NoSchedule'
```

## Storage

Persistent data lives on the `backstage-data` EFS filesystem (`fs-05929b3d75352ac77`), one access point per volume.
Volumes are static: a `PersistentVolume` per access point, bound by a `PersistentVolumeClaim` that selects it by label.

- `storageClassName: aws-efs`, `ReadWriteMany`, `persistentVolumeReclaimPolicy: Retain`.
- `volumeHandle: 'fs-05929b3d75352ac77::<access-point-id>'` with `encryptInTransit: 'true'`.
- Label the PV and select it from the PVC with `backstage.uk/storage-name: <name>` plus the app's selector labels.
- Annotate every `PersistentVolume` with `argocd.argoproj.io/sync-options: 'Delete=false,Prune=false'`.
- Access points are created outside this repo; ask for the ID rather than inventing one.

## Exposure

- **Tailscale**: annotate a `Service` to expose it on the tailnet through the operator in `backstage-tailscale`.

```yaml
metadata:
  annotations:
    tailscale.com/expose: 'true'
    tailscale.com/proxy-class: 'backstage'
```

- **Public**: the cluster's Traefik is internet-facing, so every `Ingress` is public. Reuse the Middlewares in the
  `backstage` namespace (`backstage-<name>@kubernetescrd`):

| Middleware | Purpose |
| --- | --- |
| `redirect-http-to-https` | Permanent redirect to HTTPS |
| `rate-limit` | 50 req/s average, burst 1000 |
| `ip-allowlist-internal` | Cluster service CIDR only |
| `ip-allowlist-trusted` | Fixed trusted ranges plus GitHub Actions IPv4 ranges |

`ip-allowlist-trusted` is not managed by Argo CD. A CronJob in `platform/traefik-middlewares` rebuilds it daily from
`update-ip-allowlist-trusted/fixed-ranges.txt` and `https://api.github.com/meta`; edit the fixed ranges there.

## Validation

Validate changes before committing:

- **Kustomize apps**: `kubectl kustomize <group>/<app>`
- **Helm apps**: `helm template <release> <chart> --repo <repo-url> --version <targetRevision> -f <group>/<app>/values.yaml`

## Security

- Never commit cleartext secrets. Reference SSM parameters with an `ExternalSecret` against the `aws-ssm`
  `ClusterSecretStore`:

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: <app>
  namespace: backstage
spec:
  secretStoreRef:
    kind: ClusterSecretStore
    name: aws-ssm
  data:
    - secretKey: <KEY>
      remoteRef:
        key: /backstage/<app>/<parameter>
```

- Never invent parameter names; ask for the SSM path if it is not already known.
