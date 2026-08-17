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

output "network" {
  value = local.network

  precondition {
    condition     = local.net.gateway_host > 0 && local.net.gateway_host < 255
    error_message = "network.json gateway_host must be a host octet."
  }

  precondition {
    condition     = alltrue([for n, l in local.labs : l.ipv4 != local.network.gateway_ipv4])
    error_message = "A lab claims the gateway address; change its net.host."
  }
}
