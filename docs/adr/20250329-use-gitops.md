# Use GitOps

- Status: proposed
- Deciders: Andrew Smith
- Date: 2025-03-29
- Tags: devops

Technical Story: [#1011](https://github.com/andrew-codes/home-ops/issues/1011), [#919](https://github.com/andrew-codes/home-ops/issues/919)

## Context and Problem Statement

Updates to applications are not automatically deployed. It is too easy to update and forget to deploy. Furthermore, the deployment mechanism is inflexible. Prime use cases that cannot be easily achieved is deploying the same app to a different cluster, deploying a non-latest version and deploying multiple versions.

Should home-ops utilize a deployment mechanism that is controlled by automation and versioned in source control?

## Decision Drivers

- Deployed apps being out of date from changes in the main branch.
- Untested changes can and do bring down the production use of services that impact family members, but cannot provision or deploy to a separate cluster for verification.
- Cannot run multiple versions of a single app; used for Playnite Web to demo latest changes to external parties.

## Considered Options

1. [FluxCD](https://fluxcd.io/flux/)
2. [ArgoCD](https://argo-cd.readthedocs.io/en/stable/)

## Decision Outcome

### Positive Consequences

- Following a more standard approach to deployments help new users navigate the codebase and understand its various concepts.

### Negative Consequences

- Significant restructuring of files will cause difficulties navigating the repo's history when using git blame, etc.

## Pros and Cons of the Options

### Option 1: FluxCD

FluxCD is robust and endorsed by the [Cloud Native Computing Foundation](https://www.cncf.io/) (CNCF). For this reason, it has a thriving community and exceptional documentation.

- Good, exceptional documentation; detailing several use cases that directly align.
- Good, remove reliance on 1Password and its CLI via use of Bitnami's sealed secrets; [#997](https://github.com/andrew-codes/home-ops/issues/997).
- Good, automatically update deployments via semver matching; auto sync.
- Bad, web UI requires additional setup work.

### Option 2: ArgoCD

- Good, appears more straight forward to setup (at least on the surface).
- Good, contains a built in web UI.
- Good, remove reliance on 1Password and its CLI via use of Bitnami's sealed secrets; [#997](https://github.com/andrew-codes/home-ops/issues/997).
- Bad, sync approach exist only through hooks or manually.
-
