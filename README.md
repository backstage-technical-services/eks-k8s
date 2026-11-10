# eks-k8s

GitOps configuration for Backstage's workloads on `bnjns`, the shared EKS cluster in `eu-west-1`. Backstage runs on
its own `backstage` node group, in the `backstage` and `backstage-tailscale` namespaces.

Argo CD reconciles everything here. The cluster and the platform services it relies on (Argo CD itself, Traefik,
cert-manager, external-secrets, the EFS CSI driver) are run by the cluster owner, outside this repo. Backstage's
AWS resources, including SSM parameters and EFS access points, are in
[backstage-technical-services/terraform](https://github.com/backstage-technical-services/terraform).

## Argo CD

- `Application`s live in the `backstage-argocd` namespace and belong to the `backstage` project.
- Syncs run as a restricted Backstage service account rather than as Argo CD itself. An app can only manage what the
  `backstage` project and that account allow; ask the cluster owner before adding a new kind of cluster-scoped object.
- Applications sync automatically, with prune and self-heal.
- The cluster owner creates the `backstage-argocd`, `backstage` and `backstage-tailscale` namespaces. Apps never
  create namespaces.

## Layout

| Path | Contents |
| --- | --- |
| `apps/` | Argo CD `Application` manifests, one per app |
| `platform/` | RBAC, the Tailscale operator, Traefik middlewares and StorageClasses |
| `databases/` | Shared database servers |
| `services/` | Supporting services (mail catcher, LDAP) |

Each application appears twice: an `Application` in `apps/<group>/<app>.yaml` that says where it goes and when, and a
`<group>/<app>/` directory holding what it actually is. Helm apps keep a `values.yaml`; everything else is Kustomize.

Agent conventions (YAML style, app patterns, scheduling, storage, validation) live in [AGENTS.md](AGENTS.md).

## Deployment order

Sync waves, rather than manual sequencing. Check `argocd.argoproj.io/sync-wave` on peers under `apps/` when adding
something new.

| Wave | Role |
| --- | --- |
| `0` | RBAC |
| `10` | Platform services (Tailscale operator, Traefik middlewares, StorageClasses) |
| `20` | Databases |
| `30` | Services |

## Exposure

Services reach the tailnet through the Tailscale operator in `backstage-tailscale`, by annotating the `Service`. Public
traffic goes through the cluster's internet-facing Traefik, using the Middlewares in the `backstage` namespace. The
`ip-allowlist-trusted` Middleware is rebuilt daily by a CronJob from a fixed list in git plus GitHub Actions' IPv4
ranges, so it is not managed by Argo CD. Details are in [AGENTS.md](AGENTS.md#exposure).

## Secrets

Secrets are never committed. Values live in SSM Parameter Store and reach the cluster through `ExternalSecret`
resources against the `aws-ssm` `ClusterSecretStore`. The parameters themselves are created in Terraform.
