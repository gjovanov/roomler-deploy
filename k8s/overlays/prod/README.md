# roomler (old) prod overlay

ArgoCD syncs this path. Base lives under `../../base`.

This is the **legacy** Roomler (Nuxt 2 SSR). The newer Roomler AI lives at
`roomler-ai` namespace + `roomler-ai-deploy` repo; do not confuse.

## Current state

- Images are local (`ctr import` on worker-1), `imagePullPolicy: Never`.
- Secrets (`roomler-secret`, `mongodb-secret`) sealed under `base/sealed/`.
- PVCs managed out-of-tree.

## Deployment

Changes committed to this repo and pushed trigger (on manual `argocd app sync
roomler-old`) a reconcile of the manifests. Image migration to
`registry.roomler.ai` is a follow-up — see `kustomization.yaml` header for the
recipe.
