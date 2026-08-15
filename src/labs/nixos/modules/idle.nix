{ pkgs, ... }:

let
  stateDir = "/var/lib/dlab-state";
  ioThresholdBytes = 20 * 1024 * 1024;

  idleMark = pkgs.writeShellApplication {
    name = "dlab-idle-mark";

    runtimeInputs = with pkgs; [
      coreutils
      gawk
      iproute2
      systemd
    ];

    text = ''
      state=${stateDir}
      [ -d "$state" ] || exit 0

      touch "$state/alive"

      busy=0

      if [ -f "$state/keepalive" ]; then
          until=$(cat "$state/keepalive" 2>/dev/null || echo 0)
          case "$until" in
              (*[!0-9]*|"") until=0 ;;
          esac
          [ "$until" -gt "$(date +%s)" ] && busy=1
      fi

      if [ "$(loginctl list-sessions --no-legend 2>/dev/null | wc -l)" -gt 0 ]; then
          busy=1
      fi

      if [ "$(ss -Htn state established 2>/dev/null | grep -cv '127\.0\.0\.1')" -gt 0 ]; then
          busy=1
      fi

      load=$(awk '{print $1}' /proc/loadavg)
      if awk -v l="$load" 'BEGIN { exit !(l >= 0.30) }'; then
          busy=1
      fi

      disk=$(awk '{s += $6 + $10} END {print (s + 0) * 512}' /proc/diskstats)
      net=$(cat /sys/class/net/*/statistics/rx_bytes /sys/class/net/*/statistics/tx_bytes 2>/dev/null \
            | awk '{s += $1} END {print s + 0}')
      cur=$((disk + net))

      prev_file=/run/dlab-io-prev
      if [ -f "$prev_file" ]; then
          prev=$(cat "$prev_file" 2>/dev/null || echo 0)
          case "$prev" in
              (*[!0-9]*|"") prev=$cur ;;
          esac
          if [ "$((cur - prev))" -gt ${toString ioThresholdBytes} ]; then
              busy=1
          fi
      fi
      printf '%s' "$cur" > "$prev_file"

      if [ "$busy" -eq 1 ] || [ ! -f "$state/busy" ]; then
          touch "$state/busy"
      fi
    '';
  };
in
{
  systemd.services.dlab-idle-mark = {
    description = "Publish dlab idle markers to the host state share";

    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${idleMark}/bin/dlab-idle-mark";
    };
  };

  systemd.timers.dlab-idle-mark = {
    description = "Publish dlab idle markers every 30s";
    wantedBy = [ "timers.target" ];

    timerConfig = {
      OnBootSec = "15s";
      OnUnitActiveSec = "30s";
      AccuracySec = "5s";
    };
  };

  environment.systemPackages = [
    (pkgs.writeShellApplication {
      name = "dlab-run";
      runtimeInputs = [ pkgs.coreutils ];

      text = ''
        state=${stateDir}
        if [ ! -d "$state" ]; then
            echo "dlab-run: $state is not mounted, running without a keepalive" >&2
            exec "$@"
        fi

        holder=""
        trap 'rm -f "$state/keepalive"; [ -n "$holder" ] && kill "$holder" 2>/dev/null; true' EXIT

        while true; do
            date -d '+5 minutes' +%s > "$state/keepalive"
            sleep 60
        done &
        holder=$!

        "$@"
      '';
    })
  ];
}
