# Azure ESLZ multi-subscription tenant deployment map

```mermaid
flowchart TB
  classDef existing fill:#f3f4f6,stroke:#6b7280,stroke-dasharray:5 5,color:#111827
  classDef mg fill:#dbeafe,stroke:#2563eb,color:#111827
  classDef governance fill:#ede9fe,stroke:#7c3aed,color:#111827
  classDef optional fill:#fef3c7,stroke:#d97706,stroke-dasharray:5 5,color:#111827
  classDef resource fill:#dcfce7,stroke:#16a34a,color:#111827

  TENANT[Microsoft Entra / Azure tenant]:::existing
  ROOT[Existing tenant-root management group]:::existing
  GROUPS[Existing Entra security groups\nGovernance admins · Network operators\nWorkload contributors · Read-only auditors]:::existing

  TENANT --> ROOT
  ROOT --> DEMO[New demo-root management group]:::mg

  subgraph DEMOGOV[Governance resources stored at demo root]
    PD[10 custom policy definitions\nlocations · resource types · public IP · ingress\nsubnet NSG · private access · firewall routes\nexpensive resources · storage CMK · platform tags]:::governance
    PI[Custom policy initiatives\nRG tags · tag inheritance · deployment restrictions\nnetwork ingress · private access · data protection\nbackup posture · NERC CIP overlay]:::governance
    PA[Policy assignments\ncustom controls + built-in benchmarks\nlogging · diagnostics · Defender plans]:::governance
    PE[Optional policy exemptions\nMG / subscription / resource-group scope]:::optional
    MID[Optional system-assigned identities\non remediation-capable assignments]:::optional
    PD --> PI --> PA
    PA -. optional .-> MID
    PA -. governed exceptions .-> PE
  end

  DEMO --> DEMOGOV
  DEMO --> PLATFORM[Platform management group]:::mg
  DEMO --> LZ[Landing Zones management group]:::mg

  PLATFORM --> CONNMG[Connectivity management group]:::mg
  CONNMG --> CONNSUB[Existing connectivity subscription\nre-parented into hierarchy]:::existing

  subgraph CONNRES[Connectivity subscription — opt-in resources]
    MONRG[rg-&lt;prefix&gt;-monitoring]:::optional
    LAW[Log Analytics workspace\nlog-&lt;prefix&gt;-central]:::optional
    SENT[Microsoft Sentinel onboarding]:::optional
    EVRG[rg-&lt;prefix&gt;-connectivity-demo]:::optional
    VNET[VNet vnet-&lt;prefix&gt;-shared]:::optional
    NSG[NSG nsg-&lt;prefix&gt;-shared]:::optional
    MONRG --> LAW --> SENT
    EVRG --> VNET
    EVRG --> NSG
  end
  CONNSUB -. deployCentralLogAnalytics / deploySentinel .-> MONRG
  CONNSUB -. deployEvidenceResources .-> EVRG

  LZ --> WORKMG[Corp or Online management group]:::mg
  WORKMG --> WORKSUB[Existing workload subscription\nre-parented into hierarchy]:::existing

  subgraph WORKRES[Workload subscription — opt-in resources]
    WEVRG[rg-&lt;prefix&gt;-&lt;corp|online&gt;-demo]:::optional
    BKPRG[rg-&lt;prefix&gt;-backup]:::optional
    RSV[Recovery Services vault\nrsv-&lt;prefix&gt;-backup]:::optional
    BKPPOL[VM backup policy\nbkp-&lt;prefix&gt;-vm-daily]:::optional
    WEVRG
    BKPRG --> RSV --> BKPPOL
  end
  WORKSUB -. deployEvidenceResources .-> WEVRG
  WORKSUB -. deployRecoveryServicesVault .-> BKPRG

  LZ -. enableCriticalInfrastructure .-> CIMG[Critical Infrastructure management group]:::optional
  CIMG -. optional association .-> CISUBS[Existing critical-workload subscriptions]:::existing

  GROUPS -. deployRoleAssignments .-> DEMO
  GROUPS -. deployRoleAssignments .-> CONNSUB
  GROUPS -. deployRoleAssignments .-> WORKSUB

  DEMOGOV -. inherited policy .-> PLATFORM
  DEMOGOV -. inherited policy .-> LZ
  LAW -. destination for optional policy-based logs .-> PA
```

## Scope and behavior

- **Always deployed by `main.bicep`:** the management-group hierarchy; association of the two supplied existing subscriptions; custom policy definitions and initiatives at the demo root; and policy assignments at the demo root, Platform, Landing Zones, and Corp/Online scopes. Many assignments are deliberately `DoNotEnforce`, `Audit`, or `Disabled` by default.
- **Optional:** Critical Infrastructure branch and subscription associations, Azure RBAC assignments, policy exemptions, managed identities/remediation RBAC, evidence resource groups/VNet/NSG, central Log Analytics/Sentinel, and a workload Recovery Services vault/backup policy.
- **Not created:** subscriptions, Entra groups/users, VMs, storage accounts, Key Vaults, private endpoints, firewalls, or customer-managed keys. Existing Entra groups and optional existing Log Analytics/firewall/vault resources are referenced by ID.
- **Paid-resource warning:** Log Analytics, Sentinel, Defender plans, and Azure Backup are explicit opt-ins; the provided parameter templates keep them disabled.
