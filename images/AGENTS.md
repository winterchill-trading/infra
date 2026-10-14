# images/ (AGENTS.md)

`oxcaml-base/` builds the base image (Ubuntu, opam, the `5.2.0+ox` switch with every library the org
uses). `service/` builds any service image: `build.sh <repo> <binary>` pins the repo and its siblings at
resolved commits and tags the image `:<commit12>`, labelled with the commits.

- Build the base with `make base`; a change to it moves every service's cache, so say so in the commit.
- Keep runtime stages small. A service image must not carry the compiler.
- Image sizes and build times are measured in `docs/images.md`; update it with any measured change.
