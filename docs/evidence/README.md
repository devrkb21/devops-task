# Evidence

Text output from real runs, referenced from the main README:

- `k8s-demo.txt` - `make k8s-demo`: rolling update 1.0.0 → 1.0.1 and `kubectl rollout undo`, both with 0 failed requests
- `k8s-checks.txt` - HPA, probes, non-root user, read-only root filesystem and Pod Security labels in the k3d cluster
- `alerts-firing.txt` - Prometheus `/api/v1/alerts` after the traffic run, with `AppHighErrorRate` firing

Still to add after running against AWS:

- `terraform-plan.txt` - `terraform plan -var-file=environments/staging.tfvars -no-color > terraform-plan.txt`
