# Harbor ARM64 Builds

This repository does not maintain a Harbor source fork. It only contains GitHub Actions automation that:

- resolves the latest stable upstream `goharbor/harbor` tag, or uses a manually supplied tag;
- checks out that upstream tag at workflow runtime;
- checks `ghcr.io/abhi1693` for existing ARM64 images;
- builds and publishes only when the target ARM64 image tags are missing.

The workflow runs on manual dispatch and on the 1st and 15th of each month.

For a Harbor tag like `v2.15.1`, images are published as:

- `ghcr.io/abhi1693/<component>:v2.15.1`
- `ghcr.io/abhi1693/<component>:v2.15.1-arm64`
- `ghcr.io/abhi1693/<component>:latest-arm64`

The exact version tag in this namespace is ARM64-only and is intended for ARM64 clusters that override the Harbor Helm chart image repositories.
