set shell := ["bash", "-euo", "pipefail", "-c"]
set dotenv-load
set dotenv-required

registry := "src/labs/labs.json"

# Where the VM artifacts live: images, install media, and the per-lab state
# shares.  Named once in .env, so the checkout itself can sit anywhere.
store := env_var("TF_VAR_storage_path")

resolve := 'resolve_dir() { case "$1" in shared) echo src/vm/shared ;; *) if [[ -d "src/labs/$1/tofu" ]]; then echo "src/labs/$1/tofu" ; else echo "unknown stack: $1 (try: just labs)" >&2 ; return 1 ; fi ;; esac ; } ; labs() { for d in src/labs/*/tofu ; do [[ -d "$d" ]] || continue ; n=$(basename "$(dirname "$d")") ; [[ "$n" == _* ]] && continue ; echo "$n" ; done ; } ; stacks() { echo shared ; labs ; } ; spec() { jq -r --arg l "$1" "$2" src/labs/labs.json ; } ; net() { jq -r "$1" src/labs/network.json ; } ; labip() { local o ; o=$(spec "$1" ".[\$l].net.host") ; if [[ "$o" == null ]] ; then return 1 ; fi ; echo "$(net .subnet_prefix).$o" ; } ;'

[private]
default:
    @just --list

# Every lab VM with state, address and size
[group('vm')]
vms:
    #!/usr/bin/env bash
    set -euo pipefail
    {{ resolve }}
    printf '%-16s %-9s %-16s %5s %8s\n' NAME STATE IP VCPU MEM
    for vm in $(virsh -c "$TF_VAR_libvirt_uri" list --all --name); do
        info=$(virsh -c "$TF_VAR_libvirt_uri" dominfo "$vm")
        state=$(sed -n 's/^State: *//p' <<<"$info")
        vcpu=$(sed -n 's/^CPU(s): *//p' <<<"$info")
        kib=$(sed -n 's/^Max memory: *\([0-9]*\).*/\1/p' <<<"$info")
        mem=$(awk -v k="$kib" 'BEGIN {printf "%.1fG", k / 1048576}')
        ip=$(labip "$vm" 2>/dev/null || true)
        printf '%-16s %-9s %-16s %5s %8s\n' "$vm" "$state" "${ip:--}" "$vcpu" "$mem"
    done

# Registry address of a VM
[group('vm')]
ip vm:
    @{{ resolve }} labip {{ vm }}

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

# Build a nix lab's disk image into the storage root
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
    # Pin the system rather than the image. `just deploy` and `just sync` build
    # system.build.toplevel and push that closure, so it is the thing worth
    # keeping realised between deploys — and it is a third of the size. The
    # image is a one-shot input to the compressed base below: it holds a gcroot
    # only for as long as it takes to write that base, and the store is free to
    # collect it afterwards.
    nix build ".#nixosConfigurations.{{ lab }}.config.system.build.toplevel" \
        --out-link "{{ store }}/images/.gcroot-{{ lab }}"

    # A root is a thin overlay on the base now, and libvirt keeps it open for
    # as long as the lab exists, so a base can never be rewritten in place.
    # Name it after the build it came from and let a new one land beside the
    # old: the registry reads the same store path and points the next
    # `just apply` at whichever base is current.
    #
    # Evaluated rather than built, because the name is settled at eval time. An
    # image whose base is already written is one there is no reason to realise.
    store_path=$(nix eval --raw ".#packages.x86_64-linux.image-{{ lab }}.outPath")
    stamp=$(basename "$store_path")
    base="{{ store }}/images/{{ lab }}-base-${stamp:0:8}.qcow2"

    build_link="{{ store }}/images/.gcroot-{{ lab }}.build"
    cleanup() { rm -f "$build_link" "$base.partial"; }
    trap cleanup EXIT

    if [[ -f "$base" ]]; then
        echo "{{ lab }}: $(basename "$base") is already current"
    else
        out=$(nix build ".#packages.x86_64-linux.image-{{ lab }}" \
            --out-link "$build_link" --print-out-paths)

        # The overlay declares disk_size_bytes and qcow2 reads past the end of a
        # backing file as zeroes, so the base is left at its natural size rather
        # than resized. The one thing that cannot happen is a base larger than
        # the overlay that sits on it.
        want=$(spec {{ lab }} '.[$l].disk_size_bytes')
        have=$(qemu-img info --output=json "$out/{{ lab }}.qcow2" | jq -r '.["virtual-size"]')
        if (( have > want )); then
            echo "{{ lab }}: the built image is $(numfmt --to=iec "$have") virtual, over the registry's disk_size_bytes ($(numfmt --to=iec "$want"))" >&2
            echo "an overlay cannot be smaller than its base; raise disk_size_bytes in {{ registry }}" >&2
            exit 1
        fi

        # zstd rather than the plain qcow2 the flake builds: the base is
        # read-only under the overlay, so this costs one decompress per cluster
        # read — nothing beside a seek on the disk it lives on — and takes
        # about two thirds off the file. Measured 3.4x across the nix labs.
        qemu-img convert -c -O qcow2 -o compression_type=zstd \
            "$out/{{ lab }}.qcow2" "$base.partial"
        chmod 0644 "$base.partial"
        mv "$base.partial" "$base"
    fi
    printf '%s\n' "$store_path" > "{{ store }}/images/{{ lab }}-base.store-path"
    virsh -c "$TF_VAR_libvirt_uri" pool-refresh "$TF_VAR_pool" >/dev/null 2>&1 || true

    # An older base stays until nothing is backed by it. A lab still naming one
    # has not been applied against the new image yet, and taking it away would
    # take the guest's root with it.
    if virsh -c "$TF_VAR_libvirt_uri" pool-info "$TF_VAR_pool" >/dev/null 2>&1; then
        # No root volume means no overlay, so nothing is backed by anything and
        # every older base is loose. Guard on the pool separately: a libvirt we
        # cannot reach must not read as "nothing is using these".
        live=""
        if xml=$(virsh -c "$TF_VAR_libvirt_uri" vol-dumpxml "{{ lab }}.qcow2" "$TF_VAR_pool" 2>/dev/null); then
            live=$(sed -n '/<backingStore>/,/<\/backingStore>/p' <<<"$xml" \
                | sed -n 's:.*<path>\(.*\)</path>.*:\1:p')
        fi
        shopt -s nullglob
        for old in "{{ store }}/images/{{ lab }}"-base-*.qcow2; do
            if [[ "$old" == "$base" ]]; then
                continue
            elif [[ "$old" == "$live" ]]; then
                echo "keeping $(basename "$old"): {{ lab }} is still backed by it, run: just apply {{ lab }}"
            else
                rm -f "$old"
                echo "removed stale base $(basename "$old")"
            fi
        done
    else
        echo "note  cannot reach pool $TF_VAR_pool, leaving older bases in place" >&2
    fi

    # Reported by stat rather than read out of the file: libvirt hands the whole
    # backing chain to the qemu user when a lab first boots and does not hand it
    # back, so re-running this must not depend on being able to open the base.
    printf '%s  %s compressed\n' "$(basename "$base")" "$(du -h "$base" | cut -f1)"

# Scaffold a lab: registry entry, tofu stack, storage directories
[group('lab')]
new-lab name kind="project" distro="nixos" source_type="nix":
    #!/usr/bin/env bash
    set -euo pipefail
    {{ resolve }}
    lab="{{ name }}"
    [[ "$lab" == dlab-* ]] || { echo "lab names must start with dlab-" >&2; exit 1; }
    [[ -e "src/labs/$lab" ]] && { echo "$lab already exists" >&2; exit 1; }
    jq -e --arg l "$lab" 'has($l)' {{ registry }} >/dev/null 2>&1 \
        && { echo "$lab is already in {{ registry }}" >&2; exit 1; }

    octet=$(jq '[.[].net.host] | (max // 9) + 1' {{ registry }})
    tmp=$(mktemp)
    jq --arg l "$lab" --arg k "{{ kind }}" --arg d "{{ distro }}" \
       --arg s "{{ source_type }}" --argjson o "$octet" '
        .[$l] = ({
            kind: $k, distro: $d, title: $l,
            source: ({type: $s} + (if $s == "nix" then {host: $l} else {image: ""} end)),
            net: {host: $o},
            memory_mib: 8192, current_memory_mib: 4096,
            vcpu: 16, vcpu_current: 4,
            disk_size_bytes: 68719476736,
            idle: {minutes: 60, action: "managedsave"}
        } + (if $k == "project" then {
            work_disk_bytes: 53687091200,
            secrets: ["deploy-key"],
            agent: {skillsets: [], skills: []}
        } else {} end))
        | to_entries | sort_by(.key) | from_entries' {{ registry }} > "$tmp"
    mv "$tmp" {{ registry }}

    mkdir -p "src/labs/$lab/tofu" "{{ store }}/storage/$lab/state"
    sed "s|__LAB__|$lab|g" src/labs/_template/tofu/main.tf > "src/labs/$lab/tofu/main.tf"
    cp src/labs/_template/tofu/{variables.tf,versions.tf,outputs.tf} "src/labs/$lab/tofu/"
    cp src/vm/shared/.terraform.lock.hcl "src/labs/$lab/tofu/"
    tofu -chdir="src/labs/$lab/tofu" init -input=false >/dev/null
    tofu -chdir=src/vm/shared apply -auto-approve >/dev/null

    echo "created $lab at $(labip "$lab")"
    if [[ "{{ source_type }}" == nix ]]; then
        echo "next: write src/labs/nixos/hosts/$lab.nix, then: just image $lab && just apply $lab"
    else
        echo "next: set source.image in {{ registry }} and add src/labs/$lab/config/cloud-init.yaml"
    fi

# Generate a lab's age identity and ssh host key on its state share
[group('lab')]
lab-keys lab:
    #!/usr/bin/env bash
    set -euo pipefail
    s="{{ store }}/storage/{{ lab }}/state"
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

# Seed Codex and opencode credentials plus a long-lived Claude token into project VM state
[group('lab')]
agent-auth lab="all":
    #!/usr/bin/env bash
    set -euo pipefail
    {{ resolve }}

    codex_home="${CODEX_HOME:-$HOME/.codex}"
    claude_home="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
    opencode_data="${XDG_DATA_HOME:-$HOME/.local/share}/opencode"
    codex_auth="$codex_home/auth.json"
    claude_token_file="${CLAUDE_CODE_OAUTH_TOKEN_FILE:-$claude_home/oauth-token}"
    claude_token="${CLAUDE_CODE_OAUTH_TOKEN:-}"
    opencode_auth="$opencode_data/auth.json"

    [[ -f "$codex_auth" ]] || { echo "missing Codex credentials: $codex_auth" >&2; exit 1; }
    jq -e type "$codex_auth" >/dev/null

    if [[ ! -f "$opencode_auth" ]]; then
        echo "missing opencode credentials: $opencode_auth" >&2
        echo "log in on the host with: opencode auth login" >&2
        exit 1
    fi
    jq -e type "$opencode_auth" >/dev/null

    if [[ -z "$claude_token" && -f "$claude_token_file" ]]; then
        claude_token=$(<"$claude_token_file")
    fi
    if [[ -z "$claude_token" ]]; then
        echo "missing long-lived Claude token" >&2
        echo 'generate one with: export CLAUDE_CODE_OAUTH_TOKEN="$(claude setup-token)"' >&2
        echo "then re-run just agent-auth; optionally save it at $claude_token_file" >&2
        exit 1
    fi
    [[ "$claude_token" != *[[:space:]]* ]] \
        || { echo "Claude token must be one non-empty line without whitespace" >&2; exit 1; }

    if [[ "{{ lab }}" == all ]]; then
        mapfile -t targets < <(jq -r 'to_entries[] | select(.value.kind == "project") | .key' {{ registry }})
    else
        jq -e --arg l "{{ lab }}" '.[$l].kind == "project"' {{ registry }} >/dev/null \
            || { echo "{{ lab }} is not a project lab" >&2; exit 1; }
        targets=("{{ lab }}")
    fi

    umask 077
    for target in "${targets[@]}"; do
        state="{{ store }}/storage/$target/state/agents"
        install -d -m 0700 "$state/codex" "$state/claude" "$state/opencode" "$state/opencode/data"
        install -m 0600 "$codex_auth" "$state/codex/auth.json"
        printf '%s\n' "$claude_token" | install -m 0600 /dev/stdin "$state/claude/oauth-token"
        install -m 0600 "$opencode_auth" "$state/opencode/data/auth.json"
        echo "seeded Codex and opencode logins and the Claude token for $target"
    done

# Rebuild a nix lab in place over SSH, no tofu
[group('lab')]
deploy lab *args:
    nix develop -c nixos-rebuild switch --flake .#{{ lab }} --target-host {{ lab }} --sudo {{ args }}

# Take a new configuration to sleeping labs and leave them as found
[group('lab')]
sync lab="all":
    #!/usr/bin/env bash
    set -euo pipefail
    {{ resolve }}

    # nixos-rebuild needs the guest reachable, so there is no offline path. All
    # this saves is the manual boot, push and shutdown for each sleeping lab.

    if [[ "{{ lab }}" == all ]]; then
        mapfile -t targets < <(jq -r 'to_entries[] | select(.value.distro == "nixos") | .key' {{ registry }})
    else
        targets=("{{ lab }}")
    fi

    failed=()
    for target in "${targets[@]}"; do
        was=$(virsh -c "$TF_VAR_libvirt_uri" domstate "$target" 2>/dev/null || echo undefined)
        echo "==> $target ($was)"

        # A lab already awake is somebody's working lab: switch it in place and
        # leave it running.
        if [[ "$was" == running ]]; then
            just deploy "$target" || failed+=("$target")
            continue
        fi

        just up "$target" || { failed+=("$target"); continue; }

        # It is going straight back down, so stage the generation rather than
        # activating it. Nothing restarts under a live system, and a changed
        # mount lands on the next boot instead of being swapped underneath one.
        if nix develop -c nixos-rebuild boot --flake ".#$target" --target-host "$target" --sudo; then
            echo "$target staged for next boot"
        else
            failed+=("$target")
        fi

        just quiesce "$target" || failed+=("$target")
        rm -f "$HOME/.ssh/cm-"*"@$target:"*
    done

    if (( ${#failed[@]} )); then
        printf 'failed: %s\n' "${failed[*]}" >&2
        exit 1
    fi
    echo "synced: ${targets[*]}"

# Raise a running lab's balloon and online its cpus
[group('vm')]
grow lab mem="" vcpu="":
    #!/usr/bin/env bash
    set -euo pipefail
    {{ resolve }}
    mem="{{ mem }}"; vcpu="{{ vcpu }}"
    [[ -n "$mem" ]]  || mem="$(spec {{ lab }} '.[$l].memory_mib')M"
    [[ -n "$vcpu" ]] || vcpu=$(spec {{ lab }} '.[$l].vcpu')

    want=$(numfmt --from=iec "${mem%[Mm]}$([[ "$mem" =~ [Mm]$ ]] && echo M)" 2>/dev/null || echo 0)
    want=$(( want / 1048576 ))
    (( want == 0 )) && want=${mem%[MmGg]}
    now=$(( $(virsh -c "$TF_VAR_libvirt_uri" dommemstat "{{ lab }}" | awk '/^actual/{print $2}') / 1024 ))
    delta=$(( want - now ))
    if (( delta > 0 )) && [[ "${DLAB_FORCE:-0}" != 1 ]]; then
        avail=$(( $(awk '/^MemAvailable:/ {print $2}' /proc/meminfo) / 1024 ))
        if (( avail - 4096 < delta )); then
            echo "refusing to grow {{ lab }} by ${delta} MiB: only $(( avail - 4096 )) MiB spendable" >&2
            echo "stop another lab first, or override with DLAB_FORCE=1" >&2
            exit 1
        fi
    fi

    virsh -c "$TF_VAR_libvirt_uri" setmem "{{ lab }}" "$mem" --live
    virsh -c "$TF_VAR_libvirt_uri" setvcpus "{{ lab }}" "$vcpu" --live
    virsh -c "$TF_VAR_libvirt_uri" setvcpus "{{ lab }}" "$vcpu" --guest
    sleep 5
    virsh -c "$TF_VAR_libvirt_uri" dominfo "{{ lab }}" | grep -E 'Used memory|CPU\(s\)'

# Boot a lab and wait for it to answer on SSH
[group('vm')]
up lab:
    #!/usr/bin/env bash
    set -euo pipefail
    {{ resolve }}
    mkdir -p "{{ store }}/storage/{{ lab }}/state"
    state=$(virsh -c "$TF_VAR_libvirt_uri" domstate "{{ lab }}" 2>/dev/null || echo undefined)
    if [[ "$state" != running && "${DLAB_FORCE:-0}" != 1 ]]; then
        need=$(spec {{ lab }} '.[$l].current_memory_mib // 4096')
        avail=$(( $(awk '/^MemAvailable:/ {print $2}' /proc/meminfo) / 1024 ))
        reserve=4096
        if (( avail - reserve < need )); then
            echo "refusing to start {{ lab }}: needs ${need} MiB, only $(( avail - reserve )) MiB spendable (${avail} MiB available, ${reserve} MiB reserved for the host)" >&2
            echo "that is the lab's boot balloon target; growing it later costs more." >&2
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
        *)
            # Same recovery the SSH proxy performs: a saved RAM image that will
            # not load leaves a lab you cannot reach, and the disk is intact
            # either way, so discarding it is strictly better than failing.
            if ! err=$(virsh -c "$TF_VAR_libvirt_uri" start "{{ lab }}" 2>&1); then
                info=$(virsh -c "$TF_VAR_libvirt_uri" dominfo "{{ lab }}" 2>/dev/null || true)
                if grep -qi '^Managed save: *yes' <<<"$info"; then
                    echo "{{ lab }}: restore failed, discarding the saved RAM image" >&2
                    echo "  $err" >&2
                    echo "  the disk is intact; this is equivalent to a power cut" >&2
                    virsh -c "$TF_VAR_libvirt_uri" managedsave-remove "{{ lab }}" >/dev/null 2>&1 || true
                    virsh -c "$TF_VAR_libvirt_uri" start "{{ lab }}"
                else
                    echo "$err" >&2
                    exit 1
                fi
            fi
            ;;
    esac
    ip=$(labip {{ lab }})
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
    # grep -q exits on the first match and SIGPIPEs virsh, which pipefail then
    # reports as failure, so read the XML into a variable before matching it.
    xml=$(virsh -c "$TF_VAR_libvirt_uri" dumpxml "{{ lab }}" 2>/dev/null || true)
    if grep -q '<hostdev' <<<"$xml"; then
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
    mkdir -p "{{ store }}/storage/{{ lab }}/state"
    echo "$until" > "{{ store }}/storage/{{ lab }}/state/keepalive"
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
        if [[ "$(virsh -c "$TF_VAR_libvirt_uri" domstate "{{ lab }}" 2>/dev/null)" == "shut off" ]]; then
            # A control master outlives the guest it was opened to, and doctor
            # reports one left for a stopped lab. `just down` clears its own; a
            # lab stopped on the way through an apply or a sync needs the same.
            rm -f "$HOME/.ssh/cm-"*"@{{ lab }}:"*
            exit 0
        fi
        sleep 1
    done
    echo "{{ lab }} did not shut down in 120s; destroying it will lose unflushed writes" >&2
    exit 1

# Release an idle hold early
[group('vm')]
release lab:
    @rm -f "{{ store }}/storage/{{ lab }}/state/keepalive" && echo "{{ lab }} released"

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
        s="{{ store }}/storage/$lab/state"
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
    du -sh {{ store }}/images {{ store }}/ISOs {{ store }}/storage 2>/dev/null || true

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
            # The base is named after the build it came from, so the stamp is
            # what says which file the registry will hand libvirt.
            stamp="{{ store }}/images/$lab-base.store-path"
            if [[ ! -f "$stamp" ]]; then
                bad "$stamp missing, run: just image $lab"
            else
                h=$(basename "$(cat "$stamp")")
                b="{{ store }}/images/$lab-base-${h:0:8}.qcow2"
                if [[ -f "$b" ]]; then ok "$b"; else bad "$b missing, run: just image $lab"; fi
            fi
            # The unstamped name is what a nix lab's base was called before a
            # root became an overlay on it. Nothing reads it any more, and
            # nothing is backed by it — the roots of that era were full copies.
            old="{{ store }}/images/$lab-base.qcow2"
            [[ -f "$old" ]] && printf '  note  %s predates the overlay layout and is unused, rm it to reclaim %s\n' \
                "$old" "$(du -h "$old" | cut -f1)"
        else
            img=$(spec "$lab" '.[$l].source.image')
            case "$img" in
                *://*) ok "$img (remote)" ;;
                *) if [[ -f "{{ store }}/$img" ]]; then ok "$img"; else bad "$img missing"; fi ;;
            esac
        fi
    done

    echo "virtiofs"
    if [[ -x /usr/lib/virtiofsd ]]; then ok "/usr/lib/virtiofsd"; else bad "virtiofsd missing, pacman -S virtiofsd"; fi
    if [[ -f /usr/share/qemu/vhost-user/50-virtiofsd.json ]]; then ok "virtiofsd capability descriptor"; else bad "no vhost-user descriptor, managedsave of a lab with a share will fail"; fi
    # Root spawns this one, and a domain pointing at a path that is gone will
    # not start at all, so a moved checkout has to be caught here.
    wrapper="src/vm/bin/dlab-virtiofsd"
    if [[ -x "$wrapper" ]]; then
        defined=$(virsh -c "$TF_VAR_libvirt_uri" dumpxml --inactive "$(labs | head -1)" 2>/dev/null \
            | sed -n "s:.*<binary path='\(.*\)'/>.*:\1:p")
        if [[ -z "$defined" ]]; then
            bad "domains do not use $wrapper, an unlinked file on a share will make managedsave unrestorable, run: just apply <lab>"
        elif [[ -x "$defined" ]]; then
            ok "$wrapper"
        else
            bad "domains point at $defined, which is not executable; the checkout moved, run: just apply <lab>"
        fi
    else
        bad "$wrapper missing or not executable"
    fi
    for lab in $(labs); do
        if [[ -d "{{ store }}/storage/$lab/state" ]]; then
            [[ "$(stat -c '%u' "{{ store }}/storage/$lab/state")" == "$(id -u)" ]] || bad "{{ store }}/storage/$lab/state is not owned by $(id -un)"
        else
            bad "{{ store }}/storage/$lab/state missing, virtiofsd will refuse to start"
        fi
    done
    ok "state shares for $(labs | wc -l) built labs"

    echo "network"
    live=$(virsh -c "$TF_VAR_libvirt_uri" net-dumpxml "$TF_VAR_network" 2>/dev/null || true)
    gw="$(net .subnet_prefix).$(net .gateway_host)"
    grep -q "address='$gw'" <<<"$live" \
        || bad "$TF_VAR_network is not on $gw, but every nix image has that gateway baked in, run: just apply shared"
    for lab in $(jq -r 'keys[]' {{ registry }}); do
        # Match the address too: a nix lab configures its address statically, so
        # a reservation that moved leaves the guest sitting on the old one.
        grep -q "name='$lab' ip='$(labip "$lab")'" <<<"$live" \
            || bad "$lab has no DHCP reservation at $(labip "$lab"), run: just apply shared"
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
        mkdir -p "{{ store }}/storage/{{ stack }}/state"

        # A root is an overlay, so a base the lab is not already sitting on
        # means tofu replaces that root. Unlinking a volume under a running
        # guest leaves it writing into an inode nothing can reach any more, so
        # take the lab down first — and only then, because an apply that
        # replaces nothing has no business stopping a lab someone is using.
        stamp="{{ store }}/images/{{ stack }}-base.store-path"
        if [[ -f "$stamp" ]]; then
            h=$(basename "$(cat "$stamp")")
            want="{{ store }}/images/{{ stack }}-base-${h:0:8}.qcow2"
            have=""
            if xml=$(virsh -c "$TF_VAR_libvirt_uri" vol-dumpxml "{{ stack }}.qcow2" "$TF_VAR_pool" 2>/dev/null); then
                have=$(sed -n '/<backingStore>/,/<\/backingStore>/p' <<<"$xml" \
                    | sed -n 's:.*<path>\(.*\)</path>.*:\1:p')
            fi
            if [[ "$want" != "$have" ]]; then
                just quiesce "{{ stack }}"
            fi
        fi

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
    [[ "{{ stack }}" == shared ]] || mkdir -p "{{ store }}/storage/{{ stack }}/state"
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
        mkdir -p "{{ store }}/storage/{{ stack }}/state"
        virsh -c "$TF_VAR_libvirt_uri" managedsave-remove "{{ stack }}" 2>/dev/null || true
        just quiesce "{{ stack }}"
    fi
    tofu -chdir="$dir" destroy -auto-approve
    tofu -chdir="$dir" apply -auto-approve
