# Labs

Every VM in the lab lives in the `dlab` namespace and is described by one entry in
`src/labs/labs.json`. Nothing about a lab is spread across `.env`, the justfile and a per-lab
`variables.tf` any more; the registry is the single source of truth and everything else derives from
it.

There are two kinds, distinguished by the `kind` field rather than by naming convention:

```text
dlab-ubuntu  dlab-gentoo  dlab-nixos     distro sandboxes
dlab-portfolio  dlab-archtex  dlab-nsql  project workspaces
dlab-dotfiles                            project workspace
dlab-cuda                                GPU workspace
```

`nixos-main` is bare metal, is not reachable over SSH, and is not part of this.

## The registry

`src/labs/labs.json` holds one object per lab. `src/vm/modules/lab-registry/` turns it into a
validated map and derives the MAC and the image URL. Both the shared stack and every lab stack
instantiate that module, which is why they cannot disagree about a lab's address.

`src/labs/network.json` sits beside it and holds the four facts that are about the network rather
than about a lab: subnet prefix, prefix length, the gateway's octet and the DNS domain. The registry
module reads it directly instead of taking it as a variable, and `flake.nix` reads the same file, so
a NixOS image and the DHCP reservation for it cannot end up on different subnets.

A lab's tofu stack is five lines that look the entry up by name. `.env` holds only the six values
that are genuinely per-machine — libvirt URI, paths, pool, network, username, SSH keys — and does not
grow when you add a lab.

Validation lives in the type, so `tofu validate` catches a bad entry rather than the module failing
three resources deep. Notably `gpu_pci` being non-empty forbids `idle.action = "managedsave"`, because
libvirt refuses to serialise a domain with an assigned PCI device.

## Adding a lab

```bash
just new-lab dlab-foo project nixos nix
just lab-keys dlab-foo          # only if it needs secrets
just agent-auth dlab-foo        # seed Codex and opencode logins, and a long-lived Claude token
just image dlab-foo             # only for nix labs
just apply shared               # installs its DHCP reservation
just apply dlab-foo
```

For a NixOS lab, add `src/labs/nixos/hosts/dlab-foo.nix` — an import list and nothing else. The
module set is in `src/labs/nixos/modules/`.

## NixOS labs are built, not installed

There is no serial-console install. `flake.nix` at the repository root derives
`nixosConfigurations` from the registry and builds a disk image per lab. The flake must sit at the
root because a flake cannot read above its own directory and it needs `src/labs/labs.json`.

Two consequences worth knowing:

- A `.nix` file you have not staged is **invisible** to the build, because the `git+file` fetcher
  copies only tracked files. `just image` refuses when anything below the flake root is untracked
  rather than letting you debug a config that looks correct.
- Editing anything in the repository changes the flake's `self`, so secrets are referenced through
  `builtins.path` on just the secrets directory.

The image module is imported from `base.nix` rather than reached through `extendModules`. If it only
existed in the extended module, `system.build.toplevel` — what `nixos-rebuild --target-host` builds —
would have no bootloader and no root filesystem. Importing it keeps the deployed system and the built
image as one closure.

`just image` builds, installs to `images/<lab>-base.qcow2`, resizes it to the registry's
`disk_size_bytes`, and records the store path so a rebuild is detectable. The guest's `growpart` and
`systemd-growfs-root` expand the root filesystem on first boot, so a 5 GiB image becomes a 64 GiB
disk without any provisioning step.

Day two never goes through tofu:

```bash
just deploy dlab-nsql
```

builds on the host and pushes the closure. Because guests never fetch from `cache.nixos.org`
themselves, a local binary cache is unnecessary.

## Labs are off by default

`running` and `autostart` are false. A lab starts when you connect to it:

```bash
ssh dlab-nsql
```

`src/vm/bin/dlab-ssh-proxy` is the `ProxyCommand`. If the lab is running and answering it execs
straight through; otherwise it takes a lock, starts or restores the lab, waits for SSH and then
connects. Addresses come from the registry, so there is no lease polling.

## Addresses are decided before the guest boots

A lab's address is `network.json`'s prefix plus its `net.host` octet. That is fixed at build time,
so a NixOS lab does not ask for it: `net.nix` writes one static systemd-networkd link, and
`networking.useDHCP` is off.

The cost of asking was not small. dhcpcd took **7.6s of every cold boot** — 46% of userspace, and on
the critical chain, because `dlab-project.service` waits for `network-online.target`. Almost none of
it was the DHCP exchange itself: it was ARP conflict probing for an address no other guest can be
handed, then waiting for IPv6 router advertisements a NAT network with no IPv6 will never send.

```text
multi-user.target @16.433s          before                 after
  └─dhcpcd.service @8.741s +7.581s  ─────────────────────  gone
```

Two things follow:

- The reservations in the shared stack stay. They are what makes an address the lab's to bake in, and
  the cloud and iso labs — Ubuntu, Gentoo — still lease normally.
- Nothing probes for a conflict any more, so two labs on one octet would simply collide in silence.
  `just doctor` checks that octets are unique, that each reservation is at the address the image
  expects, and that the network's gateway is the one the images route through.

`just ip` and `just vms` read the registry rather than `virsh domifaddr --source lease`; a static
guest has no lease to report.

It refuses to start a lab the host cannot afford, printing what is awake and how to stop it.
`DLAB_FORCE=1` overrides.

If a restore fails, the saved RAM image is discarded and the lab is cold-started — the disk is intact,
so this is equivalent to a power cut and strictly better than a lab you cannot reach. It logs to
`~/.local/state/dlab/<lab>.log` and leaves a breadcrumb.

## Labs stop themselves

A guest timer touches two files on the state share every 30 seconds: `alive` always, and `busy` while
the lab is doing something. The host reads their **mtimes**, which virtiofs passthrough stamps from
the host kernel — so a guest whose clock is hours stale after a restore cannot mislead the stopper.
`busy` is never removed, only touched, so its mtime is the last moment the lab was busy.

Busy means any of: a login session, an established inbound TCP connection on any port, load average
at or above 0.30, a CPU delta, more than 20 MiB of disk or network throughput in the window, or an
unexpired keepalive. The throughput term is the one that matters most — a `nix build` pulling
substitutes sits in S state with a load average near zero and would otherwise be saved mid-download.

```bash
just idle                  # what the stopper sees
just hold dlab-archtex 3h  # block it
just release dlab-archtex
just down dlab-nsql        # stop now, using the registry's action
```

Wrap long unattended work in `dlab-run` inside the guest; it holds a keepalive for the command's
lifetime and is more reliable than any heuristic.

Install the host side once:

```bash
sudo cp src/vm/systemd/dlab-idle-stop.{service,timer} /etc/systemd/system/
sudo cp src/vm/systemd/dlab-tmpfiles.conf /etc/tmpfiles.d/dlab.conf
sudo systemd-tmpfiles --create /etc/tmpfiles.d/dlab.conf
sudo systemctl daemon-reload
sudo systemctl enable --now dlab-idle-stop.timer
```

### ControlMaster and managedsave

The SSH config multiplexes connections so an editor opening several at once does not queue behind one
`ProxyCommand`. That collides with suspending labs: a master persists after the last session, and if
the lab is saved underneath it the transport dies while the socket file remains. Every later
connection then tries the dead master first and burns a long timeout — three minutes against six
seconds, measured.

`just down` and the idle stopper delete the socket when they stop a lab, and `ControlPersist` is one
minute to bound the window. If you ever stop a lab by other means, `rm ~/.ssh/cm-*@<lab>:*`.

## Memory is dynamic, and the balloon is the cap

The virtio balloon works in both directions and genuinely returns memory to the host. Measured on a
lab holding 4228 MiB of host RSS, `virsh setmem --live 2G` brought it down to 736 MiB.

What matters is `autodeflate`. With it **on**, a guest under memory pressure deflates its own balloon
and climbs back up to `<memory>` unbidden — a lab configured with 12 GiB and a 6 GiB balloon target
was measured at 11.6 GiB of host RSS, with `virsh dommemstat` showing the target had moved by itself
from 6 GiB to 7.9 GiB. With it **off**, the balloon is a hard ceiling: a guest told to fill 5 GiB
against a 3 GiB target left host RSS at 3123 MiB.

These labs run `autodeflate='off'`, so `current_memory_mib` is a real cap on what the lab can cost
the host, and `just grow` raises it when you want more.

The tradeoff is deliberate. Capping pushes memory pressure inside the guest rather than onto the
host, so a lab that over-allocates becomes slow or unreachable while the host stays healthy — which
is the right way round, since a host OOM takes your desktop with it. NixOS labs run guest zram to
soften that; the cloud images do not.

`memory_mib` remains the number the admission guard uses, because it is the worst case a lab can
reach if you grow it. Note the guard checks `MemAvailable` at start time while RSS grows lazily
afterwards, so three labs can each pass and then contend — keep an eye on `just vms` if you run
several at once.

`virsh setmem --live` works in both directions inside the ceiling. CPUs need
`virsh setvcpus --live --guest` — plain `--live` leaves them present but offline, because all vCPUs
exist from boot and no `add` uevent fires.

```bash
just grow dlab-archtex 16G 12
```

## Work survives, roots do not

Each project lab has two extra devices:

- `/home/fredrir` — a qcow2 owned by the **shared** stack, so `just rebuild` cannot take it with the
  lab. It is mounted as the home directory itself, so a checkout sits at `~/<repo>` and shell state,
  caches and editor servers survive a rebuild along with it. The volume is still named
  `<lab>-work.qcow2` and sized by `work_disk_bytes`; only the mount point moved.
- `/var/lib/dlab-state` — a small virtiofs share of `storage/<lab>/state/`, carrying the age
  identity, the SSH host key, agent login state and idle markers. It is the only thing the host and
  guest share directly.

Destroying a running domain force-kills it and ext4 loses whatever is still in page cache — that
silently zero-filled a checkout's refs once. The domain now requests a guest shutdown before
undefine, and the justfile quiesces a lab first. If a checkout is ever unusable the clone unit moves
it aside as `<name>.broken.<timestamp>` and reclones; it never deletes anything.

## The lab shell

A project lab's home disk is a freshly made ext4 filesystem, so the first login landed in
`zsh-newuser-install` — the interactive "you have no startup files" menu — twice preceded by
`can't find terminal definition for xterm-ghostty`. The terminfo half is one line in `core.nix` and
applies to every lab, distro sandboxes included. The other half is fixed by shipping the shell
instead of leaving it to the home disk.

`src/labs/nixos/shell/` holds the configuration and `shell.nix` installs it:

```text
/etc/zsh/dlab/zshrc          the loader, linked into the home disk as ~/.zshrc
/etc/zsh/dlab/conf.d/*.zsh   shipped drop-ins, read-only, replaced by `just deploy`
~/.config/zsh/conf.d/*.zsh   yours, on the persistent home disk, read last so it wins
```

Only `kind = "project"` labs get it. A distro sandbox keeps the shell its distro ships, which is the
whole point of a distro sandbox.

Four layers load in that order, and knowing which one owns a setting saves editing the wrong file:

1. NixOS's generated `/etc/zshrc` — the direnv hook, `dircolors`, autosuggestions and syntax
   highlighting, each a module option set in `shell.nix` rather than a line written by hand.
   `programs.zsh.promptInit` is cleared there, because the prompt arrives with the framework below.
2. oh-my-zsh, which the loader sources immediately after `05-ohmyzsh.zsh` has chosen the plugins —
   the same order the workstation's `.zshrc` uses, and the only order that works, since omz reads
   `$plugins` as it loads. It brings `compinit`, the plugin set, the theme, and fzf's key bindings
   and fuzzy completion.
3. The rest of the shipped `conf.d` — colors, environment, history, aliases, completion styles and
   the fzf rebinding. These land *after* omz on purpose: it is what makes `gl` mean `git log` here
   rather than omz's `git pull`.
4. Your own `conf.d`, for a tweak that belongs to one lab.

oh-my-zsh comes from the flake pin as a read-only store path rather than a `~/.oh-my-zsh` clone, so
`$ZSH` updates with a deploy and cannot drift. Four consequences are worth knowing, and every one of
them is why `shell.nix` looks the way it does:

- omz notices `$ZSH` is unwritable and moves its cache and completion dump to `~/.cache/oh-my-zsh`,
  on the persistent home disk. Its self-update is inert for the same reason — the checker returns
  early when `$ZSH` is not a git work tree, so `mode reminder` never fires.
- `programs.zsh.enableGlobalCompInit` is **off**. omz puts each enabled plugin's directory on `fpath`
  and then runs `compinit` itself; the global one runs before all of that, so it would dump a cache
  built from an `fpath` missing exactly the plugins that came to extend it, and omz would rebuild it
  anyway. The cost of the layering is that a hand-written `~/.zshrc` which does not source omz gets
  no completion — check `$+functions[compdef]` if you write one. A login costs about 60ms.
- `programs.fzf` is **off** and `FZF_BASE` points into the store instead, because omz's fzf plugin
  sources the same key bindings and completion. Enabling both would do the work twice.
- `ZSH_CUSTOM` is inside that read-only path, so the `$ZSH/custom/plugins/...` probes in
  `05-ohmyzsh.zsh` stay false by design. autosuggestions and syntax highlighting come from the two
  NixOS options instead, which is why the file still loads them without finding them there.

`~/.zshrc` is a symlink to the shipped loader, planted by `dlab-shell-home.service` and only when
nothing is there. A real file at that path is left alone and logged: `dlab-dotfiles` checks out the
dotfiles repository itself, whose `setup.sh` plants its own `~/.zshrc`, and a lab that fought its own
subject would be worthless. `/etc/zshrc` applies either way, so nothing is left with an unconfigured
shell.

To change the shell everywhere, add or edit a numbered file under `src/labs/nixos/shell/conf.d/`:

```bash
just deploy dlab-nsql   # a lab that is awake
just sync               # the sleeping ones, left as found
```

Nothing is copied into the home disk, so a lab cannot drift from the flake — the drop-ins are read
out of `/etc`, which is part of the system closure and replaced whole on every switch.

## The lab editor

Neovim needs neither a wrapper nor a plugin manager here, because it already reads a system
configuration directory. `/etc/xdg/nvim` is second in `runtimepath`, immediately behind
`~/.config/nvim`, and nvim sources `sysinit.vim` from there before any user configuration. So
`nvim.nix` is three `environment.etc` entries and no service:

```text
/etc/xdg/nvim/sysinit.vim       hands over to a user config, or loads the lab's
/etc/xdg/nvim/lua/dlab/         the configuration itself, from src/labs/nixos/nvim/
/etc/xdg/nvim/pack/dlab/start/  plugins as store paths, loaded by nvim's own packages
```

Plugins are `vimUtils.packDir` over `pkgs.vimPlugins`, so they are part of the closure a deploy
pushes: nothing is cloned at runtime and a lab with no network still has a working editor. The set is
four — treesitter, catppuccin, fzf-lua and gitsigns — and treesitter is there for the grammars and
their highlight queries, which core nvim only bundles for five languages. `vim.treesitter.start()`
runs per buffer from an autocommand, so none of the plugin's own Lua is involved.

Language servers are a table in `lua/dlab/lsp.lua`, each enabled only when its binary is on `PATH`.
That is what keeps the editor honest about the lab it is on: `dlab-dotfiles` starts `nil`, `lua_ls`,
`ruff` and `rust_analyzer` because its host file imports the lua, python and rust modules, and
nothing else is configured for a language it cannot build. There is no `nvim-lspconfig` and no
completion plugin — `vim.lsp.config` and `vim.lsp.completion` are core API in nvim 0.11 upwards, and
`K`, `grn`, `gra`, `grr` and `gri` are already bound by default.

Yanking reaches the workstation clipboard: a lab has no display server, so the `+` register is wired
to OSC 52 and travels back over the SSH connection. Paste deliberately answers from the unnamed
register rather than querying the terminal, since a terminal that refuses clipboard reads would make
every `p` wait for a reply that never comes.

There are two ways to change it on the lab, and they differ in scope:

- `~/.config/nvim/after/plugin/*.lua` — runs after the lab config, adds to it, changes nothing else.
  This is the equivalent of the shell's `~/.config/zsh/conf.d`.
- `~/.config/nvim/init.lua` — a full takeover. `sysinit.vim` sees it, drops `/etc/xdg/nvim` out of
  `packpath` so the lab's plugins do not load underneath it, and stands down. This is the case that
  matters on `dlab-dotfiles`, where the checkout under test is a Neovim configuration.

## Agent CLIs and skills

Every NixOS lab with `kind = "project"` includes `codex`, `claude`, `opencode`, and
`dlab-agent-status`. The CLI packages come from the flake's pinned nixpkgs, so an image rebuild or
`just deploy <lab>` updates them together with the rest of the guest. Because the pin is what decides
the version, guests set `OPENCODE_DISABLE_AUTOUPDATE=1`; `opencode upgrade` cannot write to the
read-only store path anyway.

Skills have three layers:

1. `src/agents/skillsets.json` has `shared`, which every project receives.
2. The same file has reusable named sets. A project selects them with `agent.skillsets` in
   `src/labs/labs.json`; this is how Rust and frontend skills are shared by several, but not all,
   projects.
3. `agent.skills` in the registry adds skills to only that project.

The full skill directories are vendored below `src/agents/skills/`. On boot, the guest links the
resolved set into `<repo>/.agents/skills`. Claude Code currently discovers project skills below
`.claude/skills`, so dlab exposes the same directories there as well. Existing project-owned skills
win on a name collision; dlab only creates, updates, or removes links that point to its own Nix store
paths. Generated links are added to the checkout's local `.git/info/exclude` and do not dirty the
repository.

opencode needs no third copy: it walks up from the working directory and auto-loads
`.agents/skills/<name>/SKILL.md` and `.claude/skills/<name>/SKILL.md`, which is exactly what the
guest already provisions. Its own conventions, `.opencode/skill(s)/` in a project and
`~/.config/opencode/skill(s)/`, stay free for skills dlab does not manage.

For a project without a configured repository, such as `dlab-cuda`, `~` is the project root. For
cloned projects, the root is `~/<repo>`.

Codex, Claude and opencode keep credentials in persistent, per-lab directories below
`storage/<lab>/state/agents/`. Codex and opencode can reuse the host login file. Claude's ordinary
login uses a rotating refresh token, so cloning `~/.claude/.credentials.json` across VMs is not
durable. Generate the supported one-year, inference-only token once and seed every project with it:

```bash
export CLAUDE_CODE_OAUTH_TOKEN="$(claude setup-token)"
just agent-auth                 # all project labs
just agent-auth dlab-archtex   # one project lab
unset CLAUDE_CODE_OAUTH_TOKEN
```

Instead of keeping the token in the shell, save the single token line with mode `0600` at
`~/.claude/oauth-token`; `just agent-auth` reads that path by default. The recipe copies
`~/.codex/auth.json`, `~/.local/share/opencode/auth.json` and the Claude token with mode `0600`. In
the guest, `~/.codex` and `~/.claude` point at the corresponding state directories, and the packaged
`claude` launcher reads the token without putting it in the image. opencode splits its two XDG
directories, so `~/.local/share/opencode` (credentials, session database) and `~/.config/opencode`
(configuration) are linked separately; only `auth.json` is seeded, the rest is the guest's own. Run
`dlab-agent-status` inside a guest to show all three CLI versions, all three login states, and the
discovered project skills.

These files are bearer credentials. They stay below the gitignored `storage/` tree, but backups of
that tree must be protected like the accounts themselves. Re-run `just agent-auth` after signing in
again on the host or rotating credentials. Codex also supports API-key and enterprise access-token
login. See the official [Codex authentication](https://learn.chatgpt.com/docs/auth),
[Claude Code authentication](https://code.claude.com/docs/en/authentication) and
[opencode providers](https://opencode.ai/docs/providers/) documentation.

## Secrets

`storage/<lab>/state/agenix.key` is the root of trust. It is generated by `just lab-keys`, lives only
on the share, and never enters git or the nix store. Ciphertext lives in
`src/labs/nixos/secrets/<lab>/`, encrypted to your keys plus that lab's identity, so a fresh clone
plus one key file reproduces a lab.

To add a secret, list it in the lab's `secrets` array and encrypt it to the same recipients as the
existing ones. It appears at `/run/agenix/<name>` owned by `fredrir`.

Push access uses a per-repository deploy key with write access, so a lab authenticates as itself
rather than as the account. `ssh -T git@github.com` from a lab answers `Hi fredrir/<repo>!`, not with
your username.

## Base images

Cloud labs pin a local image under `ISOs/` rather than fetching over HTTPS. Two reasons, and only one
of them is speed:

Gentoo's `autobuilds/` directory keeps only the most recent handful of builds, so a pinned URL
eventually 404s and a fresh create stops working. Gentoo publishes
`latest-di-amd64-cloudinit.txt`, but it is a signed text file rather than a redirect, so it cannot be
used as an image source directly. Ubuntu's release URLs are stable and pin only for speed — fetching
runs at roughly 11 MB/s, so a 1.9 GiB image costs about 2m45s against roughly three seconds for a
local copy.

The path lives in the lab's registry entry, relative to `storage_path`. Anything with a scheme is
passed through unchanged, so a remote URL still works.

To update one, download it, verify against the publisher's signed digests, then repoint the registry
and rebuild:

```bash
build=20260811T083102Z
base=https://distfiles.gentoo.org/releases/amd64/autobuilds/$build
curl -O --output-dir ISOs "$base/di-amd64-cloudinit-$build.qcow2"
curl -s "$base/di-amd64-cloudinit-$build.qcow2.DIGESTS" | grep -A1 "SHA512 HASH"
sha512sum ISOs/di-amd64-cloudinit-$build.qcow2
just rebuild dlab-gentoo
```

Change the image only as part of a rebuild. A cloud lab's root volume is a qcow2 overlay on that exact
file, so swapping the backing image under a running lab corrupts it silently. NixOS labs sidestep this
entirely: their root is a full copy, not an overlay, precisely because a flake-built image changes on
every build.

## Adopting a VM created outside OpenTofu

A domain built by hand cannot simply be applied over — the pool already holds a volume of that name
and the domain already exists. Either import it:

```bash
tofu import module.vm.libvirt_domain.vm <uuid>
```

which requires the configuration to match the existing XML exactly, or remove the old VM first:

```bash
virsh -c qemu:///system destroy <name>
virsh -c qemu:///system undefine --nvram <name>
virsh -c qemu:///system vol-delete --pool images <name>.qcow2
```

Copy the disk first if the installed system matters.
