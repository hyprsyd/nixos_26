{ config, pkgs, lib, ... }:

let
  cleanDnsBypass = pkgs.writeShellScript "clean-dns-bypass" ''
    set -euo pipefail
    export PATH="${lib.makeBinPath [ pkgs.iptables pkgs.openresolv pkgs.iproute2 pkgs.gnugrep pkgs.gnused pkgs.coreutils ]}"

    remove_bypass_rules() {
      local bin="$1" chain="$2"
      while "$bin" -t nat -S "$chain" 2>/dev/null | grep -q "dns-rescue-bypass"; do
        local rule
        rule=$("$bin" -t nat -S "$chain" | grep "dns-rescue-bypass" | head -n 1 | sed 's/^-A /-D /')
        # shellcheck disable=SC2086
        "$bin" -t nat $rule || break
      done
    }

    remove_bypass_rules iptables OUTPUT
    remove_bypass_rules iptables PREROUTING
    remove_bypass_rules ip6tables OUTPUT
    resolvconf -f -d tailscale 2>/dev/null || true
    resolvconf -f -d NetworkManager 2>/dev/null || true
    resolvconf -f -d emergency-fallback 2>/dev/null || true
    printf "search taile1c034.ts.net\nnameserver 127.0.0.1\nnameserver ::1\n" | resolvconf -x -a lo.adguardhome
  '';

  adguardPostStart = pkgs.writeShellScript "adguardhome-post-start" ''
    set -euo pipefail
    export PATH="${lib.makeBinPath [ pkgs.iproute2 pkgs.gnugrep pkgs.coreutils ]}"

    # Verify AdGuardHome stays alive and binds UDP :53 (prevents Type=simple false-positive starts)
    bound=0
    for _ in 1 2 3 4 5 6 7 8; do
      if [[ -n "''${MAINPID:-}" ]] && ! kill -0 "$MAINPID" 2>/dev/null; then
        echo "AdGuardHome exited prematurely during startup" >&2
        exit 1
      fi
      if ss -Hulpn 2>/dev/null | grep -qE '127\.0\.0\.1:53\b'; then
        bound=1
        break
      fi
      sleep 0.5
    done

    if [[ "$bound" -ne 1 ]]; then
      echo "AdGuardHome failed to bind 127.0.0.1:53 within timeout" >&2
      exit 1
    fi

    # Clean up any emergency failover rules now that AdGuardHome (:53) is healthy
    "${cleanDnsBypass}"
  '';

  dnsFailoverRescue = pkgs.writeShellScript "dns-failover-rescue" ''
    set -uo pipefail
    export PATH="${lib.makeBinPath [ pkgs.iptables pkgs.openresolv pkgs.dnsutils pkgs.iproute2 pkgs.gnugrep pkgs.gnused pkgs.coreutils ]}"

    # If 127.0.0.1:53 is already answering normally, nothing to rescue
    if dig +time=2 +tries=1 @127.0.0.1 . NS >/dev/null 2>&1; then
      exit 0
    fi

    echo "WARNING: Local port 53 is unresponsive; engaging automatic DNS failover..." >&2

    # Tier 1: Redirect port 53 directly to local Unbound (:5335) — 100% local, zero external DNS leak
    if dig +time=3 +tries=1 @127.0.0.1 -p 5335 . NS >/dev/null 2>&1; then
      add_nat_rule() {
        local bin="$1"; shift
        "$bin" -t nat -C "$@" 2>/dev/null || "$bin" -t nat -I "$@"
      }
      add_nat_rule iptables OUTPUT -d 127.0.0.1/32 -p udp --dport 53 -m comment --comment dns-rescue-bypass -j REDIRECT --to-ports 5335
      add_nat_rule iptables OUTPUT -d 127.0.0.1/32 -p tcp --dport 53 -m comment --comment dns-rescue-bypass -j REDIRECT --to-ports 5335
      add_nat_rule iptables PREROUTING -i ve-+ -d 192.168.100.10/32 -p udp --dport 53 -m comment --comment dns-rescue-bypass -j REDIRECT --to-ports 5335
      add_nat_rule iptables PREROUTING -i ve-+ -d 192.168.100.10/32 -p tcp --dport 53 -m comment --comment dns-rescue-bypass -j REDIRECT --to-ports 5335
      add_nat_rule ip6tables OUTPUT -d ::1/128 -p udp --dport 53 -m comment --comment dns-rescue-bypass -j REDIRECT --to-ports 5335
      add_nat_rule ip6tables OUTPUT -d ::1/128 -p tcp --dport 53 -m comment --comment dns-rescue-bypass -j REDIRECT --to-ports 5335
    fi

    # Verify Tier 1 resolved the outage; if BOTH AdGuard Home and Unbound failed, engage Tier 2
    if dig +time=3 +tries=1 @127.0.0.1 nixos.org >/dev/null 2>&1; then
      echo "DNS Failover Tier 1 active: port 53 redirected to local Unbound (:5335)." >&2
      exit 0
    fi

    echo "CRITICAL: Both AdGuard Home and Unbound failed; activating emergency openresolv fallback (9.9.9.9, 1.1.1.1) so internet stays online." >&2
    resolvconf -f -d lo.adguardhome 2>/dev/null || true
    printf "nameserver 9.9.9.9\nnameserver 1.1.1.1\n" | resolvconf -x -a emergency-fallback
  '';
in
{
  # Allow AdGuard Home & Unbound to bind 192.168.100.10 at boot even before ve-media veth comes up
  boot.kernel.sysctl."net.ipv4.ip_nonlocal_bind" = 1;

  # Lock /etc/resolv.conf strictly to 127.0.0.1 via openresolv lo.adguardhome (ignore router DHCP & Tailscale overrides)
  services.resolved.enable = lib.mkForce false;
  networking.networkmanager.dns = "none";
  networking.resolvconf = {
    extraOptions = [ "trust-ad" ];
    extraConfig = ''
      deny_interfaces='tailscale NetworkManager'
    '';
  };
  networking.nameservers = lib.mkForce [ "127.0.0.1" "::1" ];
  services.tailscale.extraSetFlags = [ "--accept-dns=false" ];

  # Provide dig/nslookup for DNS & DNSSEC diagnostics
  environment.systemPackages = [ pkgs.dnsutils ];

  # Allow containers.media (ve-media -> 192.168.100.10:53 and failover :5335) to query host DNS
  networking.firewall.interfaces."ve-+" = {
    allowedUDPPorts = [ 53 5335 ];
    allowedTCPPorts = [ 53 5335 ];
  };

  # --- 1. Engine: Unbound Root-Recursive DNSSEC Resolver (:5335) ---
  services.unbound = {
    enable = true;
    resolveLocalQueries = false; # AdGuard Home listens on :53 in front of Unbound
    enableRootTrustAnchor = true;
    settings = {
      server = {
        interface = [ "127.0.0.1" "::1" "192.168.100.10" ];
        port = 5335;
        ip-freebind = true;
        access-control = [
          "127.0.0.0/8 allow"
          "::1/128 allow"
          "192.168.100.0/24 allow"
        ];

        # Direct root recursion + QNAME minimization privacy + DNSSEC hardening
        do-ip4 = true;
        do-ip6 = true;
        do-udp = true;
        do-tcp = true;
        qname-minimisation = true;
        harden-glue = true;
        harden-dnssec-stripped = true;
        aggressive-nsec = true;
        do-not-query-localhost = false; # Required for ts.net -> 100.100.100.100 stub
        domain-insecure = [ "ts.net." ];

        # DNS Rebinding protection for private RFC1918 / ULA ranges
        private-address = [
          "10.0.0.0/8"
          "172.16.0.0/12"
          "192.168.0.0/16"
          "169.254.0.0/16"
          "fd00::/8"
          "fe80::/10"
        ];

        # High-speed RAM cache + background prefetch + 0ms serve-expired
        num-threads = 4;
        so-reuseport = true;
        msg-cache-size = "128m";
        rrset-cache-size = "256m";
        prefetch = true;
        prefetch-key = true;
        serve-expired = true;
        serve-expired-ttl = 86400;
        cache-min-ttl = 60;
      };

      # Preserve Tailscale MagicDNS resolution locally without leaking internet DNS
      forward-zone = [
        {
          name = "ts.net.";
          forward-addr = [ "100.100.100.100" ];
        }
      ];
    };
  };

  # --- 2. Frontend (:53): AdGuard Home Ad/Tracker/Malware Blocker -> Unbound (:5335) ---
  services.adguardhome = {
    enable = true;
    mutableSettings = true;
    settings = {
      http.address = "127.0.0.1:3000";
      dns = {
        bind_hosts = [
          "127.0.0.1"
          "::1"
          "192.168.100.10"
        ];
        port = 53;
        upstream_dns = [ "127.0.0.1:5335" ];
        bootstrap_dns = [ "127.0.0.1:5335" ];
        enable_dnssec = true;
        cache_enabled = false; # Unbound manages the unified RAM cache + prefetch + serve-expired
        cache_size = 4194304;  # Keep positive value for AdGuard Home schema v29+ compatibility
      };
      filtering = {
        protection_enabled = true;
        filtering_enabled = true;
      };
      filters = [
        {
          enabled = true;
          url = "https://adguardteam.github.io/HostlistsRegistry/assets/filter_1.txt";
          name = "AdGuard DNS filter";
          id = 1;
        }
        {
          enabled = true;
          url = "https://raw.githubusercontent.com/hagezi/dns-blocklists/main/adblock/pro.txt";
          name = "HaGeZi Multi PRO Blocklist";
          id = 2;
        }
      ];
    };
  };

  # --- 3. Automatic Runtime Self-Healing & Two-Tier DNS Failover ---
  systemd.services.unbound = {
    unitConfig = {
      StartLimitIntervalSec = lib.mkForce 30;
      StartLimitBurst = lib.mkForce 4;
      OnFailure = [ "dns-failover-rescue.service" ];
    };
    serviceConfig.RestartSec = lib.mkForce "2s";
  };

  systemd.services.adguardhome = {
    after = [ "unbound.service" ];
    requires = [ "unbound.service" ];
    unitConfig = {
      StartLimitIntervalSec = lib.mkForce 30;
      StartLimitBurst = lib.mkForce 4;
      OnFailure = [ "dns-failover-rescue.service" ];
    };
    serviceConfig = {
      RestartSec = lib.mkForce "2s";
      ExecStartPost = [ "+${adguardPostStart}" ];
    };
  };

  systemd.services.dns-failover-rescue = {
    description = "Emergency DNS Failover (Unbound :5335 bypass -> openresolv fallback)";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${dnsFailoverRescue}";
    };
  };

  # Ensure Unbound & AdGuard Home start before containers.media (prevents ACME race during activation/boot)
  systemd.services."container@media" = {
    after = [ "unbound.service" "adguardhome.service" ];
    wants = [ "unbound.service" "adguardhome.service" ];
  };
}
