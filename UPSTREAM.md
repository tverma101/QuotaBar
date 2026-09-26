# OpenUsage upstream provenance

Status: **external-derived / quarantined pending repository ownership decision (#41)**

## Observed upstream

The subtree's existing README points to:

- Repository: `https://github.com/robinebers/openusage`
- Product/release identity: OpenUsage
- License file present in this subtree: `LICENSE`

## Imported revision

**Unknown.**

Do not guess or synthesize a commit SHA/tag. The exact source revision must be established from Git history or a reproducible upstream comparison before this field is changed.

## Local purpose

This tree is currently tracked inside `tverma101/Tools` as a substantial OpenUsage-derived macOS usage-tracker codebase. Whether it should remain vendored here, become a maintained fork, or move to a separate repository is unresolved in #41.

## Agent modification policy

Unless an issue explicitly targets `OpenUsage/`:

- do not edit this subtree;
- do not run repo-wide formatting/refactors/dependency updates through it;
- do not reinterpret upstream release/CI/contribution files as policy for the whole `Tools` repository;
- do not remove or rewrite upstream attribution, license, trademark, security or contributor notices;
- do not claim local ownership of upstream behavior merely because the files are tracked here.

When explicitly tasked here, read `OpenUsage/AGENTS.md` in addition to the repository root agent contract.

## Local patches

Not yet inventoried. #41 owns identifying local deltas from upstream.

Record future intentional patches here or in a linked patch manifest with:

- local commit/PR;
- upstream file/area;
- reason for divergence;
- whether the patch should be upstreamed, retained, or dropped during refresh.

## Update procedure

Not yet normalized. Until #41 defines a reproducible update procedure, do **not** perform opportunistic bulk upstream refreshes.

Any future refresh must preserve licenses/notices and produce a reviewable upstream-vs-local delta.
