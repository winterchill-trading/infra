# compose/ (AGENTS.md)

`docker-compose.yml` defines the local stack under profiles: `monitoring`, `day-close`, `copy`, `testnet`,
`db` and `neobank`. `recorder.sexp` and `recorder-testnet.sexp` are recorder configs; `prometheus.yml`
scrapes the services; `postgres/` holds the database init script; the nginx configs serve the web apps.

- Run `make up` and `make down` through the Makefile, whose `ALL_PROFILES` lets `down` reach every profile.
- Name services explicitly: `docker compose --profile X up` also starts services with no profile.
- A volume shared by two containers takes its owner from the first mount. Mount it read-only in the second.
- Keep `postgres/initdb.d/10-databases.sh` identical to the chart's copy; `make lint` checks it.
