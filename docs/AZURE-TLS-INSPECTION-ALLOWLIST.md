# Azure Private-Network Connectivity and TLS Inspection

## Contents

- [Scope and rule types](#scope-and-rule-types)
- [Microsoft Entra ID](#microsoft-entra-id)
- [Azure Resource Manager and governance](#azure-resource-manager-and-governance)
- [Azure portal (administrative browsers only)](#azure-portal-administrative-browsers-only)
- [Virtual Network, private endpoints, and DNS](#virtual-network-private-endpoints-and-dns)
- [Azure Service Bus](#azure-service-bus)
- [Azure Kubernetes Service (AKS)](#azure-kubernetes-service-aks)
- [Azure Container Apps](#azure-container-apps)
- [Azure Container Registry (ACR)](#azure-container-registry-acr)
- [Azure Storage](#azure-storage)
- [Azure Key Vault](#azure-key-vault)
- [Azure Monitor, Log Analytics, and Microsoft Sentinel](#azure-monitor-log-analytics-and-microsoft-sentinel)
- [Azure Backup and Recovery Services vaults](#azure-backup-and-recovery-services-vaults)
- [Sources](#sources)

## Scope and rule types

**No.** The original five names cover only sign-in and Azure Resource Manager
(ARM); they do not cover every Azure control or data plane. There is no fixed,
universal FQDN list for every Azure resource. This guide is for **Azure public
cloud**, from clients, VMs, and workloads in restricted Azure VNets. The
repository deploys governance, network evidence, optional Log Analytics /
Sentinel, and optional Recovery Services vault resources. Service Bus, AKS,
Container Apps, and ACR are **conditional workload examples**, not resources
deployed by this template. Sovereign clouds use different suffixes.

Use the table entries for the **source subnet and feature actually in use**.
Unless a row specifies otherwise, HTTPS uses outbound TCP 443. `<...>` means
replace with a value from the deployed resource; it is **not** a literal
firewall entry. An FQDN rule controls the destination name; a service tag
controls a set of public IP prefixes, **not** TLS inspection or authorization.
Private endpoints still require routable private IPs, working DNS, and
appropriate network rules. Neither a private endpoint nor a service tag
automatically grants data-plane access.

**Allow traffic** and **bypass TLS decryption** are separate NVA settings.
Where inspection causes certificate validation or protocol failures, exempt
the affected Microsoft endpoint from interception; keep normal end-to-end TLS
verification enabled. Do not set `AZURE_CLI_DISABLE_CONNECTION_VERIFICATION=1`
as a permanent fix. Prefer resource-specific names over broad wildcards.
Consult each linked service reference before enabling optional features or
using ports other than 443.

## Microsoft Entra ID

| Outbound FQDN | When / why |
| --- | --- |
| `login.microsoftonline.com` | Azure CLI, SDK, and workload-identity token requests. Include the exact host even when allowing a wildcard. |
| `*.microsoftonline.com` | Other sign-in, device, or tenant-specific authentication hosts when used by the client. |
| `*.msauth.net`, `*.msftauth.net` | Interactive authentication assets; required if the sign-in flow requests them. |
| `graph.microsoft.com` | Microsoft Graph operations, for example this repository's `az ad group show`; **not** the ARM endpoint. |

Managed-identity token retrieval can use a local platform endpoint rather
than a call from the VM to `login.microsoftonline.com`. Allow the actual
outbound identity traffic of the hosting platform (see Container Apps and AKS
below). Do not treat OAuth token audience strings as network destinations.
[Sources: portal authentication; Microsoft Graph API; Microsoft 365 endpoint sets 56/59.](#sources)

## Azure Resource Manager and governance

| Outbound FQDN | When / why |
| --- | --- |
| `management.azure.com` | Azure CLI `az rest`, Bicep/ARM deployments, management groups, Azure Policy, RBAC, PIM, subscriptions, VNet/NSG/private-DNS configuration, monitoring/vault setup, and other resource **control-plane** operations. |

ARM management calls do **not** cover a resource's data plane (for example,
sending Service Bus messages or reading Key Vault secrets). ARM Private Link is
an optional, separately configured tenant-level feature; if used, resolve
`management.azure.com` to its private IP through `privatelink.azure.com`.
It does **not** make Microsoft Entra or every resource data plane private;
Microsoft notes that AKS does not support the ARM private endpoint
implementation. [Sources: ARM Private Link; Azure portal FQDNs.](#sources)

## Azure portal (administrative browsers only)

For an admin browsing from a protected VM or jump host, **in addition** to
Entra and ARM, the public-cloud portal needs `portal.azure.com`,
`*.portal.azure.com`, `*.hosting.portal.azure.net`,
`*.hosting-ms.portal.azure.net`, `*.reactblade.portal.azure.net`,
`*.ext.azure.com`, `hosting.partners.azure.net`,
`*.graph.microsoft.com`, and sometimes `*.graph.windows.net` (portal
framework). Its sign-in can also require `login.microsoft.com`,
`login.live.com`, `*.aadcdn.msftauth.net`,
`*.aadcdn.msftauthimages.net`, `*.aadcdn.msauthimages.net`,
`*.logincdn.msftauth.net`, `*.aadcdn.microsoftonline-p.com`, and
`*.microsoftonline-p.com`. These are **not** a requirement for headless
Azure CLI deployments or an app's data-plane calls; the portal has further
account and service-specific dependencies. Use Microsoft's complete
[public-cloud portal list](https://learn.microsoft.com/azure/azure-portal/azure-portal-safelist-urls?tabs=public-cloud)
for a browser-based administration policy. [Source: portal FQDNs.](#sources)

## Virtual Network, private endpoints, and DNS

**Private DNS zone names are not destinations to allowlist.** Clients should
still call the service's normal FQDN; its DNS CNAME chain resolves to a
**private endpoint IP** inside linked VNets. Allow traffic from the client to
that IP on the service's protocol/port, and make custom DNS forwarders resolve
the private zone. Check resolution from the actual VM/pod, not just the NVA.
Do not send private-endpoint traffic to an internet proxy. See the zones in
each service section and [Microsoft's zone reference](#sources).

For Azure-provided DNS, allow `168.63.129.16` on **UDP and TCP 53**, or reach
your custom DNS resolver on both protocols. Azure VM agents also need the
platform WireServer `168.63.129.16` on **TCP 80 and 32526** through the
guest firewall; this virtual address isn't a TLS-bypass FQDN and isn't
subject to user-defined routes. Service tags such as `AzureResourceManager`,
`AzureActiveDirectory`, `AzureMonitor`, and `Storage.<region>` can help with
**IP-based** rules where applicable, but do not replace endpoint-specific DNS
or TLS policy. [Sources: private endpoint DNS; service tags; Azure platform IP.](#sources)

## Azure Service Bus

| Destination | When / why |
| --- | --- |
| `<namespace>.servicebus.windows.net` | Client **data plane**: send/receive queues and topics; allow TCP **5671** for native TLS AMQP, or TCP **443** for HTTPS/AMQP-over-WebSockets when the SDK is configured to use WebSockets. Some AMQP clients also need TCP **5672**; check the client transport. |
| `management.azure.com` | Namespace/entity management via ARM; already listed above. |
| `login.microsoftonline.com` | Client-side Entra token acquisition when used; managed identities can obtain tokens through a platform endpoint. |

For **private** messaging, create a Service Bus **Premium** namespace private
endpoint and link `privatelink.servicebus.windows.net`; keep using the
`<namespace>.servicebus.windows.net` name, now resolving to a private IP.
Allow the selected port to that IP. If public access is used instead, scope an
FQDN rule to the namespace rather than the broader `*.servicebus.windows.net`
suggested for arbitrary namespaces in the Container Apps firewall guide.
An intercepting proxy can cause AMQP TLS handshake failures. Network access
and Service Bus data roles are separate. [Sources: Service Bus Private Link;
AMQP ports/transports; troubleshooting.](#sources)

## Azure Kubernetes Service (AKS)

For a conventional, **non-network-isolated** public-cloud cluster, the AKS
node-subnet egress dependencies below apply even if the workloads themselves
use private endpoints:

| Outbound FQDN (TCP 443) | When / why |
| --- | --- |
| `mcr.microsoft.com`, `*.data.mcr.microsoft.com`, `mcr-0001.mcr-msedge.net` | Microsoft container images and CDN data for cluster creation, scale, and upgrades. |
| `packages.microsoft.com` | Node package repository. |
| `acs-mirror.azureedge.net`, `packages.aks.azure.com` | Kubernetes and Azure CNI binaries; keep both as documented. |
| `management.azure.com`, `login.microsoftonline.com` | Azure APIs and Entra authentication. |
| `*.hcp.<region>.azmk8s.io` | Public-cluster node/API-server Konnectivity traffic when applicable; preserve ALPN (do not rewrite it). **Not** a public egress requirement for a private cluster's private API path. |

For a **private cluster**, allow the cluster's **actual API-server FQDN/IP**
over TCP 443 inside the VNet and resolve its private zone
(`privatelink.<region>.azmk8s.io` or its assigned subzone). This makes the
API path private, **not** registry/package/update egress. AKS
**network-isolated clusters** using a private ACR artifact cache can avoid
public image/bootstrap egress; do not assume an ordinary private AKS cluster
has this property. If routing traffic through an NVA, keep AKS
node-to-node/subnet traffic unblocked and check the documented non-HTTPS
rules: public-cluster tunnel UDP 1194 and TCP 9000 where applicable, and
DNS UDP/TCP 53 to custom DNS. These are **network**, not URL rules.

Add only for enabled features:

| Outbound FQDN (TCP 443) | When / why |
| --- | --- |
| `data.policy.core.windows.net`, `store.policy.core.windows.net`, `dc.services.visualstudio.com` | AKS **Azure Policy add-on**, not the ARM-only governance policies deployed by this repository. |
| `<region>.dp.kubernetesconfiguration.azure.com` | AKS cluster extensions; marketplace extensions and images have further registry/telemetry endpoints in the AKS reference. |
| Key Vault, Azure Monitor, ACR, and application data endpoints below | Secrets Store CSI, Container Insights/Prometheus/Defender, image pulls, and workload-specific services respectively; use private endpoints where supported. |

Windows/GPU node pools and OS package patching have additional conditional
destinations in Microsoft's [AKS outbound rules](#sources); do not apply this
Linux/base list as their complete allowlist. [Sources: AKS outbound rules;
private clusters; network-isolated clusters.](#sources)

## Azure Container Apps

**Workload-profile** environments support full UDRs and firewall-controlled
egress. Legacy Consumption-only environments have limited custom egress
support, additional AKS ports, and other requirements in the
[Container Apps NSG reference](#sources).

| Outbound FQDN (TCP 443) | When / why |
| --- | --- |
| `mcr.microsoft.com`, `*.data.mcr.microsoft.com` | Container Apps system images (all firewall/UDR scenarios). |
| `packages.aks.azure.com`, `acs-mirror.azureedge.net` | Underlying AKS and CNI binaries (all firewall/UDR scenarios). |
| `*.identity.azure.net`, `login.microsoftonline.com`, `*.login.microsoftonline.com`, `*.login.microsoft.com` | Add when **managed identity** is enabled, per the Container Apps firewall guide. |
| `<registry>.azurecr.io`, its configured data endpoints, `login.microsoft.com` | Add when pulling application images from ACR, per the Container Apps firewall guide; see ACR section for storage redirects if dedicated data endpoints are absent. |
| `<vault>.vault.azure.net`, `login.microsoft.com` | Add when the app uses Key Vault, per the Container Apps firewall guide. |
| `<namespace>.servicebus.windows.net` | Add when app code connects to Service Bus; use its configured data-plane port (see above). |
| `<region>.ext.azurecontainerapps.dev` | Only for the **Aspire dashboard** in a VNet environment. |

For **private inbound access to the app**, use an internal environment or a
workload-profile environment with a private endpoint. Allow the app's
**actual Application URL** on TCP 443 to its private VIP/private endpoint;
the private endpoint DNS zone is
`privatelink.<region>.azurecontainerapps.io`. This controls **ingress** and
does not make its outbound calls private. Portal log streaming/console can
add `azurecontainerapps.dev` on an administrative browser, not a generic
runtime requirement. [Sources: Container Apps firewall; networking; private
endpoint DNS.](#sources)

## Azure Container Registry (ACR)

| Outbound FQDN (TCP 443) | When / why |
| --- | --- |
| `<registry>.azurecr.io` | Registry login and manifest API. |
| `<registry>.<region>.data.azurecr.io` | Layer downloads when dedicated data endpoints/private endpoints are enabled; enumerate each configured region. |
| `<registry>.<region>.geo.azurecr.io` | Only if the client uses enabled regional/geo-replica login endpoints. |
| `*.blob.core.windows.net` | Blob redirects **only** if neither dedicated data endpoints nor private endpoints are used; prefer enabling dedicated data endpoints rather than allowing all storage accounts. |

Use `az acr show-endpoints --name <registry> --resource-group <resource-group>`
to discover actual endpoints. For private access, ACR **Premium** supports a
private endpoint with DNS zone `privatelink.azurecr.io` (including regional
data records). Ensure **both** login and layer-data names resolve privately.
Application workloads may also need Entra token access; see Entra/Container
Apps sections. [Sources: ACR endpoint reference; private endpoints.](#sources)

## Azure Storage

| Outbound FQDN (usual data-plane port) | When / why |
| --- | --- |
| `<account>.blob.core.windows.net` (TCP 443) | Blob objects. |
| `<account>.dfs.core.windows.net` (TCP 443) | ADLS Gen2; some operations also require the Blob endpoint. |
| `<account>.queue.core.windows.net`, `<account>.table.core.windows.net` (TCP 443) | Queue and Table data, respectively. |
| `<account>.file.core.windows.net` (TCP 443 for REST; TCP 445 for SMB) | Azure Files: choose port by client protocol; SMB is **not** HTTPS/TLS inspection. |
| `<account>.web.core.windows.net` (TCP 443) | Static website only if used. |

Each used storage subresource needs its **own** private endpoint and DNS zone,
for example `privatelink.blob.core.windows.net`,
`privatelink.dfs.core.windows.net`, `privatelink.queue.core.windows.net`,
`privatelink.table.core.windows.net`, and
`privatelink.file.core.windows.net`. Keep the normal account FQDN in the
client connection string, pointing to the private IP; don't use the
`privatelink` name as the URL. Disabling public network access separately
prevents public fallback. [Sources: Storage private endpoints; private
endpoint DNS.](#sources)

## Azure Key Vault

`<vault>.vault.azure.net` on TCP 443 is the **data-plane** host for secrets,
keys, and certificates. If using a vault private endpoint, configure
`privatelink.vaultcore.azure.net` and confirm the **normal** vault FQDN
resolves to its private IP. `management.azure.com` covers vault ARM
operations, not secret access. Entra authentication can require its own
outbound path; for Container Apps, see its additional identity rules above.
This repo refers to existing customer-managed-key vault URIs, but does not
create a vault. [Sources: Key Vault Private Link; private endpoint DNS.](#sources)

## Azure Monitor, Log Analytics, and Microsoft Sentinel

Creating a Log Analytics workspace or enabling Sentinel via this repository
uses **ARM**, not a client data-plane endpoint. Direct VM/AKS **Azure Monitor
Agent (AMA)** ingestion, custom telemetry, and queries are separate:

| Outbound FQDN (TCP 443) | When / why |
| --- | --- |
| `global.handler.control.monitor.azure.com`, `<vm-region>.handler.control.monitor.azure.com` | AMA control and data collection rules. |
| `global.prod.microsoftmetrics.com` | AMA metrics service. |
| `<workspace-id>.ods.opinsights.azure.com` | AMA/Log Analytics log ingestion, when using public endpoints. |
| `<dce>.<vm-region>.ingest.monitor.azure.com` | Data collection endpoint ingestion, when configured. |
| `<vm-region>.monitoring.azure.com` | AMA **custom metrics only**, when configured. |
| `api.loganalytics.azure.com` | **Only** for applications querying Log Analytics through its REST API; older clients may use `api.loganalytics.io`. |

Microsoft explicitly says **disable HTTPS inspection** for AMA firewall
endpoints. For private AMA traffic, configure an **Azure Monitor Private Link
Scope (AMPLS)** with its resources and private data collection endpoints;
the agent documentation says to use **only private DCEs** rather than the
public AMA endpoints above. AMPLS DNS includes
`privatelink.monitor.azure.com`,
`privatelink.ods.opinsights.azure.com`, and
`privatelink.oms.opinsights.azure.com` (among others); allow resolved
private IPs, not these zone suffixes as destination URLs. Resource-specific
ingestion and shared query endpoints differ. Diagnostic-settings export from
an Azure resource is service-to-service: do not assume the exporter traverses
your VM's NVA. [Sources: AMA network configuration; Azure Monitor Private Link;
Log Analytics API.](#sources)

## Azure Backup and Recovery Services vaults

Creating the vault/backup policy uses ARM. **VM backup/restore data** is
separate: with a vault Azure Backup private endpoint, let protected VMs reach
the **actual backup, Blob, and Queue FQDNs** recorded on the vault's private
endpoint DNS configuration over TCP 443, resolved to private IPs. Configure
the private DNS zones
`privatelink.<geo>.backup.windowsazure.com`,
`privatelink.blob.core.windows.net`, and
`privatelink.queue.core.windows.net`; `<geo>` is the Azure Backup geo code,
not necessarily the region name. New storage/DNS records can appear after
registration or the first backup, so recheck the endpoint's DNS configuration.
VMs also need Entra access. A private endpoint alone does not make a
previously protected vault eligible for this configuration; follow the
vault's documented prerequisites.

For **public** Azure Backup traffic instead of private endpoints, use the
`AzureBackup`, `Storage`, and `AzureActiveDirectory` service tags where
supported, plus the required HTTPS-inspection policy for the actual agent
endpoints. Don't mistake the `privatelink` zone names for public URLs to
allowlist. [Sources: Azure Backup private endpoints; service tags; private
endpoint DNS.](#sources)

## Sources

- [Azure portal public-cloud URLs](https://learn.microsoft.com/azure/azure-portal/azure-portal-safelist-urls?tabs=public-cloud)
  and [Microsoft 365 authentication endpoint sets 56/59](https://learn.microsoft.com/microsoft-365/enterprise/urls-and-ip-address-ranges?view=o365-worldwide#microsoft-365-common-and-office-online)
- [Microsoft Graph API endpoint](https://learn.microsoft.com/graph/use-the-api)
- [ARM Private Link](https://learn.microsoft.com/azure/azure-resource-manager/management/create-private-link-access-portal)
  and [Azure service tags](https://learn.microsoft.com/azure/virtual-network/service-tags-overview)
- [Private endpoint DNS zones](https://learn.microsoft.com/azure/private-link/private-endpoint-dns)
  and [Azure platform IP `168.63.129.16`](https://learn.microsoft.com/azure/virtual-network/what-is-ip-address-168-63-129-16)
- [Service Bus Private Link](https://learn.microsoft.com/azure/service-bus-messaging/private-link-service),
  [AMQP/WebSockets](https://learn.microsoft.com/azure/service-bus-messaging/service-bus-amqp-overview),
  and [connectivity troubleshooting](https://learn.microsoft.com/azure/service-bus-messaging/service-bus-troubleshooting-guide)
- [AKS outbound dependencies and optional add-ons](https://learn.microsoft.com/azure/aks/outbound-rules-control-egress),
  [private clusters](https://learn.microsoft.com/azure/aks/private-clusters),
  and [network-isolated clusters](https://learn.microsoft.com/azure/aks/concepts-network-isolated)
- [Container Apps firewall FQDNs](https://learn.microsoft.com/azure/container-apps/use-azure-firewall),
  [NSG rules](https://learn.microsoft.com/azure/container-apps/firewall-integration),
  and [networking/ingress](https://learn.microsoft.com/azure/container-apps/networking)
- [ACR endpoint reference](https://learn.microsoft.com/azure/container-registry/container-registry-endpoint-reference)
  and [ACR Private Link](https://learn.microsoft.com/azure/container-registry/container-registry-private-endpoints)
- [Azure Storage private endpoints](https://learn.microsoft.com/azure/storage/common/storage-private-endpoints)
  and [Key Vault Private Link](https://learn.microsoft.com/azure/key-vault/general/private-link-service)
- [Azure Monitor Agent network configuration](https://learn.microsoft.com/azure/azure-monitor/agents/azure-monitor-agent-network-configuration),
  [Azure Monitor Private Link](https://learn.microsoft.com/azure/azure-monitor/fundamentals/private-link-security),
  and [Log Analytics REST API](https://learn.microsoft.com/azure/azure-monitor/logs/api/access-api)
- [Azure Backup private endpoints](https://learn.microsoft.com/azure/backup/backup-azure-private-endpoints-configure-manage)

The starting list came from the September 23, 2026 **Fix Azure CLI Login
Error** session: an NVA's SSL-inspection certificate prevented Azure CLI
authentication. These sources extend that narrow answer to distinct Azure
control/data-plane and private-network scenarios; review them when enabling
new workloads because endpoint requirements change.
