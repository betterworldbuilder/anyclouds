# Flux — track the GitOps repo that receives Cloud Jumper push-backup commits.
# Apply into the cluster (e.g. kubectl apply -f) after replacing placeholders or use Stage 8 snippet generator.
apiVersion: source.toolkit.fluxcd.io/v1beta2
kind: GitRepository
metadata:
  name: cloudjumper-gitops-__CUSTOMER__
  namespace: __FLUX_NS__
spec:
  interval: 1m0s
  url: __GIT_URL__
  ref:
    branch: __BRANCH__
