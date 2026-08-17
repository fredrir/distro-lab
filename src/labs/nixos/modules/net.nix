{
  network,
  spec,
  ...
}:

let
  address = "${network.subnet_prefix}.${toString spec.net.host}";
  gateway = "${network.subnet_prefix}.${toString network.gateway_host}";
in
{
  # The registry fixes a lab's address and libvirt reserves it, so there is
  # nothing left to negotiate at boot. dhcpcd negotiated it anyway and cost
  # 7.6s of every cold boot: ARP conflict probing for an address no other guest
  # can be handed, then waiting on router advertisements this NAT network never
  # sends. Baked in, the link is up before multi-user.target is reached.
  networking.useDHCP = false;
  networking.useNetworkd = true;

  # libvirt assigns the NIC's PCIe slot, so the predictable name shifts when the
  # device set changes (enp2s0 today). A lab has exactly one physical link, so
  # match its class the way the nixpkgs DHCP fallback does rather than a name.
  systemd.network.networks."10-lan" = {
    matchConfig = {
      Type = "ether";
      Kind = "!*";
    };

    address = [ "${address}/${toString network.prefix_length}" ];

    routes = [
      { Gateway = gateway; }
    ];

    # Nothing on this network speaks IPv6: libvirt gives it no IPv6 address and
    # sends no advertisements. Both of these are pure waiting. Link-local is the
    # more expensive one — networkd holds a link "not configured" until it gains
    # IPv6LL, so duplicate address detection on an address no one else can hold
    # kept network-online.target 1.4s away. Loopback ::1 is untouched.
    networkConfig = {
      IPv6AcceptRA = false;
      LinkLocalAddressing = "no";
    };

    linkConfig.RequiredForOnline = "routable";
  };

  # networkd pulls in systemd-resolved by default, which would replace
  # /etc/resolv.conf with the 127.0.0.53 stub and stop resolving single-label
  # names. Keep openresolv and the file dhcpcd used to write, byte for byte.
  services.resolved.enable = false;

  # dhcpcd wrote both of these out of the lease.
  networking.nameservers = [ gateway ];
  networking.domain = network.domain;
}
