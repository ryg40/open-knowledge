---
'@inkeep/open-knowledge': patch
---

The pin check `scripts/tenant/pins.sh` exits with 2 when a pin source or a checked document is not a regular file. With GNU awk, a directory in place of a document was skipped and the check passed.
