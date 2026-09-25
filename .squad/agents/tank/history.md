# Project Context
- **Owner:** Emmanuel
- **Project:** Azure enterprise-scale landing zone multi-subscription demo
- **Stack:** Bicep, PowerShell, Bash, Azure CLI, Azure Policy, Azure RBAC
- **Created:** 2026-09-23T10:00:40.745-04:00

## Learnings

- The offline preflight harness can model Azure REST transport failures with a nonzero mock exit plus stderr, and must assert those diagnostics are not collapsed into a confirmed RBAC denial.
- Effective-permission regression coverage now distinguishes allowed, denied, request-failed, invalid-JSON, and empty-response outcomes in both PowerShell and Bash, including wildcard `Actions` and wildcard `NotActions`.
- On this Windows checkout, the Bash files use CRLF and the available WSL environment has no native `jq`; normalized Bash syntax validates, but executing the Bash offline suite requires an LF checkout with Linux `jq`.
