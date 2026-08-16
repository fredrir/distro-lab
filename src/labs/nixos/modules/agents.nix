{
  config,
  lib,
  pkgs,
  spec,
  ...
}:

let
  user = "fredrir";
  group = "fredrir";
  homeDir = "/home/${user}";
  workDir = "${homeDir}/work";
  stateDir = "/var/lib/dlab-state";
  stateMountUnit = "var-lib-dlab\\x2dstate.mount";
  workMountUnit = "home-${user}-work.mount";

  enabled = spec.kind == "project";
  repo = spec.repo or null;
  repoName =
    if repo == null then
      null
    else
      lib.removeSuffix ".git" (lib.last (lib.splitString "/" (toString repo)));
  projectDir = if repoName == null then workDir else "${workDir}/${repoName}";

  catalog = builtins.fromJSON (builtins.readFile ../../../agents/skillsets.json);
  skillRoot = ../../../agents/skills;
  agentConfig = spec.agent or { };
  requestedSets = agentConfig.skillsets or [ ];
  directSkills = agentConfig.skills or [ ];
  unknownSets = lib.filter (name: !(builtins.hasAttr name catalog.sets)) requestedSets;
  resolvedSkills = lib.unique (
    catalog.shared ++ lib.concatMap (name: catalog.sets.${name} or [ ]) requestedSets ++ directSkills
  );
  skillExists = name: builtins.pathExists (skillRoot + "/${name}/SKILL.md");
  missingSkills = lib.filter (name: !(skillExists name)) resolvedSkills;
  invalidSkillNames = lib.filter (
    name: builtins.match "[a-z0-9][a-z0-9-]*" name == null
  ) resolvedSkills;
  availableSkills = lib.filter skillExists resolvedSkills;
  skillEntries = map (name: {
    inherit name;
    path = builtins.path {
      path = skillRoot + "/${name}";
      name = "dlab-agent-skill-${name}";
    };
  }) availableSkills;
  skillArguments = lib.concatMapStringsSep " " (
    skill: "${lib.escapeShellArg skill.name} ${lib.escapeShellArg (toString skill.path)}"
  ) skillEntries;
  desiredSkillNames = lib.concatStringsSep " " availableSkills;

  claudeCli = pkgs.writeShellApplication {
    name = "claude";
    runtimeInputs = [ pkgs.coreutils ];

    text = ''
      token_file=${stateDir}/agents/claude/oauth-token
      if [[ -s "$token_file" ]]; then
        CLAUDE_CODE_OAUTH_TOKEN="$(cat "$token_file")"
        export CLAUDE_CODE_OAUTH_TOKEN
      fi

      exec ${pkgs.claude-code}/bin/claude "$@"
    '';
  };

  agentStatus = pkgs.writeShellApplication {
    name = "dlab-agent-status";
    runtimeInputs = [
      claudeCli
      pkgs.codex
      pkgs.coreutils
      pkgs.findutils
    ];

    text = ''
      echo "Codex: $(codex --version)"
      codex login status || true
      echo
      echo "Claude: $(claude --version)"
      claude auth status --text || true
      echo
      echo "Project skills:"
      find -L ${lib.escapeShellArg projectDir}/.agents/skills -mindepth 2 -maxdepth 2 \
        -name SKILL.md -printf '  %h\n' 2>/dev/null | sort
    '';
  };
in
{
  config = lib.mkIf enabled {
    assertions = [
      {
        assertion = unknownSets == [ ];
        message = "Unknown agent skillsets for ${config.networking.hostName}: ${lib.concatStringsSep ", " unknownSets}";
      }
      {
        assertion = missingSkills == [ ];
        message = "Missing vendored agent skills for ${config.networking.hostName}: ${lib.concatStringsSep ", " missingSkills}";
      }
      {
        assertion = invalidSkillNames == [ ];
        message = "Invalid agent skill names for ${config.networking.hostName}: ${lib.concatStringsSep ", " invalidSkillNames}";
      }
    ];

    environment.systemPackages = [
      claudeCli
      pkgs.codex
      agentStatus
    ];

    nixpkgs.config.allowUnfreePredicate = package: lib.getName package == "claude-code";

    systemd.services.dlab-agent-home = {
      description = "Attach persistent Codex and Claude configuration";
      wantedBy = [ "multi-user.target" ];
      after = [ stateMountUnit ];
      requires = [ stateMountUnit ];

      unitConfig.ConditionPathIsMountPoint = stateDir;

      path = [ pkgs.coreutils ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };

      script = ''
        state=${stateDir}/agents
        home=${homeDir}

        install -d -m 0700 -o ${user} -g ${group} "$state" "$state/codex" "$state/claude"

        link_config_dir() {
          source=$1
          target=$2

          if [ -L "$target" ] && [ "$(readlink "$target")" = "$source" ]; then
            return
          fi

          if [ -e "$target" ] || [ -L "$target" ]; then
            stamp=$(date +%Y%m%dT%H%M%S)
            if [ -d "$target" ] && [ ! -L "$target" ]; then
              cp -a --no-clobber "$target/." "$source/"
            fi
            mv "$target" "$target.dlab-unmanaged.$stamp"
          fi

          ln -s "$source" "$target"
          chown -h ${user}:${group} "$target"
        }

        link_config_dir "$state/codex" "$home/.codex"
        link_config_dir "$state/claude" "$home/.claude"
      '';
    };

    systemd.services.dlab-agent-skills = {
      description = "Provision managed project agent skills";
      wantedBy = [ "multi-user.target" ];
      after = [
        workMountUnit
        "dlab-work-perms.service"
      ]
      ++ lib.optional (repo != null) "dlab-project.service";
      requires = [
        workMountUnit
        "dlab-work-perms.service"
      ]
      ++ lib.optional (repo != null) "dlab-project.service";

      unitConfig.ConditionPathIsMountPoint = workDir;

      path = with pkgs; [
        coreutils
        findutils
        git
        gnugrep
      ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = user;
        Group = group;
      };

      script = ''
        project=${lib.escapeShellArg projectDir}
        agents_skills="$project/.agents/skills"
        claude_skills="$project/.claude/skills"
        desired=" ${desiredSkillNames} "
        exclude_agents_link=0
        exclude_claude_link=0

        mkdir -p "$project/.agents" "$project/.claude"

        if [ ! -e "$agents_skills" ] && [ ! -L "$agents_skills" ]; then
          if [ -e "$claude_skills" ] || [ -L "$claude_skills" ]; then
            ln -s ../.claude/skills "$agents_skills"
            exclude_agents_link=1
          else
            mkdir -p "$agents_skills"
          fi
        fi

        if [ ! -e "$claude_skills" ] && [ ! -L "$claude_skills" ]; then
          ln -s ../.agents/skills "$claude_skills"
          exclude_claude_link=1
        fi

        exclude_pattern() {
          pattern=$1
          git_dir=$(git -C "$project" rev-parse --git-dir 2>/dev/null || true)
          # A project without a Git checkout (for example dlab-cuda's plain
          # ~/work root) has no per-repository exclude file to update.  Make
          # that a successful no-op so `set -e` does not abort provisioning.
          [ -n "$git_dir" ] || return 0
          case "$git_dir" in
            /*) ;;
            *) git_dir="$project/$git_dir" ;;
          esac
          exclude="$git_dir/info/exclude"
          mkdir -p "$(dirname "$exclude")"
          touch "$exclude"
          grep -Fqx "$pattern" "$exclude" || echo "$pattern" >> "$exclude"
        }

        [ "$exclude_agents_link" -eq 0 ] || exclude_pattern "/.agents/skills"
        [ "$exclude_claude_link" -eq 0 ] || exclude_pattern "/.claude/skills"

        install_managed_skills() {
          skill_dir=$1
          mkdir -p "$skill_dir"

          for link in "$skill_dir"/*; do
            [ -L "$link" ] || continue
            target=$(readlink "$link")
            case "$target" in
              /nix/store/*-dlab-agent-skill-*)
                name=$(basename "$link")
                case "$desired" in
                  *" $name "*) ;;
                  *) rm "$link" ;;
                esac
                ;;
            esac
          done

          set -- ${skillArguments}
          while [ "$#" -gt 0 ]; do
            name=$1
            source=$2
            shift 2
            link="$skill_dir/$name"

            if [ -e "$link" ] || [ -L "$link" ]; then
              if [ -L "$link" ]; then
                target=$(readlink "$link")
                case "$target" in
                  /nix/store/*-dlab-agent-skill-*) ln -sfn "$source" "$link" ;;
                  *) echo "keeping project-owned skill link: $link" ;;
                esac
              else
                echo "keeping project-owned skill: $link"
              fi
            else
              ln -s "$source" "$link"
            fi

            exclude_pattern "/.agents/skills/$name"
            exclude_pattern "/.claude/skills/$name"
          done
        }

        install_managed_skills "$agents_skills"

        agents_real=$(readlink -f "$agents_skills")
        claude_real=$(readlink -f "$claude_skills")
        if [ "$agents_real" != "$claude_real" ]; then
          install_managed_skills "$claude_skills"
        fi
      '';
    };
  };
}
