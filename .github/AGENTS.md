# .github/ (AGENTS.md)

`workflows/` holds `ci.yml` (lint, helm, compose, the `ox-setup` exercise, obj-magic), `base-image.yml`,
`service-images.yml` (manual), `o3-compare.yml` and `proctopus.yml` (manual). `obj-magic.yml` and
`actions/ox-setup/` are the reusable pieces other repositories call.

- A change to `ox-setup` affects every OCaml repository's CI. Exercise it through the `ox-setup` job in
  `ci.yml` before merging, and note the cache-key change in `docs/ci.md`.
- Keep the `concurrency` block in `ci.yml`.
- Check a run with one `gh run list --limit 1`, and at most one `gh run watch <id> --exit-status`.
