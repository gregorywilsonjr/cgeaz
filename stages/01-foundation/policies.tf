# Six policies (three from the course starter, three of my own), one initiative, assigned once at mg-grc-sandbox.
# Every subscription that ever joins the sandbox group inherits all of it. (CSF: GV.PO, PR.DS, PR.PS)

# --- 1. Require the `env` tag on resource groups (inventory hygiene; POA&M owner resolution) ---

resource "azurerm_policy_definition" "require_env_tag" {
  name                = "cge-require-env-tag-rg"
  display_name        = "Resource groups must carry an env tag"
  policy_type         = "Custom"
  mode                = "All"
  management_group_id = azurerm_management_group.sandbox.id

  parameters = jsonencode({
    effect = {
      type          = "String"
      allowedValues = ["Audit", "Deny", "Disabled"]
      defaultValue  = "Audit"
    }
  })

  policy_rule = jsonencode({
    if = {
      allOf = [
        { field = "type", equals = "Microsoft.Resources/subscriptions/resourceGroups" },
        { field = "tags['env']", exists = "false" }
      ]
    }
    then = { effect = "[parameters('effect')]" }
  })
}

# --- 2. Deny public blob access on storage accounts (clear-cut, framework-mandated: earned Deny) ---
# blast radius: refuses any create or update that would leave a storage account under mg-grc-sandbox open to
# public blob access, including Terraform and CLI changes; it changes nothing that already exists.
# rollback: set public_blob_policy_effect to "Audit" in a reviewed PR and apply. (CSF: PR.DS)

resource "azurerm_policy_definition" "deny_public_blob" {
  name                = "cge-deny-public-blob"
  display_name        = "Storage accounts must not allow public blob access"
  policy_type         = "Custom"
  mode                = "Indexed"
  management_group_id = azurerm_management_group.sandbox.id

  parameters = jsonencode({
    effect = {
      type          = "String"
      allowedValues = ["Audit", "Deny", "Disabled"]
      defaultValue  = "Deny"
    }
  })

  policy_rule = jsonencode({
    if = {
      allOf = [
        { field = "type", equals = "Microsoft.Storage/storageAccounts" },
        { field = "Microsoft.Storage/storageAccounts/allowBlobPublicAccess", equals = "true" }
      ]
    }
    then = { effect = "[parameters('effect')]" }
  })
}

# --- 3. deployIfNotExists: storage accounts missing diagnostic settings get them, routed to the GRC workspace ---
# Logging that enforces its own coverage. Remediation runs AS the identity in identity.tf.
# blast radius: creates one diagnostic setting (ds-to-grc-workspace) on any storage account under mg-grc-sandbox
# that lacks one, as the remediation identity; it never modifies or deletes anything else.
# rollback: remove this definition from the initiative in a reviewed PR and apply; settings it created stay.

resource "azurerm_policy_definition" "storage_diagnostics" {
  name                = "cge-dine-storage-diagnostics"
  display_name        = "Storage accounts must route diagnostics to the GRC workspace"
  policy_type         = "Custom"
  mode                = "Indexed"
  management_group_id = azurerm_management_group.sandbox.id

  parameters = jsonencode({
    workspaceId = {
      type     = "String"
      metadata = { displayName = "Log Analytics workspace resource ID" }
    }
  })

  policy_rule = jsonencode({
    if = {
      field  = "type"
      equals = "Microsoft.Storage/storageAccounts"
    }
    then = {
      effect = "DeployIfNotExists"
      details = {
        type = "Microsoft.Insights/diagnosticSettings"
        roleDefinitionIds = [
          # Monitoring Contributor
          "/providers/Microsoft.Authorization/roleDefinitions/749f88d5-cbae-40b8-bcfc-e573ddc772fa"
        ]
        existenceCondition = {
          allOf = [
            { field = "Microsoft.Insights/diagnosticSettings/workspaceId", equals = "[parameters('workspaceId')]" }
          ]
        }
        deployment = {
          properties = {
            mode = "incremental"
            parameters = {
              resourceName = { value = "[field('name')]" }
              workspaceId  = { value = "[parameters('workspaceId')]" }
              location     = { value = "[field('location')]" }
            }
            template = {
              "$schema"      = "https://schema.management.azure.com/schemas/2015-01-01/deploymentTemplate.json#"
              contentVersion = "1.0.0.0"
              parameters = {
                resourceName = { type = "string" }
                workspaceId  = { type = "string" }
                location     = { type = "string" }
              }
              resources = [
                {
                  type       = "Microsoft.Storage/storageAccounts/providers/diagnosticSettings"
                  apiVersion = "2021-05-01-preview"
                  name       = "[concat(parameters('resourceName'), '/Microsoft.Insights/ds-to-grc-workspace')]"
                  properties = {
                    workspaceId = "[parameters('workspaceId')]"
                    metrics = [
                      { category = "Transaction", enabled = true }
                    ]
                  }
                }
              ]
            }
          }
        }
      }
    }
  })
}

# --- 4. (My addition) Cosmos DB accounts must not accept key-based access ---
# The evidence store is identity-only by design; this turns that one-time setting into a watched control.
# Rule mirrors Microsoft's built-in "Cosmos DB database accounts should have local authentication methods disabled".
# blast radius: Audit flags only. At Deny, blocks creating or updating any Cosmos account under mg-grc-sandbox
# that accepts keys; it cannot read data or change existing accounts.
# rollback: set cosmos_auth_policy_effect back to "Audit" in a reviewed PR and apply. (CSF: PR.AA, PR.DS)

resource "azurerm_policy_definition" "cosmos_local_auth" {
  name                = "cge-cosmos-disable-local-auth"
  display_name        = "Cosmos DB accounts must disable key-based (local) authentication"
  policy_type         = "Custom"
  mode                = "Indexed"
  management_group_id = azurerm_management_group.sandbox.id

  parameters = jsonencode({
    effect = {
      type          = "String"
      allowedValues = ["Audit", "Deny", "Disabled"]
      defaultValue  = "Audit"
    }
  })

  policy_rule = jsonencode({
    if = {
      allOf = [
        { field = "type", equals = "Microsoft.DocumentDB/databaseAccounts" },
        { field = "Microsoft.DocumentDB/databaseAccounts/disableLocalAuth", notEquals = true },
        # Mongo, Cassandra and Gremlin accounts handle this setting differently (same exclusion as the built-in).
        { field = "Microsoft.DocumentDB/databaseAccounts/capabilities[*].name", notIn = ["EnableMongo", "EnableCassandra", "EnableGremlin"] }
      ]
    }
    then = { effect = "[parameters('effect')]" }
  })
}

# --- 5. (My addition) Resource groups must name an accountable owner ---
# The POA&M's Owner column is meant to resolve from this tag, so a missing tag means an unowned finding.
# blast radius: Audit flags only. At Deny, blocks creating or updating a resource group under mg-grc-sandbox
# without a non-empty owner tag; it never touches the resources inside.
# rollback: set owner_tag_policy_effect back to "Audit" in a reviewed PR and apply. (CSF: GV.RR, ID.AM)

resource "azurerm_policy_definition" "require_owner_tag" {
  name                = "cge-require-owner-tag-rg"
  display_name        = "Resource groups must carry a non-empty owner tag"
  policy_type         = "Custom"
  mode                = "All"
  management_group_id = azurerm_management_group.sandbox.id

  parameters = jsonencode({
    effect = {
      type          = "String"
      allowedValues = ["Audit", "Deny", "Disabled"]
      defaultValue  = "Audit"
    }
  })

  policy_rule = jsonencode({
    if = {
      allOf = [
        { field = "type", equals = "Microsoft.Resources/subscriptions/resourceGroups" },
        {
          anyOf = [
            { field = "tags['owner']", exists = "false" },
            { field = "tags['owner']", equals = "" }
          ]
        }
      ]
    }
    then = { effect = "[parameters('effect')]" }
  })
}

# --- 6. (My addition) Storage accounts must require TLS 1.2 or newer ---
# Evidence, reports and Terraform state all travel to storage accounts. Azure Storage has refused TLS 1.0/1.1
# platform-wide since 2026-02-03, so this checks each account's DECLARED minimum: configuration an auditor can
# verify, instead of a platform default.
# Differs from Microsoft's built-in on purpose: the built-in flags anything not EXACTLY TLS1_2, which would
# wrongly flag a stricter TLS1_3 minimum. This rule flags only versions below 1.2, or no minimum set at all.
# Earned Deny: every storage account passed at Audit first, and the one finding was closed before the switch.
# blast radius: refuses creating any storage account under mg-grc-sandbox that doesn't declare TLS 1.2 or newer
# (for example, az storage account create without --min-tls-version), and any update that would lower it.
# Updates to accounts that already comply still go through. It changes nothing that already exists.
# rollback: set storage_tls_policy_effect back to "Audit" in a reviewed PR and apply. (CSF: PR.DS)

resource "azurerm_policy_definition" "storage_min_tls" {
  name                = "cge-storage-min-tls12"
  display_name        = "Storage accounts must require TLS 1.2 or newer"
  policy_type         = "Custom"
  mode                = "Indexed"
  management_group_id = azurerm_management_group.sandbox.id

  parameters = jsonencode({
    effect = {
      type          = "String"
      allowedValues = ["Audit", "Deny", "Disabled"]
      defaultValue  = "Audit"
    }
  })

  policy_rule = jsonencode({
    if = {
      allOf = [
        { field = "type", equals = "Microsoft.Storage/storageAccounts" },
        {
          anyOf = [
            { field = "Microsoft.Storage/storageAccounts/minimumTlsVersion", "in" = ["TLS1_0", "TLS1_1"] },
            { field = "Microsoft.Storage/storageAccounts/minimumTlsVersion", exists = "false" }
          ]
        }
      ]
    }
    then = { effect = "[parameters('effect')]" }
  })
}

# --- The initiative: one assignment, whole-sandbox inheritance ---

resource "azurerm_management_group_policy_set_definition" "grc_baseline" {
  name                = "cge-grc-baseline"
  display_name        = "CGE-AZ GRC Baseline"
  policy_type         = "Custom"
  management_group_id = azurerm_management_group.sandbox.id

  parameters = jsonencode({
    tagEffect        = { type = "String", defaultValue = "Audit" }
    publicBlobEffect = { type = "String", defaultValue = "Deny" }
    workspaceId      = { type = "String" }
    cosmosAuthEffect = { type = "String", defaultValue = "Audit" }
    ownerTagEffect   = { type = "String", defaultValue = "Audit" }
    storageTlsEffect = { type = "String", defaultValue = "Audit" }
  })

  policy_definition_reference {
    policy_definition_id = azurerm_policy_definition.require_env_tag.id
    parameter_values = jsonencode({
      effect = { value = "[parameters('tagEffect')]" }
    })
  }

  policy_definition_reference {
    policy_definition_id = azurerm_policy_definition.deny_public_blob.id
    parameter_values = jsonencode({
      effect = { value = "[parameters('publicBlobEffect')]" }
    })
  }

  policy_definition_reference {
    policy_definition_id = azurerm_policy_definition.storage_diagnostics.id
    parameter_values = jsonencode({
      workspaceId = { value = "[parameters('workspaceId')]" }
    })
  }

  policy_definition_reference {
    policy_definition_id = azurerm_policy_definition.cosmos_local_auth.id
    parameter_values = jsonencode({
      effect = { value = "[parameters('cosmosAuthEffect')]" }
    })
  }

  policy_definition_reference {
    policy_definition_id = azurerm_policy_definition.require_owner_tag.id
    parameter_values = jsonencode({
      effect = { value = "[parameters('ownerTagEffect')]" }
    })
  }

  policy_definition_reference {
    policy_definition_id = azurerm_policy_definition.storage_min_tls.id
    parameter_values = jsonencode({
      effect = { value = "[parameters('storageTlsEffect')]" }
    })
  }
}

resource "azurerm_management_group_policy_assignment" "grc_baseline" {
  name                 = "cge-grc-baseline"
  display_name         = "CGE-AZ GRC Baseline"
  policy_definition_id = azurerm_management_group_policy_set_definition.grc_baseline.id
  management_group_id  = azurerm_management_group.sandbox.id
  location             = var.location

  parameters = jsonencode({
    tagEffect        = { value = var.tag_policy_effect }
    publicBlobEffect = { value = var.public_blob_policy_effect }
    workspaceId      = { value = azurerm_log_analytics_workspace.grc.id }
    cosmosAuthEffect = { value = var.cosmos_auth_policy_effect }
    ownerTagEffect   = { value = var.owner_tag_policy_effect }
    storageTlsEffect = { value = var.storage_tls_policy_effect }
  })

  # Remediation effects (deployIfNotExists) execute AS this identity.
  # Without this block, Terraform applies cleanly and remediation silently never runs.
  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.remediation.id]
  }
}
