output "labs" {
  value = local.labs

  precondition {
    condition     = length(distinct([for n, l in local.labs : l.mac_address])) == length(local.labs)
    error_message = "Derived MAC addresses collide; rename one of the labs."
  }
}

output "names" {
  value = sort(keys(local.labs))
}
