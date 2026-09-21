# Gate rule: a policy assignment carrying remediation effects without an identity
# applies cleanly and then silently never remediates. Make that mistake unmergeable.
#
# The first version of this rule tested `not rc.change.after.identity`, which never fired:
# Terraform serialises an absent block as an empty list, and `not []` is false in Rego.
# Proven with conftest 0.70.1 against a plan for stages/02-activation. `object.get` with a
# default now treats missing, null and [] the same way.
package main

import rego.v1

assignment_types := {
	"azurerm_management_group_policy_assignment",
	"azurerm_subscription_policy_assignment",
	"azurerm_resource_group_policy_assignment",
}

# Assignments whose initiative carries no remediation effect, and so need no identity.
# A plan cannot see a built-in initiative's effects, so the exemption is data: adding a
# name here is a reviewed decision, and its reason lives in docs/CONTROLS.md.
audit_only := {"nist-csf-20"}

deny contains msg if {
	some rc in input.resource_changes
	rc.type in assignment_types
	rc.change.actions[_] != "delete"
	not rc.change.after.name in audit_only
	count(object.get(rc.change.after, "identity", [])) == 0
	msg := sprintf("%s: policy assignments must carry an identity block (remediation effects silently no-op without one), or be listed as audit-only in policy/policy_identity.rego", [rc.address])
}
