# Detector 2 of 2, as code. Detector 1 (drift) asks whether Azure still matches the
# repo; this one asks who changed Azure at all. Both halves were manual before: the
# routing came from labs/02-toolkit/route-activity-log.sh, outside state and drift
# detection, and the caller query ran only when someone ran it.

# Subscription-level control-plane activity into the GRC workspace. Adopted with
# `terraform import` from the diagnostic setting route-activity-log.sh created; the four
# categories below are exactly the ones that script enabled, so the import is a no-op.
resource "azurerm_monitor_diagnostic_setting" "activity_log" {
  name                       = "ds-activity-to-law"
  target_resource_id         = data.azurerm_subscription.current.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.grc.id

  enabled_log {
    category = "Administrative"
  }

  enabled_log {
    category = "Security"
  }

  enabled_log {
    category = "Policy"
  }

  enabled_log {
    category = "Alert"
  }
}

# Where a change notification goes. One receiver, the accountable owner from var.owner_email,
# on the common alert schema so the payload shape is stable if a second receiver is added.
resource "azurerm_monitor_action_group" "control_plane_changes" {
  name                = "ag-grc-control-plane-changes"
  resource_group_name = azurerm_resource_group.sandbox.name
  short_name          = "grcchange"

  email_receiver {
    name                    = "capstone-owner"
    email_address           = var.owner_email
    use_common_alert_schema = true
  }

  tags = {
    env     = var.environment
    purpose = "grc-change-detection"
  }
}

# The tripwire. Hourly, because attribution after the fact is the goal, not interception:
# the Activity Log is already the record, and this makes someone read it.
#
# blast radius: read-only. It queries the workspace and sends mail. It cannot change,
# create or delete anything in Azure, and it cannot block a change.
# rollback: remove this resource in a reviewed PR and apply. Nothing it created persists
# except the alerts already fired, which stay in Azure Monitor's own history.
#
# Severity 3 on purpose: a control-plane change is not a finding, it is something that
# has to be attributable. Treating every deploy as an incident trains people to ignore it.
resource "azurerm_monitor_scheduled_query_rules_alert_v2" "control_plane_changes" {
  name                = "alert-grc-control-plane-changes"
  display_name        = "Successful Azure control-plane changes"
  description         = "Successful administrative writes and deletes, with the caller that made them."
  resource_group_name = azurerm_resource_group.sandbox.name
  location            = azurerm_resource_group.sandbox.location

  scopes               = [azurerm_log_analytics_workspace.grc.id]
  evaluation_frequency = "PT1H"
  window_duration      = "PT1H"
  severity             = 3
  enabled              = true

  # The query uses the ...Value columns and _ResourceId, not AzureActivity's legacy columns
  # (ResourceId, OperationName and others): those are not reliably populated, and Azure
  # rejects a rule whose query names a column the table doesn't have.
  criteria {
    query = <<-KQL
      AzureActivity
      | where CategoryValue =~ "Administrative"
      | where ActivityStatusValue in~ ("Success", "Succeeded")
      | where OperationNameValue endswith "/WRITE" or OperationNameValue endswith "/DELETE"
      | project TimeGenerated, Caller, OperationNameValue, _ResourceId
    KQL

    time_aggregation_method = "Count"
    operator                = "GreaterThan"
    threshold               = 0

    failing_periods {
      minimum_failing_periods_to_trigger_alert = 1
      number_of_evaluation_periods             = 1
    }
  }

  action {
    action_groups = [azurerm_monitor_action_group.control_plane_changes.id]
    email_subject = "CGE-AZ: Azure control-plane change detected"
  }

  # One email per burst of changes, not one per hour of a long deploy. Muting silences the
  # email, not the record: every change stays in the Activity Log, and the evidence script
  # reads it there. auto_mitigation_enabled stays unset: the provider documents it and a
  # mute duration as mutually exclusive.
  mute_actions_after_alert_duration = "PT6H"

  tags = {
    env     = var.environment
    purpose = "grc-change-detection"
  }
}
