---
'@inkeep/open-knowledge': patch
---

The public-content check keys an exception on path, rule and line hash, without a line number, so an upstream edit that moves an excepted line no longer fails the check. Convert each row of `scripts/tenant/public-check.allow` to four fields; see `deploy/docs/deployment.md`.
