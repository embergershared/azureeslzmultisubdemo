# Project Context
- **Owner:** Emmanuel
- **Project:** Azure enterprise-scale landing zone multi-subscription demo
- **Stack:** Bicep, PowerShell, Bash, Azure CLI, Azure Policy, Azure RBAC
- **Created:** 2026-09-23T10:00:40.745-04:00

## Learnings

### 2026-09-23 — Management-group effective-permissions review

- The documented Microsoft.Authorization Permissions API `2022-04-01` supports only resource-group and resource paths. It does not define a management-group or generic `ListForScope` operation.
- Therefore, `/providers/Microsoft.Management/managementGroups/{id}/providers/Microsoft.Authorization/permissions` cannot be used as a reliable hard gate. Failure means permission state is unknown, not that the caller lacks the requested action.
- The management-group scope is nevertheless the correct bootstrap scope for policy writes into newly created descendant management groups, because those permissions must be inherited from an existing ancestor.
- Role-assignment enumeration at management-group scope is supported, but it is advisory unless evaluation includes inherited/direct assignments, transitive group membership, role definitions, conditions, and deny assignments.
- The deployment also needs management-group creation and subscription-association permissions; checking only Policy/RBAC actions cannot prove deployability.
