# Screenshots

Taken from a local run: `make up`, then 8 minutes of `scripts/generate-traffic.sh` with
`DEBUG_TOKEN` set (error spike).

- `dashboard-application.png` - Application dashboard during the error spike
- `dashboard-host.png` - Host dashboard
- `dashboard-containers.png` - Containers dashboard
- `alert-rules.png` - Grafana alert rule list with `AppHighErrorRate` firing

Still to add after running against AWS:

- `terraform-apply.png` - successful `terraform apply` of the staging environment
- `deploy-run.png` - successful Release/Deploy workflow run
