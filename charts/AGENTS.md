# charts/ (AGENTS.md)

`winterchill/` is the Helm chart: recorder deployments and services, the day-close cron job, the
simulators, copy trading, node-exporter and PostgreSQL. `values.yaml` holds defaults and `values-dev.yaml`
the local values. `rendered-example.yaml` is the reviewed render of the dev values.

- Defaults reference commit-tagged images, never `latest`.
- After a template change run `make chart` and review the diff of `rendered-example.yaml`.
- `make lint` runs `helm lint` with both value files and the init-script copy check.
