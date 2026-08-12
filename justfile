set shell := ["bash", "-euo", "pipefail", "-c"]
set dotenv-load
set dotenv-required

stacks := "shared gentoo-dev nixos-dev ubuntu-dev"

resolve := 'resolve_dir() { case "$1" in shared) echo src/vm/shared ;; gentoo-dev|nixos-dev|ubuntu-dev) echo src/distros/$1/tofu ;; *) echo "unknown stack: $1 (stacks: shared gentoo-dev nixos-dev ubuntu-dev)" >&2 ; return 1 ;; esac ; } ;'

[private]
default:
    @just --list

# Every lab VM with state, address and size
[group('vm')]
vms:
    #!/usr/bin/env bash
    set -euo pipefail
    printf '%-12s %-9s %-16s %5s %8s\n' NAME STATE IP VCPU MEM
    for vm in $(virsh -c "$TF_VAR_libvirt_uri" list --all --name); do
        info=$(virsh -c "$TF_VAR_libvirt_uri" dominfo "$vm")
        state=$(sed -n 's/^State: *//p' <<<"$info")
        vcpu=$(sed -n 's/^CPU(s): *//p' <<<"$info")
        kib=$(sed -n 's/^Max memory: *\([0-9]*\).*/\1/p' <<<"$info")
        mem=$(awk -v k="$kib" 'BEGIN {printf "%.1fG", k / 1048576}')
        ip=$(virsh -c "$TF_VAR_libvirt_uri" domifaddr "$vm" --source lease 2>/dev/null |
            awk '$3 == "ipv4" {split($4, a, "/"); print a[1]; exit}' || true)
        printf '%-12s %-9s %-16s %5s %8s\n' "$vm" "$state" "${ip:--}" "$vcpu" "$mem"
    done

# Current DHCP lease address of a VM
[group('vm')]
ip vm:
    @virsh -c "$TF_VAR_libvirt_uri" domifaddr {{ vm }} --source lease | awk '$3 == "ipv4" {split($4, a, "/"); print a[1]; exit}'

# SSH into a VM, optionally running a command
[group('vm')]
ssh vm *args:
    ssh {{ vm }} {{ args }}

# Attach to a VM serial console, Ctrl+] to detach
[group('vm')]
console vm:
    virsh -c "$TF_VAR_libvirt_uri" console {{ vm }}

# Boot a defined VM
[group('vm')]
start vm:
    virsh -c "$TF_VAR_libvirt_uri" start {{ vm }}

# Shut a VM down gracefully
[group('vm')]
stop vm:
    virsh -c "$TF_VAR_libvirt_uri" shutdown {{ vm }}

# Reboot a running VM
[group('vm')]
reboot vm:
    virsh -c "$TF_VAR_libvirt_uri" reboot {{ vm }}

# Dump the libvirt XML of a VM
[group('vm')]
xml vm:
    virsh -c "$TF_VAR_libvirt_uri" dumpxml {{ vm }}

# Volumes in the images pool
[group('vm')]
pool:
    @virsh -c "$TF_VAR_libvirt_uri" vol-list "$TF_VAR_pool" --details

# Disk used by images, install media and persistent storage
[group('vm')]
df:
    #!/usr/bin/env bash
    set -euo pipefail
    virsh -c "$TF_VAR_libvirt_uri" vol-list "$TF_VAR_pool" --details
    echo
    du -sh images ISOs storage 2>/dev/null || true

# What OpenTofu believes against what libvirt actually has
[group('lab')]
status:
    #!/usr/bin/env bash
    set -euo pipefail
    {{ resolve }}
    printf '%-12s %-10s %-8s %s\n' STACK RESOURCES DOMAIN STATE
    for stack in {{ stacks }}; do
        dir=$(resolve_dir "$stack")
        if [[ -f "$dir/terraform.tfstate" ]]; then
            count=$(tofu -chdir="$dir" state list 2>/dev/null | wc -l || true)
        else
            count=0
        fi
        if [[ "$stack" == shared ]]; then
            printf '%-12s %-10s %-8s %s\n' "$stack" "$count" - -
            continue
        fi
        if state=$(virsh -c "$TF_VAR_libvirt_uri" domstate "$stack" 2>/dev/null); then
            domain=yes
        else
            domain=no
            state=-
        fi
        printf '%-12s %-10s %-8s %s\n' "$stack" "$count" "$domain" "$state"
    done

# Check every host dependency the lab quietly relies on
[group('lab')]
doctor:
    #!/usr/bin/env bash
    set -uo pipefail
    fail=0
    ok()  { printf '  ok    %s\n' "$1"; }
    bad() { printf '  FAIL  %s\n' "$1"; fail=1; }

    echo "commands"
    for cmd in tofu virsh nc qemu-img ssh; do
        if command -v "$cmd" >/dev/null 2>&1; then ok "$cmd"; else bad "$cmd not on PATH"; fi
    done

    echo "libvirt"
    if virsh -c "$TF_VAR_libvirt_uri" version >/dev/null 2>&1; then
        ok "$TF_VAR_libvirt_uri reachable"
    else
        bad "cannot reach $TF_VAR_libvirt_uri"
    fi
    pool_state=$(virsh -c "$TF_VAR_libvirt_uri" pool-info "$TF_VAR_pool" 2>/dev/null | sed -n 's/^State: *//p')
    if [[ "$pool_state" == running ]]; then
        ok "pool $TF_VAR_pool active"
    else
        bad "pool $TF_VAR_pool missing or inactive, run: just apply shared"
    fi
    if virsh -c "$TF_VAR_libvirt_uri" net-info "$TF_VAR_network" >/dev/null 2>&1; then
        ok "network $TF_VAR_network defined"
    else
        bad "network $TF_VAR_network missing"
    fi

    echo "environment"
    declared=$(sed -n 's/^variable "\(.*\)".*/\1/p' src/vm/shared/variables.tf src/distros/*/tofu/variables.tf | sort -u)
    missing=0
    for var in $declared; do
        name="TF_VAR_$var"
        if [[ -z "${!name:-}" ]]; then bad "$name unset"; missing=1; fi
    done
    if [[ $missing -eq 0 ]]; then ok "all $(wc -w <<<"$declared") declared variables set"; fi
    unexpanded=$(env | grep '^TF_VAR_' | grep -c '\${')
    if [[ "$unexpanded" -eq 0 ]]; then
        ok "no unexpanded references in .env"
    else
        bad "$unexpanded TF_VAR_* still contain \${...}, just did not expand .env"
    fi

    echo "ssh"
    proxy="$HOME/.local/bin/libvirt-ssh-proxy"
    if [[ -x "$proxy" ]]; then ok "$proxy"; else bad "$proxy missing, symlink src/vm/libvirt-ssh-proxy"; fi
    if [[ -e "$HOME/.ssh/config.d/20-distro-lab-host" ]]; then
        ok "~/.ssh/config.d/20-distro-lab-host"
    else
        bad "~/.ssh/config.d/20-distro-lab-host missing, symlink src/vm/ssh/20-distro-lab-host"
    fi

    echo "media"
    for url in "$TF_VAR_gentoo_dev_image_url" "$TF_VAR_ubuntu_dev_image_url"; do
        if [[ "$url" != file://* ]]; then
            ok "$url (remote)"
        elif [[ -f "${url#file://}" ]]; then
            ok "${url#file://}"
        else
            bad "${url#file://} missing"
        fi
    done
    iso="$TF_VAR_distro_lab_path/ISOs/$TF_VAR_nixos_dev_iso"
    if [[ -f "$iso" ]]; then ok "$iso"; else bad "$iso missing"; fi

    exit $fail

# Variables that would be handed to OpenTofu
[group('lab')]
env:
    @env | grep '^TF_' | sort

# Format every OpenTofu file under src/
[group('tofu')]
fmt:
    tofu fmt -recursive src

# Initialise a stack
[group('tofu')]
init stack:
    @{{ resolve }} dir=$(resolve_dir {{ stack }}) && mkdir -p "$TF_PLUGIN_CACHE_DIR" && tofu -chdir="$dir" init

# Validate a stack
[group('tofu')]
validate stack:
    @{{ resolve }} dir=$(resolve_dir {{ stack }}) && tofu -chdir="$dir" validate

# Plan a stack
[group('tofu')]
plan stack *args:
    @{{ resolve }} dir=$(resolve_dir {{ stack }}) && tofu -chdir="$dir" plan {{ args }}

# Plan a stack without reconciling state against libvirt
[group('tofu')]
plan-fast stack *args:
    @{{ resolve }} dir=$(resolve_dir {{ stack }}) && tofu -chdir="$dir" plan -refresh=false -lock=false -compact-warnings {{ args }}

# Apply a stack
[group('tofu')]
apply stack *args:
    @{{ resolve }} dir=$(resolve_dir {{ stack }}) && tofu -chdir="$dir" apply {{ args }}

# Apply a stack without reconciling state against libvirt
[group('tofu')]
apply-fast stack *args:
    @{{ resolve }} dir=$(resolve_dir {{ stack }}) && tofu -chdir="$dir" apply -refresh=false -lock=false -compact-warnings {{ args }}

# Reconcile stack state against libvirt
[group('tofu')]
refresh stack:
    @{{ resolve }} dir=$(resolve_dir {{ stack }}) && tofu -chdir="$dir" refresh

# Show a stack's outputs
[group('tofu')]
output stack:
    @{{ resolve }} dir=$(resolve_dir {{ stack }}) && tofu -chdir="$dir" output

# Show a stack's state
[group('tofu')]
show stack:
    @{{ resolve }} dir=$(resolve_dir {{ stack }}) && tofu -chdir="$dir" show

# Destroy a stack, discarding the installed system
[confirm('destroy this stack and everything installed in it? [y/N]')]
[group('tofu')]
destroy stack:
    @{{ resolve }} dir=$(resolve_dir {{ stack }}) && tofu -chdir="$dir" destroy -auto-approve

# Destroy and recreate a stack from scratch
[confirm('rebuild this stack from scratch, discarding the installed system? [y/N]')]
[group('tofu')]
rebuild stack:
    #!/usr/bin/env bash
    set -euo pipefail
    {{ resolve }}
    dir=$(resolve_dir {{ stack }})
    tofu -chdir="$dir" destroy -auto-approve
    tofu -chdir="$dir" apply -auto-approve
