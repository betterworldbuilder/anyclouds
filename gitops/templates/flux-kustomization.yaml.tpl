# Flux — reconcile the Kustomize stub path created by Cloud Jumper push-backup.
# Extend this directory in Git with HelmReleases, ConfigMaps, etc. as needed.
apiVersion: kustomize.toolkit.fluxcd.io/v1beta2
kind: Kustomization
metadata:
  name: cloudjumper-bundle-__STAMP_SLUG__
  namespace: __FLUX_NS__
spec:
  interval: 10m0s
  path: __KUSTOMIZE_PATH__
  prune: true
  sourceRef:
    kind: GitRepository
    name: cloudjumper-gitops-__CUSTOMER__
  wait: true
  timeout: 5m0s
