---
name: add-app
description: >-
  Add a new Argo CD Application to Backstage's eks-k8s GitOps repo. Use when
  creating a new app, adding a service, or scaffolding Application manifests
  and app configuration under apps/ and the matching group directory.
---

# Add App

## Checklist

- [ ] Create `apps/<group>/<app>.yaml` (Argo CD `Application` in `backstage-argocd`, `project: backstage`)
- [ ] Create app payload under `<group>/<app>/`
- [ ] Choose a sync wave from dependency principles below (confirm against peers under `apps/`)
- [ ] Match existing `Application` defaults: automated sync with prune and selfHeal, `ServerSideApply=true`,
  no `CreateNamespace`
- [ ] Label everything `bnjns.uk/owner: 'backstage'` (Kustomize `labels:`, no `includeSelectors`/`includeTemplates`)
- [ ] Put every pod on the `backstage` node group (node selector and toleration, see Scheduling below)
- [ ] Give persistent data a static EFS volume (see Storage below)
- [ ] Validate with `kubectl kustomize` or `helm template` (see [AGENTS.md](../../../AGENTS.md))

## Groups and sync waves

Put the `Application` under `apps/<group>/` next to related apps. Payload lives at `<group>/<app>/`.

| Group | Put here when… |
| --- | --- |
| `platform` | Other apps depend on it (RBAC, operators, shared middlewares) |
| `databases` | It is a shared database server |
| `services` | It is a supporting service or workload |

Sync waves are **dependency bands**, not a catalogue of current apps:

| Wave | Put here when… |
| --- | --- |
| `0` | It is RBAC |
| `10` | It is a platform service other apps rely on |
| `20` | It is a database |
| `30` | It is an ordinary workload that depends on the above |

When unsure, open a similar `Application` under `apps/<group>/` and match its `argocd.argoproj.io/sync-wave`. Prefer an
existing band over inventing a new number. High-level overview: [README.md](../../../README.md).

## Helm app

1. `Application` in `apps/<group>/<app>.yaml` with multi-source: chart + `$values` ref
2. Values in `<group>/<app>/values.yaml`
3. Pin chart version via `targetRevision` in the `Application`

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: <app>
  namespace: backstage-argocd
  annotations:
    argocd.argoproj.io/sync-wave: '<wave>'
spec:
  project: backstage
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
  destination:
    server: https://kubernetes.default.svc
    namespace: backstage
  # Only for kinds this app actually manages that have /spec/replicas.
  # Deployment → kind: Deployment; StatefulSet → kind: StatefulSet; skip for DaemonSet.
  ignoreDifferences:
    - group: apps
      kind: Deployment
      jsonPointers:
        - /spec/replicas
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - RespectIgnoreDifferences=true
      - ServerSideApply=true
```

Set the chart's node selector and tolerations (see Scheduling) and its common labels, if it has them, in
`values.yaml`.

## Kustomize app

1. `Application` in `apps/<group>/<app>.yaml` pointing at `<group>/<app>`
2. Manifests + `kustomization.yaml` under `<group>/<app>/`, each with an explicit `metadata.namespace`
3. Pin image versions in `kustomization.yaml`; use `:unknown` in workload manifests

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: <app>
  namespace: backstage-argocd
  annotations:
    argocd.argoproj.io/sync-wave: '<wave>'
spec:
  project: backstage
  source:
    repoURL: https://github.com/backstage-technical-services/eks-k8s.git
    targetRevision: HEAD
    path: <group>/<app>
  destination:
    server: https://kubernetes.default.svc
    namespace: backstage
  # Only for kinds this app actually manages that have /spec/replicas.
  # Deployment → kind: Deployment; StatefulSet → kind: StatefulSet; skip for DaemonSet.
  ignoreDifferences:
    - group: apps
      kind: Deployment
      jsonPointers:
        - /spec/replicas
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - RespectIgnoreDifferences=true
      - ServerSideApply=true
```

```yaml
# <group>/<app>/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

labels:
  - pairs:
      bnjns.uk/owner: 'backstage'

resources:
  - service.yaml
  - deployment.yaml

images:
  - name: <image>
    newTag: '<version>'
```

Kustomize `labels:` only reaches object metadata. Write the pod template labels out in the workload, and keep the
selector to a stable label such as `backstage.uk/component: <app>`.

## Scheduling

Every pod template needs both:

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

Persistent data uses a static EFS volume: a `PersistentVolume` on an access point of `fs-05929b3d75352ac77`, and a
`PersistentVolumeClaim` that selects it by label. The access point is created in Terraform; ask for its ID.

```yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: backstage-<app>
  labels:
    backstage.uk/component: <app>
    backstage.uk/storage-name: <app>
  annotations:
    argocd.argoproj.io/sync-options: 'Delete=false,Prune=false'
spec:
  accessModes:
    - ReadWriteMany
  volumeMode: Filesystem
  storageClassName: aws-efs
  persistentVolumeReclaimPolicy: Retain
  capacity:
    storage: <size>
  csi:
    driver: efs.csi.aws.com
    volumeHandle: 'fs-05929b3d75352ac77::<access-point-id>'
    volumeAttributes:
      encryptInTransit: 'true'
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: <app>
  namespace: backstage
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: aws-efs
  resources:
    requests:
      storage: <size>
  selector:
    matchLabels:
      backstage.uk/component: <app>
      backstage.uk/storage-name: <app>
```

## Exposure

- **Tailscale only**: annotate the `Service` with `tailscale.com/expose: 'true'` and
  `tailscale.com/proxy-class: 'backstage'`.
- **Public**: every `Ingress` on the cluster is internet-facing. Only add one when the app has its own authentication,
  and attach the `backstage` Middlewares it needs (`backstage-redirect-http-to-https@kubernetescrd`, and an IP
  allowlist where appropriate). See [AGENTS.md](../../../AGENTS.md#exposure).

## Secrets

If the app needs secrets, add an `ExternalSecret` (pattern in [AGENTS.md](../../../AGENTS.md#security)) as
`<group>/<app>/externalsecret.yaml`. The SSM parameter must already exist under `/backstage/` — ask for its path rather
than inventing one.

- **Kustomize apps**: list `externalsecret.yaml` in `kustomization.yaml` resources.
- **Helm apps**: let the `$values` source also render it, and label it in the manifest.

```yaml
    - repoURL: https://github.com/backstage-technical-services/eks-k8s.git
      targetRevision: HEAD
      ref: values
      path: <group>/<app>
      directory:
        include: 'externalsecret.yaml'
```
