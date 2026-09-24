# Azure TLS Inspection Bypass List

Use this minimal list to bypass TLS/SSL inspection for Azure CLI authentication
and Azure Resource Manager operations in the Azure public cloud. Allow outbound
TCP 443 and preserve the original Microsoft certificate chain.

| FQDN | Purpose |
| --- | --- |
| `login.microsoftonline.com` | Primary Microsoft Entra sign-in and token endpoint used by Azure CLI. |
| `*.microsoftonline.com` | Supporting Microsoft Entra authentication, tenant, and identity endpoints. |
| `*.msauth.net` | Microsoft authentication content and browser-based sign-in dependencies. |
| `*.msftauth.net` | Microsoft authentication CDN content used during interactive sign-in. |
| `management.azure.com` | Azure Resource Manager API used by Azure CLI to read and manage Azure resources after authentication. |

## NVA configuration notes

- Configure these FQDNs as a **TLS-decryption/SSL-inspection bypass**, not only
  as a firewall allowlist. The original failure occurred because the NVA
  replaced the Microsoft certificate.
- If the NVA does not support wildcard matching, resolve the required
  subdomains from its traffic logs and add explicit entries. Do not replace
  Microsoft-documented exact names with broader wildcards.
- Do not use `AZURE_CLI_DISABLE_CONNECTION_VERIFICATION=1` as a fix. It disables
  server-certificate verification and is suitable only for short-lived
  diagnostics.
- This is a minimal Azure CLI list, not a complete list for the Azure portal or
  every Azure service. Add service-specific endpoints from Microsoft's
  documentation when the workflow uses services such as Key Vault, Storage, or
  Log Analytics.

## Sources

- [Allow the Azure portal URLs on your firewall or proxy server](https://learn.microsoft.com/azure/azure-portal/azure-portal-safelist-urls?tabs=public-cloud) -
  identifies the public-cloud authentication endpoints and
  `management.azure.com`, and explains proxy/firewall bypass requirements.
- [Microsoft 365 URLs and IP address ranges](https://learn.microsoft.com/microsoft-365/enterprise/urls-and-ip-address-ranges?view=o365-worldwide#microsoft-365-common-and-office-online) -
  endpoint sets 56 and 59 document the Microsoft Entra and authentication
  wildcard domains, including `*.microsoftonline.com`, `*.msauth.net`, and
  `*.msftauth.net`.
- [Troubleshooting Azure CLI](https://learn.microsoft.com/cli/azure/use-azure-cli-successfully-troubleshooting?view=azure-cli-latest) -
  its debug example shows Azure CLI making HTTPS requests to
  `management.azure.com`.

This list was derived from the September 23, 2026 session **Fix Azure CLI Login
Error**, where an NVA SSL-inspection certificate was identified as the cause.
