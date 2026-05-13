# Argo CD — Application pointing at the same bundle path as Flux.
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: cloudjumper-__CUSTOMER__-__STAMP_SLUG__
  namespace: argocd
spec:
  project: default
  source:
    repoURL: __GIT_URL__
    targetRevision: __BRANCH__
    path: __KUSTOMIZE_PATH__
  destination:
    server: https://kubernetes.default.svc
    namespace: cloudjumper-gitops
  syncPolicy:
    automated:
      prune: true
      selfHeal: false
