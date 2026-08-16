set shell := ["bash", "-euo", "pipefail", "-c"]
set dotenv-load
set dotenv-required

registry := "src/labs/labs.json"

resolve := 'resolve_dir() { case "$1" in shared) echo src/vm/shared ;; *) if [[ -d "src/labs/$1/tofu" ]]; then echo "src/labs/$1/tofu" ; else echo "unknown stack: $1 (try: just labs)" >&2 ; return 1 ; fi ;; esac ; } ; labs() { for d in src/labs/*/tofu ; do [[ -d "$d" ]] || continue ; n=$(basename "$(dirname "$d")") ; [[ "$n" == _* ]] && continue ; echo "$n" ; done ; } ; stacks() { echo shared ; labs ; } ; spec() { jq -r --arg l "$1" "$2" src/labs/labs.json ; } ;'

[private]
default:
    @just --list

# Every lab VM with state, address and size
[group('vm')]
vms:
    #!/usr/bin/env bash
    set -euo pipefail
    printf '%-16s %-9s %-16s %5s %8s\n' NAME STATE IP VCPU MEM
    for vm in $(virsh -c "$TF_VAR_libvirt_uri" list --all --name); do
        info=$(virsh -c "$TF_VAR_libvirt_uri" dominfo "$vm")
        state=$(sed -n 's/^State: *//p' <<<"$info")
        vcpu=$(sed -n 's/^CPU(s): *//p' <<<"$info")
        kib=$(sed -n 's/^Max memory: *\([0-9]*\).*/\1/p' <<<"$info")
        mem=$(awk -v k="$kib" 'BEGIN {printf "%.1fG", k / 1048576}')
        ip=$(virsh -c "$TF_VAR_libvirt_uri" domifaddr "$vm" --source lease 2>/dev/null |
            awk '$3 == "ipv4" {split($4, a, "/"); print a[1]; exit}' || true)
        printf '%-16s %-9s %-16s %5s %8s\n' "$vm" "$state" "${ip:--}" "$vcpu" "$mem"
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

# Build a nix lab's disk image into images/
[group('lab')]
image lab:
    #!/usr/bin/env bash
    set -euo pipefail
    {{ resolve }}
    kind=$(spec {{ lab }} '.[$l].source.type')
    [[ "$kind" == nix ]] || { echo "{{ lab }} is a $kind lab, not nix" >&2; exit 1; }
    untracked=$(git ls-files --others --exclude-standard flake.nix src/labs/nixos)
    if [[ -n "$untracked" ]]; then
        echo "untracked files below the flake root are invisible to a git+file flake:" >&2
        sed 's/^/  /' <<<"$untracked" >&2
        echo "stage them first: git add -N <files>" >&2
        exit 1
    fi
    out=$(nix build ".#packages.x86_64-linux.image-{{ lab }}" \
        --out-link "images/.gcroot-{{ lab }}" --print-out-paths)
    install -m 0644 "$out/{{ lab }}.qcow2" "images/{{ lab }}-base.qcow2"
    qemu-img resize "images/{{ lab }}-base.qcow2" "$(spec {{ lab }} '.[$l].disk_size_bytes')"
    readlink -f "$out" > "images/{{ lab }}-base.store-path"
    qemu-img info "images/{{ lab }}-base.qcow2" | head -4

# Generate a lab's age identity and ssh host key on its state share
[group('lab')]
lab-keys lab:
    #!/usr/bin/env bash
    set -euo pipefail
    s="storage/{{ lab }}/state"
    pub="src/labs/nixos/secrets/hosts"
    mkdir -p "$s" "$pub"
    if [[ ! -f "$s/agenix.key" ]]; then
        age-keygen -o "$s/agenix.key" 2>/dev/null
        chmod 600 "$s/agenix.key"
        echo "generated age identity for {{ lab }}"
    fi
    age-keygen -y "$s/agenix.key" > "$pub/{{ lab }}.pub"
    if [[ ! -f "$s/ssh_host_ed25519_key" ]]; then
        ssh-keygen -q -t ed25519 -N "" -C "{{ lab }}" -f "$s/ssh_host_ed25519_key"
        echo "generated ssh host key for {{ lab }}"
    fi
    cp "$s/ssh_host_ed25519_key.pub" "$pub/{{ lab }}.ssh.pub"
    echo "{{ lab }} age recipient: $(cat "$pub/{{ lab }}.pub")"

# Rebuild a nix lab in place over SSH, no tofu
[group('lab')]
deploy lab *args:
    nix develop -c nixos-rebuild switch --flake .#{{ lab }} --target-host {{ lab }} --sudo {{ args }}

# Raise a running lab's balloon and online its cpus
[group('vm')]
grow lab mem="" vcpu="":
    #!/usr/bin/env bash
    set -euo pipefail
    {{ resolve }}
    mem="{{ mem }}"; vcpu="{{ vcpu }}"
    [[ -n "$mem" ]]  || mem="$(spec {{ lab }} '.[$l].memory_mib')M"
    [[ -n "$vcpu" ]] || vcpu=$(spec {{ lab }} '.[$l].vcpu')
    virsh -c "$TF_VAR_libvirt_uri" setmem "{{ lab }}" "$mem" --live
    virsh -c "$TF_VAR_libvirt_uri" setvcpus "{{ lab }}" "$vcpu" --live --guest
    virsh -c "$TF_VAR_libvirt_uri" dominfo "{{ lab }}" | grep -E 'Used memory|CPU\(s\)'

# Boot a lab and wait for it to answer on SSH
[group('vm')]
up lab:
    #!/usr/bin/env bash
    set -euo pipefail
    {{ resolve }}
    mkdir -p "storage/{{ lab }}/state"
    state=$(virsh -c "$TF_VAR_libvirt_uri" domstate "{{ lab }}" 2>/dev/null || echo undefined)
    if [[ "$state" != running && "${DLAB_FORCE:-0}" != 1 ]]; then
        need=$(spec {{ lab }} '.[$l].memory_mib // 8192')
        avail=$(( $(awk '/^MemAvailable:/ {print $2}' /proc/meminfo) / 1024 ))
        reserve=4096
        if (( avail - reserve < need )); then
            echo "refusing to start {{ lab }}: needs ${need} MiB, only $(( avail - reserve )) MiB spendable (${avail} MiB available, ${reserve} MiB reserved for the host)" >&2
            echo "virtiofs inhibits ram discard, so a lab's host RSS is its full memory_mib regardless of the balloon." >&2
            echo "awake now:" >&2
            for d in $(virsh -c "$TF_VAR_libvirt_uri" list --name); do
                [[ "$d" == dlab-* ]] && echo "  $d    stop with: just down $d" >&2
            done
            echo "override with DLAB_FORCE=1 just up {{ lab }}" >&2
            exit 1
        fi
    fi
    case "$state" in
        undefined)     echo "{{ lab }} is not defined, run: just apply {{ lab }}" >&2 ; exit 1 ;;
        running)       ;;
        paused)        virsh -c "$TF_VAR_libvirt_uri" resume "{{ lab }}" ;;
        pmsuspended)   virsh -c "$TF_VAR_libvirt_uri" dompmwakeup "{{ lab }}" ;;
        crashed)       virsh -c "$TF_VAR_libvirt_uri" destroy "{{ lab }}" ; virsh -c "$TF_VAR_libvirt_uri" start "{{ lab }}" ;;
        *)             virsh -c "$TF_VAR_libvirt_uri" start "{{ lab }}" ;;
    esac
    ip="$TF_VAR_subnet_prefix.$(spec {{ lab }} '.[$l].net.host')"
    for _ in $(seq 1 300); do
        nc -z -w1 "$ip" 22 2>/dev/null && { echo "{{ lab }} up on $ip"; exit 0; }
        sleep 1
    done
    echo "{{ lab }} did not answer on $ip:22" >&2
    exit 1

# Stop a lab using the idle action from the registry
[group('vm')]
down lab:
    #!/usr/bin/env bash
    set -euo pipefail
    {{ resolve }}
    action=$(spec {{ lab }} '.[$l].idle.action // "shutdown"')
    if virsh -c "$TF_VAR_libvirt_uri" dumpxml "{{ lab }}" 2>/dev/null | grep -q '<hostdev'; then
        action=shutdown
    fi
    case "$action" in
        managedsave) virsh -c "$TF_VAR_libvirt_uri" managedsave "{{ lab }}" ;;
        none)        echo "{{ lab }} has idle.action none, not stopping" >&2 ;;
        *)           virsh -c "$TF_VAR_libvirt_uri" shutdown --mode agent,acpi "{{ lab }}" ;;
    esac
    rm -f "$HOME/.ssh/cm-"*"@{{ lab }}:"*

# Block the idle stopper for a while
[group('vm')]
hold lab duration="2h":
    #!/usr/bin/env bash
    set -euo pipefail
    d="{{ duration }}"
    case "$d" in
        *[0-9]m) d="${d%m} minutes" ;;
        *[0-9]h) d="${d%h} hours" ;;
        *[0-9]d) d="${d%d} days" ;;
    esac
    until=$(date -d "now + $d" +%s)
    mkdir -p "storage/{{ lab }}/state"
    echo "$until" > "storage/{{ lab }}/state/keepalive"
    echo "{{ lab }} held until $(date -d "@$until" '+%H:%M:%S')"

# Shut a lab down cleanly so its work disk is flushed, then wait
[group('vm')]
quiesce lab:
    #!/usr/bin/env bash
    set -euo pipefail
    state=$(virsh -c "$TF_VAR_libvirt_uri" domstate "{{ lab }}" 2>/dev/null || echo undefined)
    [[ "$state" == running ]] || exit 0
    echo "quiescing {{ lab }} so buffered writes reach the work disk"
    virsh -c "$TF_VAR_libvirt_uri" shutdown --mode agent,acpi "{{ lab }}" >/dev/null 2>&1 || true
    for _ in $(seq 1 120); do
        [[ "$(virsh -c "$TF_VAR_libvirt_uri" domstate "{{ lab }}" 2>/dev/null)" == "shut off" ]] && exit 0
        sleep 1
    done
    echo "{{ lab }} did not shut down in 120s; destroying it will lose unflushed writes" >&2
    exit 1

# Release an idle hold early
[group('vm')]
release lab:
    @rm -f "storage/{{ lab }}/state/keepalive" && echo "{{ lab }} released"

# What the idle stopper currently sees
[group('vm')]
idle:
    #!/usr/bin/env bash
    set -euo pipefail
    {{ resolve }}
    now=$(date +%s)
    printf '%-16s %-9s %-10s %-10s %s\n' LAB STATE ALIVE IDLE HOLD
    for lab in $(labs); do
        state=$(virsh -c "$TF_VAR_libvirt_uri" domstate "$lab" 2>/dev/null || echo undefined)
        s="storage/$lab/state"
        a="-"; i="-"; h="-"
        [[ -f "$s/alive" ]] && a="$(( now - $(stat -c %Y "$s/alive") ))s"
        [[ -f "$s/busy" ]]  && i="$(( (now - $(stat -c %Y "$s/busy")) / 60 ))m"
        if [[ -f "$s/keepalive" ]]; then
            u=$(cat "$s/keepalive"); (( u > now )) && h="$(( (u - now) / 60 ))m"
        fi
        printf '%-16s %-9s %-10s %-10s %s\n' "$lab" "$state" "$a" "$i" "$h"
    done

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
    printf '%-16s %-10s %-8s %s\n' STACK RESOURCES DOMAIN STATE
    for stack in $(stacks); do
        dir=$(resolve_dir "$stack")
        if [[ -f "$dir/terraform.tfstate" ]]; then
            count=$(tofu -chdir="$dir" state list 2>/dev/null | wc -l || true)
        else
            count=0
        fi
        if [[ "$stack" == shared ]]; then
            printf '%-16s %-10s %-8s %s\n' "$stack" "$count" - -
            continue
        fi
        if state=$(virsh -c "$TF_VAR_libvirt_uri" domstate "$stack" 2>/dev/null); then
            domain=yes
        else
            domain=no
            state=-
        fi
        printf '%-16s %-10s %-8s %s\n' "$stack" "$count" "$domain" "$state"
    done

# Check every host dependency the lab quietly relies on
[group('lab')]
doctor:
    #!/usr/bin/env bash
    set -uo pipefail
    {{ resolve }}
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
    declared=$(sed -n 's/^variable "\(.*\)".*/\1/p' src/vm/shared/variables.tf src/labs/*/tofu/variables.tf | sort -u)
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
    proxy="src/vm/bin/dlab-ssh-proxy"
    if [[ -x "$proxy" ]]; then ok "$proxy"; else bad "$proxy missing or not executable"; fi
    if [[ -e "$HOME/.ssh/config.d/20-distro-lab-host" ]]; then
        ok "~/.ssh/config.d/20-distro-lab-host"
    else
        bad "~/.ssh/config.d/20-distro-lab-host missing, symlink src/vm/ssh/20-distro-lab-host"
    fi
    stale=$(command ls "$HOME/.ssh/"cm-*@dlab-* 2>/dev/null | wc -l)
    if [[ "$stale" -eq 0 ]]; then
        ok "no lingering ssh control masters"
    else
        for s in "$HOME/.ssh/"cm-*@dlab-*; do
            lab=${s##*@}; lab=${lab%%:*}
            [[ "$(virsh -c "$TF_VAR_libvirt_uri" domstate "$lab" 2>/dev/null)" == running ]] \
                || bad "stale control master for stopped $lab, rm $s"
        done
    fi

    echo "lifecycle"
    if systemctl is-enabled dlab-idle-stop.timer >/dev/null 2>&1; then
        ok "dlab-idle-stop.timer enabled"
    else
        bad "dlab-idle-stop.timer not installed, see src/vm/systemd/"
    fi
    if [[ -d /run/dlab ]]; then ok "/run/dlab"; else bad "/run/dlab missing, install src/vm/systemd/dlab-tmpfiles.conf"; fi
    if [[ "$(systemctl is-enabled libvirt-guests 2>/dev/null)" == enabled ]]; then
        bad "libvirt-guests is enabled and will restore every lab at host boot"
    else
        ok "libvirt-guests disabled"
    fi

    echo "registry"
    if jq -e . {{ registry }} >/dev/null 2>&1; then ok "{{ registry }} parses"; else bad "{{ registry }} is not valid JSON"; fi
    pending=$(for lab in $(jq -r 'keys[]' {{ registry }}); do [[ -d "src/labs/$lab/tofu" ]] || echo "$lab"; done | tr '\n' ' ')
    [[ -n "$pending" ]] && printf '  note  declared but not built yet: %s\n' "$pending"
    for lab in $(labs); do
        jq -e --arg l "$lab" 'has($l)' {{ registry }} >/dev/null || bad "src/labs/$lab has no registry entry"
    done
    dupes=$(jq -r '[.[].net.host] | group_by(.) | map(select(length > 1)) | flatten | @csv' {{ registry }})
    if [[ -z "$dupes" ]]; then ok "net.host octets unique"; else bad "duplicate net.host: $dupes"; fi

    echo "media"
    for lab in $(labs); do
        kind=$(spec "$lab" '.[$l].source.type')
        if [[ "$kind" == nix ]]; then
            if [[ -f "images/$lab-base.qcow2" ]]; then ok "images/$lab-base.qcow2"; else bad "images/$lab-base.qcow2 missing, run: just image $lab"; fi
        else
            img=$(spec "$lab" '.[$l].source.image')
            case "$img" in
                *://*) ok "$img (remote)" ;;
                *) if [[ -f "$TF_VAR_distro_lab_path/$img" ]]; then ok "$img"; else bad "$img missing"; fi ;;
            esac
        fi
    done

    echo "virtiofs"
    if [[ -x /usr/lib/virtiofsd ]]; then ok "/usr/lib/virtiofsd"; else bad "virtiofsd missing, pacman -S virtiofsd"; fi
    if [[ -f /usr/share/qemu/vhost-user/50-virtiofsd.json ]]; then ok "virtiofsd capability descriptor"; else bad "no vhost-user descriptor, managedsave of a lab with a share will fail"; fi
    for lab in $(labs); do
        if [[ -d "storage/$lab/state" ]]; then
            [[ "$(stat -c '%u' "storage/$lab/state")" == "$(id -u)" ]] || bad "storage/$lab/state is not owned by $(id -un)"
        else
            bad "storage/$lab/state missing, virtiofsd will refuse to start"
        fi
    done
    ok "state shares for $(labs | wc -l) built labs"

    echo "network"
    live=$(virsh -c "$TF_VAR_libvirt_uri" net-dumpxml "$TF_VAR_network" 2>/dev/null || true)
    for lab in $(jq -r 'keys[]' {{ registry }}); do
        grep -q "name='$lab'" <<<"$live" || bad "$lab has no DHCP reservation, run: just apply shared"
    done
    [[ -n "$live" ]] && ok "$(jq -r 'keys | length' {{ registry }}) reservations checked"

    echo "memory"
    ksm=$(cat /sys/kernel/mm/ksm/run 2>/dev/null || echo 0)
    if [[ "$ksm" != 0 ]]; then
        bad "KSM is on but every lab has a virtiofs share; memfd-shared guest RAM is never scanned"
    else
        ok "KSM off (correct: virtiofs forces shared memory backing)"
    fi
    if [[ "$(swapon --show --noheadings | wc -l)" -gt 0 ]]; then
        ok "swap present"
    else
        bad "no swap: virtiofs guest RAM is unreclaimable shmem, the OOM killer is the only relief. enable zram"
    fi
    committed=0
    for d in $(virsh -c "$TF_VAR_libvirt_uri" list --name); do
        [[ "$d" == dlab-* ]] || continue
        committed=$(( committed + $(spec "$d" '.[$l].memory_mib // 8192') ))
    done
    avail=$(( $(awk '/^MemAvailable:/ {print $2}' /proc/meminfo) / 1024 ))
    printf '  note  %s MiB committed by awake labs, %s MiB available\n' "$committed" "$avail"

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
    #!/usr/bin/env bash
    set -euo pipefail
    {{ resolve }}
    dir=$(resolve_dir {{ stack }})
    if [[ "{{ stack }}" != shared ]]; then
        mkdir -p "storage/{{ stack }}/state"
        virsh -c "$TF_VAR_libvirt_uri" managedsave-remove "{{ stack }}" 2>/dev/null || true
    fi
    tofu -chdir="$dir" apply {{ args }}

# Apply a stack without reconciling state against libvirt
[group('tofu')]
apply-fast stack *args:
    #!/usr/bin/env bash
    set -euo pipefail
    {{ resolve }}
    dir=$(resolve_dir {{ stack }})
    [[ "{{ stack }}" == shared ]] || mkdir -p "storage/{{ stack }}/state"
    tofu -chdir="$dir" apply -refresh=false -lock=false -compact-warnings {{ args }}

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
    #!/usr/bin/env bash
    set -euo pipefail
    {{ resolve }}
    dir=$(resolve_dir {{ stack }})
    if [[ "{{ stack }}" != shared ]]; then
        virsh -c "$TF_VAR_libvirt_uri" managedsave-remove "{{ stack }}" 2>/dev/null || true
        just quiesce "{{ stack }}"
    fi
    tofu -chdir="$dir" destroy -auto-approve

# Destroy and recreate a stack from scratch
[confirm('rebuild this stack from scratch, discarding the installed system? [y/N]')]
[group('tofu')]
rebuild stack:
    #!/usr/bin/env bash
    set -euo pipefail
    {{ resolve }}
    dir=$(resolve_dir {{ stack }})
    if [[ "{{ stack }}" != shared ]]; then
        mkdir -p "storage/{{ stack }}/state"
        virsh -c "$TF_VAR_libvirt_uri" managedsave-remove "{{ stack }}" 2>/dev/null || true
        just quiesce "{{ stack }}"
    fi
    tofu -chdir="$dir" destroy -auto-approve
    tofu -chdir="$dir" apply -auto-approve
