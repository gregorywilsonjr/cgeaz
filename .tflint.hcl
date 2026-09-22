# tflint's bundled Terraform ruleset. The "recommended" preset adds the checks the language
# itself doesn't make: unused declarations, deprecated syntax, typed variables, pinned
# providers and a required_version in every root module.
#
# No azurerm plugin: most of its rules check attribute values that the provider's own
# validation already rejects at `terraform validate`, which tier0 runs first.
plugin "terraform" {
  enabled = true
  preset  = "recommended"
}
