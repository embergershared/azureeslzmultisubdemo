#!/usr/bin/env python3
"""Check ARM policy contracts that the Bicep compiler treats as opaque strings."""

import copy
import json
import re
import sys


def require(condition, message):
    if not condition:
        raise ValueError(message)


def resources(template):
    items = template.get("resources", {})
    return list(items.values()) if isinstance(items, dict) else items


def strings(value):
    if isinstance(value, str):
        yield value
    elif isinstance(value, dict):
        for child in value.values():
            yield from strings(child)
    elif isinstance(value, list):
        for child in value:
            yield from strings(child)


def check_expression(expression, context):
    unquoted = re.sub(r"'(?:''|[^'])*'", "''", expression)
    depth = 0
    for character in unquoted:
        if character == "(":
            depth += 1
        elif character == ")":
            depth -= 1
        require(depth >= 0, f"{context}: unbalanced policy expression parentheses")
    require(depth == 0, f"{context}: unbalanced policy expression parentheses")
    require(
        not re.search(r"\b(?:true|false)\b(?!\s*\()", unquoted, re.I),
        f"{context}: bare boolean in policy expression",
    )


def check_deployment_names(template, ancestor_names=()):
    for resource in resources(template):
        if resource["type"] != "Microsoft.Resources/deployments":
            continue
        same_scope = not any(key in resource for key in ("scope", "subscriptionId", "resourceGroup"))
        names = ancestor_names if same_scope else ()
        name = resource["name"]
        require(name not in names, f"{name}: nested deployment name collides with an active ancestor at the same scope")
        check_deployment_names(resource["properties"]["template"], (*names, name))


def check_available_versions(template):
    for resource in resources(template):
        if resource["type"] in (
            "Microsoft.Authorization/policyDefinitions",
            "Microsoft.Authorization/policySetDefinitions",
        ):
            properties = resource["properties"]
            require(
                properties.get("versions") == [properties["version"]],
                f"{resource['name']}: available versions must match the demo's published version",
            )
        elif resource["type"] == "Microsoft.Resources/deployments":
            check_available_versions(resource["properties"]["template"])


def check(template):
    check_deployment_names(template)
    modules = template["resources"]
    library = modules["policyLibrary"]["properties"]["template"]
    definitions = resources(library)
    for definition in definitions:
        properties = definition["properties"]
        require(
            properties.get("version") == properties["metadata"]["version"],
            f"{definition['name']}: custom policy version must match metadata",
        )
        rule = properties["policyRule"]
        declared = set(properties.get("parameters", {}))
        used = set()
        for expression in strings(rule):
            if not expression.startswith("[["):
                continue
            used.update(re.findall(r"parameters\('([^']+)'\)", expression))
            check_expression(expression, definition["name"])
        require(
            declared == used,
            f"{definition['name']}: unused/undeclared policy parameters: "
            f"{sorted(declared ^ used)}",
        )

    def reaches_hierarchy(name, seen=None):
        if name == "hierarchy":
            return True
        seen = set() if seen is None else seen
        if name in seen:
            return False
        seen.add(name)
        return any(
            reaches_hierarchy(dependency, seen)
            for dependency in modules.get(name, {}).get("dependsOn", [])
        )

    for name, module in modules.items():
        parameters = module.get("properties", {}).get("parameters", {})
        bindings = parameters.get("policyDefinitionReferences", {}).get("value", [])
        if isinstance(bindings, list):
            bindings = list(bindings)
            if "policyDefinitionId" in parameters:
                bindings.append({key: value["value"] for key, value in parameters.items()})
            for binding in bindings:
                target = re.fullmatch(
                    r"\[reference\('([^']+)'\)\.outputs\.\w+\.value\]",
                    binding["policyDefinitionId"],
                )
                if target and (target[1] == "policyLibrary" or target[1].endswith("Initiative")):
                    version = (
                        definitions[0]["properties"]["version"]
                        if target[1] == "policyLibrary"
                        else modules[target[1]]["properties"]["parameters"]["initiativeVersion"]["value"]
                    )
                    require(
                        binding.get("definitionVersion") == f"{version.split('.')[0]}.*.*",
                        f"{name}: custom definition must pin its declared major version",
                    )
        if "Microsoft.Management/managementGroups" in module.get("scope", ""):
            require(reaches_hierarchy(name), f"{name}: missing hierarchy dependency")
        for resource in resources(module.get("properties", {}).get("template", {})):
            if resource["type"] != "Microsoft.Authorization/policySetDefinitions":
                continue
            properties = resource["properties"]
            require(
                "copy" not in properties
                and properties.get("policyDefinitions", "").startswith(
                    "[map(variables('validatedPolicyDefinitionReferences'), lambda("
                ),
                f"{name}: initiative must avoid policyDefinitions property-copy re-evaluation",
            )
            parameters = module["properties"]["parameters"]
            declared = (
                parameters["initiativeParameters"]["value"]
                if "initiativeParameters" in parameters
                else module["properties"]["template"]["parameters"]["initiativeParameters"]["defaultValue"]
            )
            for expression in strings(parameters["policyDefinitionReferences"]["value"]):
                if expression.startswith("[["):
                    check_expression(expression, name)
                    for parameter in re.findall(r"parameters\('([^']+)'\)", expression):
                        require(parameter in declared, f"{name}: undeclared initiative parameter {parameter}")

    for name in (
        "defenderCspmAssignment",
        "defenderForServersAssignment",
        "defenderForStorageAssignment",
    ):
        module = modules[name]
        nested = resources(module["properties"]["template"])
        assignment = next(r for r in nested if r["type"].endswith("/policyAssignments"))
        require(assignment["identity"]["type"] == "SystemAssigned", f"{name}: identity required")
        require(
            assignment["properties"]["parameters"]
            == "[union(createObject('effect', createObject('value', if(parameters('enablePlan'), 'DeployIfNotExists', 'Disabled'))), variables('planParameters')[parameters('plan')])]",
            f"{name}: paid effect must require opt-in",
        )
        require(len(nested) == 1, f"{name}: must not grant roles or deploy paid resources")
        opt_in = module["properties"]["parameters"]["enablePlan"]["value"]
        parameter = re.fullmatch(r"\[parameters\('([^']+)'\)\]", opt_in).group(1)
        require(template["parameters"][parameter]["defaultValue"] is False, f"{name}: unsafe default")

    for name in (
        "activityLogExportAssignment",
        "resourceDiagnosticsAssignment",
        "vaultDiagnosticsAuditAssignment",
    ):
        module = modules[name]
        parameters = module["properties"]["parameters"]
        require(parameters["identity"]["value"] == {"type": "SystemAssigned"}, f"{name}: identity required")
        require(parameters["location"]["value"] == "[parameters('deploymentLocation')]", f"{name}: location required")
        require(parameters["deployRemediationRoleAssignments"]["value"] is False, f"{name}: must not grant roles")
        nested = resources(module["properties"]["template"])
        assignment = next(r for r in nested if r["type"].endswith("/policyAssignments"))
        require(
            "createObject('type', parameters('identity').type)" in assignment["identity"],
            f"{name}: identity not attached",
        )
        for resource in nested:
            if resource is not assignment and not resource.get("existing", False):
                require(
                    resource.get("condition") == "[parameters('deployRemediationRoleAssignments')]",
                    f"{name}: remediation deployment must be gated",
                )

    firewall = next(d for d in definitions if "audit-approved-firewall-routes" in d["name"])
    contract = firewall["properties"]["parameters"]
    require(contract["effect"]["defaultValue"] == "Audit", "Firewall route effect must default to Audit")
    require(contract["effect"]["allowedValues"] == ["Audit", "Disabled"], "Firewall route effect must remain audit-only")
    for name in ("firewallRouteWorkloadAssignment", "firewallRouteCriticalAssignment", "nercCipTechnicalOverlayAssignment"):
        parameters = modules[name]["properties"]["parameters"]
        require(
            parameters["metadata"]["value"]["approvedFirewallResourceId"]
            == "[parameters('approvedFirewallResourceId')]",
            f"{name}: firewall evidence missing from metadata",
        )
        require("approvedFirewallResourceId" not in parameters["parameters"]["value"], f"{name}: unused policy parameter")
    references = modules["nercCipTechnicalOverlayInitiative"]["properties"]["parameters"]["policyDefinitionReferences"]["value"]
    member = next(r for r in references if r["policyDefinitionReferenceId"] == "critical-approved-firewall-routes")
    require(set(member["parameters"]) == set(contract), "NERC firewall member must match the definition contract")
    root_initiative = modules["rootDeploymentRestrictions"]["properties"]["template"]["resources"]["initiative"]
    for reference in root_initiative["properties"]["parameters"]["policyDefinitionReferences"]["value"]:
        require(
            reference.get("definitionVersion") == "1.*.*",
            "Root deployment-restrictions references must pin their verified major versions",
        )
    check_available_versions(template)


def main():
    with open(sys.argv[1], encoding="utf-8-sig") as stream:
        template = json.load(stream)
    check(template)

    # Prove each reported failure is rejected, not just that today's template passes.
    def remove_identity(candidate):
        assignment = candidate["resources"]["defenderCspmAssignment"]["properties"]["template"]["resources"]["assignment"]
        assignment["identity"]["type"] = "None"

    def bare_boolean(candidate):
        library = candidate["resources"]["policyLibrary"]["properties"]["template"]
        definition = next(d for d in resources(library) if "public-mgmt-ingress" in d["name"])
        definition["properties"]["policyRule"]["if"] = {"value": "[[if(true(), false, true())]", "equals": True}

    def unused_parameter(candidate):
        library = candidate["resources"]["policyLibrary"]["properties"]["template"]
        resources(library)[0]["properties"]["parameters"]["unused"] = {"type": "String"}

    def missing_dependency(candidate):
        candidate["resources"]["backupPostureInitiative"]["dependsOn"] = []

    def unwanted_roles(candidate):
        candidate["resources"]["activityLogExportAssignment"]["properties"]["parameters"]["deployRemediationRoleAssignments"]["value"] = True

    def extra_parenthesis(candidate):
        library = candidate["resources"]["policyLibrary"]["properties"]["template"]
        definition = next(d for d in resources(library) if "public-mgmt-ingress" in d["name"])
        definition["properties"]["policyRule"]["if"] = {"value": "[[if(true(), false(), true()))]", "equals": True}

    def missing_parenthesis(candidate):
        library = candidate["resources"]["policyLibrary"]["properties"]["template"]
        definition = next(d for d in resources(library) if "public-mgmt-ingress" in d["name"])
        definition["properties"]["policyRule"]["if"] = {"value": "[[if(true(), false(), true()]", "equals": True}

    def initiative_property_copy(candidate):
        initiative = candidate["resources"]["backupPostureInitiative"]["properties"]["template"]["resources"]["initiative"]
        initiative["properties"]["copy"] = [{"name": "policyDefinitions", "count": 1, "input": {}}]
        del initiative["properties"]["policyDefinitions"]

    def undeclared_initiative_parameter(candidate):
        parameters = candidate["resources"]["backupPostureInitiative"]["properties"]["parameters"]
        parameters["policyDefinitionReferences"]["value"][0]["parameters"]["effect"]["value"] = "[[parameters('missingEffect')]"

    def colliding_deployment(candidate):
        wrapper = candidate["resources"]["rootDeploymentRestrictions"]
        wrapper["properties"]["template"]["resources"]["initiative"]["name"] = wrapper["name"]

    def missing_custom_version(candidate):
        library = candidate["resources"]["policyLibrary"]["properties"]["template"]
        del resources(library)[0]["properties"]["version"]

    def missing_custom_pin(candidate):
        del candidate["resources"]["backupPostureAssignment"]["properties"]["parameters"]["definitionVersion"]

    def missing_available_versions(candidate):
        library = candidate["resources"]["policyLibrary"]["properties"]["template"]
        del resources(library)[0]["properties"]["versions"]

    def missing_root_builtin_pin(candidate):
        initiative = candidate["resources"]["rootDeploymentRestrictions"]["properties"]["template"]["resources"]["initiative"]
        del initiative["properties"]["parameters"]["policyDefinitionReferences"]["value"][0]["definitionVersion"]

    for mutate, expected in (
        (remove_identity, "identity required"),
        (bare_boolean, "bare boolean"),
        (unused_parameter, "unused/undeclared"),
        (missing_dependency, "missing hierarchy"),
        (unwanted_roles, "must not grant roles"),
        (extra_parenthesis, "unbalanced policy expression"),
        (missing_parenthesis, "unbalanced policy expression"),
        (initiative_property_copy, "property-copy re-evaluation"),
        (undeclared_initiative_parameter, "undeclared initiative parameter"),
        (colliding_deployment, "nested deployment name collides"),
        (missing_custom_version, "custom policy version must match"),
        (missing_custom_pin, "custom definition must pin"),
        (missing_available_versions, "available versions must match"),
        (missing_root_builtin_pin, "Root deployment-restrictions references must pin"),
    ):
        candidate = copy.deepcopy(template)
        mutate(candidate)
        try:
            check(candidate)
        except ValueError as error:
            require(expected in str(error), f"{mutate.__name__}: unexpected failure: {error}")
            continue
        raise ValueError(f"Regression fixture unexpectedly passed: {mutate.__name__}")
    print("Deployment contracts and fourteen negative regression fixtures passed.")


if __name__ == "__main__":
    try:
        main()
    except ValueError as error:
        sys.exit(f"ERROR: {error}")
