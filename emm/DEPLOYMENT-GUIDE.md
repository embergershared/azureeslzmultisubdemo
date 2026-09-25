# Deploying the sample Azure Landing Zone

Use the repository's **PowerShell 7 deployment workflow**, starting with the
governance-only profile. **Even this safe profile moves your two subscriptions**,
so use sandboxes and approve the inheritance changes first.

Run all commands below from the repository root, not from the `emm` folder.

## 1. Prepare Azure access and collect IDs

You need these values:

| Parameter | Value to supply |
|---|---|
| `tenantRootManagementGroupId` | Existing Tenant Root Group ID |
| `connectivitySubscriptionId` | Connectivity sandbox subscription GUID |
| `workloadSubscriptionId` | Different workload sandbox subscription GUID |
| `governanceAdminsGroupObjectId` | Existing governance administrators security-group object ID |
| `networkOperatorsGroupObjectId` | Existing network operators security-group object ID |
| `workloadContributorsGroupObjectId` | Existing workload contributors security-group object ID |
| `readOnlyAuditorsGroupObjectId` | Existing auditors security-group object ID |
| `namePrefix` | Unique lowercase prefix, such as `eslz-lab-sep26` |

Both subscriptions must be enabled and belong to the same tenant. All four group
IDs must be distinct, even when role deployment is disabled.

Have your Azure administrator authorize management-group creation, subscription
movement, policy management, and tenant/nested deployments. **Subscription Owner
alone is insufficient.** See [required permissions](../README.md#required-permissions).

Record the subscriptions' original management-group parents and inherited
access/policies. Verify that none of the generated management-group names already
exists.

## 2. Verify tools and sign in

Run from **PowerShell 7**, in this repository's root:

```powershell
$PSVersionTable.PSVersion
git --version
az version
az bicep version
```

If Azure CLI's Bicep component is missing:

```powershell
az bicep install
```

Sign in to the intended tenant and confirm subscription visibility:

```powershell
az login --tenant "<YOUR-TENANT-GUID>"
az account show --output table
az account list --all --output table
```

The deployment targets come from your parameter file, not merely the currently
selected subscription.

## 3. Create your local parameter file

If you have not already created it:

```powershell
Copy-Item .\parameters\demo.parameters.template.json `
    .\parameters\demo.parameters.json
```

Edit `parameters\demo.parameters.json` in VS Code. Replace every `REPLACE_WITH_*`
value and choose your unique prefix. **Keep the rest of the full template
intact**: preflight expects its parameter names and types.

For the first deployment, retain:

| Setting | Safe value |
|---|---|
| `denyPolicyEnforcementMode` | `"DoNotEnforce"` |
| `deployRoleAssignments`, `deployEvidenceResources`, `enableTagInheritance` | `false` |
| `deployCentralLogAnalytics`, `deploySentinel` | `false` |
| `enableDefenderCspm`, `enableDefenderForServers`, `enableDefenderForStorage` | `false` |
| `activityLogExportPolicyEffect`, `resourceDiagnosticsPolicyEffect` | `"Disabled"` |
| `enableVmBackupRemediation`, `enableVaultDiagnostics`, `deployRecoveryServicesVault` | `false` |
| `enableCriticalInfrastructure`, `enableNercCipTechnicalOverlay` | `false` |
| `policyExemptions` | `[]` |

The shipped `enableDefenderCiem=true` can remain unchanged: it is inactive while
`enableDefenderCspm=false`.

## 4. Validate and preview without deploying

Run these **one at a time**, stopping on any failure:

```powershell
.\tests\test.ps1
```

```powershell
.\scripts\preflight.ps1 -ParameterFile .\parameters\demo.parameters.json
```

```powershell
.\scripts\what-if.ps1 -ParameterFile .\parameters\demo.parameters.json
```

Resolve any missing permissions, provider registrations, invalid IDs, or
policy-version issues reported by preflight before proceeding.

Review the preview with your administrator. For this profile, expect **five
management groups, subscription placement, and policy governance objects**. Stop
if it shows unintended subscription targets, management-group modifications,
deletions, resource groups, workload resources, or paid services.

Separately review the access/policy implications of moving the subscriptions;
what-if is not a complete inherited-access impact report.

## 5. Execute the deployment

**This step changes Azure and moves the subscriptions.** Only after approving the
preview:

```powershell
$env:ESLZ_DEPLOY_CONFIRMATION = "DEPLOY-ESLZ-DEMO"

.\scripts\deploy.ps1 -ParameterFile .\parameters\demo.parameters.json
```

The script reruns preflight and what-if, prints the targets, and asks you to type
the exact `namePrefix`. Confirm only if everything matches.

Afterward, remove the confirmation flag:

```powershell
Remove-Item Env:\ESLZ_DEPLOY_CONFIRMATION
```

## 6. Confirm the result

In the Azure portal, check **Management groups** and **Policy**:

- Connectivity subscription is under `<prefix>-connectivity`; workload
  subscription is under `<prefix>-corp` or `<prefix>-online`.
- Demo policy assignments are confined to the demo hierarchy.
- Deny-capable assignments remain `DoNotEnforce`.
- No unexpected RBAC assignments, resource groups, or paid resources were created.

If you later want the sample VNet/NSG and two resource groups, set
`deployEvidenceResources=true`, then repeat validation, preview, and deployment.
Enable RBAC separately with `deployRoleAssignments=true`.

The repository's [First-Run Checklist](../docs/FIRST-RUN-CHECKLIST.md) is the
operator reference. **Do not treat teardown as a full rollback:** it returns
subscriptions to tenant root, not their original parents.
