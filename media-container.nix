{ config, pkgs, lib, ... }:

let
  domain = "jellyfin.quest";
  tunnelId = "ee3e42e9-a541-46fa-927f-68496c654cd4";
  # RX 7600 (PCI 0000:12:00.0) maps to card1 + renderD128 on workstation
  gpuRenderNode = "/dev/dri/renderD128";
  gpuCardNode = "/dev/dri/card1";

  jellyfinNetworkXml = pkgs.writeText "network.xml" ''
    <?xml version="1.0" encoding="utf-8"?>
    <NetworkConfiguration xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:xsd="http://www.w3.org/2001/XMLSchema">
      <BaseUrl />
      <EnableHttps>false</EnableHttps>
      <RequireHttps>false</RequireHttps>
      <CertificatePath />
      <CertificatePassword />
      <InternalHttpPort>8096</InternalHttpPort>
      <InternalHttpsPort>8920</InternalHttpsPort>
      <PublicHttpPort>80</PublicHttpPort>
      <PublicHttpsPort>443</PublicHttpsPort>
      <AutoDiscovery>false</AutoDiscovery>
      <EnableUPnP>false</EnableUPnP>
      <EnableIPv4>true</EnableIPv4>
      <EnableIPv6>false</EnableIPv6>
      <EnableRemoteAccess>true</EnableRemoteAccess>
      <LocalNetworkSubnets>
        <string>192.168.0.0/24</string>
        <string>192.168.1.0/24</string>
        <string>100.64.0.0/10</string>
      </LocalNetworkSubnets>
      <LocalNetworkAddresses>
        <string>127.0.0.1</string>
      </LocalNetworkAddresses>
      <KnownProxies>
        <string>127.0.0.1</string>
      </KnownProxies>
      <IgnoreVirtualInterfaces>true</IgnoreVirtualInterfaces>
      <VirtualInterfaceNames>
        <string>veth</string>
      </VirtualInterfaceNames>
      <EnablePublishedServerUriByRequest>false</EnablePublishedServerUriByRequest>
      <PublishedServerUriBySubnet>
        <string>all=https://hyprsyd.${domain}</string>
      </PublishedServerUriBySubnet>
      <RemoteIPFilter />
      <IsRemoteIPFilterBlacklist>false</IsRemoteIPFilterBlacklist>
    </NetworkConfiguration>
  '';
in
{
  hardware.graphics.enable = true;

  # Outbound internet NAT for the isolated container (torrents, ACME DNS-01, Cloudflare Tunnel)
  networking.nat = {
    enable = true;
    internalInterfaces = [ "ve-+" ];
  };

  # Expose 8443 for direct LAN HTTPS and 51413 for BitTorrent peer traffic,
  # and allow container traffic alongside Docker's default FORWARD DROP policy
  networking.firewall = {
    allowedTCPPorts = [ 8443 51413 ];
    allowedUDPPorts = [ 51413 ];
    extraCommands = ''
      iptables -w -N DOCKER-USER 2>/dev/null || true
      iptables -w -C DOCKER-USER -i ve-+ -j ACCEPT 2>/dev/null || iptables -w -I DOCKER-USER 1 -i ve-+ -j ACCEPT
      iptables -w -C DOCKER-USER -o ve-+ -m conntrack --ctstate RELATED,ESTABLISHED,DNAT -j ACCEPT 2>/dev/null || iptables -w -I DOCKER-USER 1 -o ve-+ -m conntrack --ctstate RELATED,ESTABLISHED,DNAT -j ACCEPT
      iptables -w -C FORWARD -o ve-+ -m conntrack --ctstate RELATED,ESTABLISHED,DNAT -j ACCEPT 2>/dev/null || iptables -w -I FORWARD 1 -o ve-+ -m conntrack --ctstate RELATED,ESTABLISHED,DNAT -j ACCEPT
    '';
    extraStopCommands = ''
      iptables -w -D DOCKER-USER -i ve-+ -j ACCEPT 2>/dev/null || true
      iptables -w -D DOCKER-USER -o ve-+ -m conntrack --ctstate RELATED,ESTABLISHED,DNAT -j ACCEPT 2>/dev/null || true
      iptables -w -D FORWARD -o ve-+ -m conntrack --ctstate RELATED,ESTABLISHED,DNAT -j ACCEPT 2>/dev/null || true
    '';
  };

  containers.media = {
    autoStart = true;
    privateNetwork = true;
    hostAddress = "192.168.100.10";
    localAddress = "192.168.100.11";

    forwardPorts = [
      { protocol = "tcp"; hostPort = 8443; containerPort = 443; }
      { protocol = "tcp"; hostPort = 51413; containerPort = 51413; }
      { protocol = "udp"; hostPort = 51413; containerPort = 51413; }
    ];

    allowedDevices = [
      { node = gpuRenderNode; modifier = "rw"; }
      { node = gpuCardNode; modifier = "rw"; }
      { node = "/dev/kfd"; modifier = "rw"; }
    ];

    bindMounts = {
      "/home/sid/mnt" = {
        hostPath = "/home/sid/mnt";
        isReadOnly = false;
      };
      "/dev/dri" = {
        hostPath = "/dev/dri";
        isReadOnly = false;
      };
      "/dev/kfd" = {
        hostPath = "/dev/kfd";
        isReadOnly = false;
      };
      "/run/secrets/cloudflare.env" = {
        hostPath = "/etc/nixos/secrets/cloudflare.env";
        isReadOnly = true;
      };
      "/run/secrets/cloudflared.json" = {
        hostPath = "/etc/nixos/secrets/cloudflared.json";
        isReadOnly = true;
      };
    };

    config = { config, pkgs, lib, ... }: {
      system.stateVersion = "26.05";

      # Mesa radeonsi VA-API + RADV Vulkan + ROCm 7.2 OpenCL (HDR10 tone-mapping) for RX 7600
      hardware.graphics.enable = true;
      hardware.amdgpu.opencl.enable = true;

      # Fonts for libass ASS/SSA/SRT subtitle burn-in
      fonts = {
        fontconfig.enable = true;
        packages = with pkgs; [
          dejavu_fonts
          noto-fonts
          noto-fonts-cjk-sans
          noto-fonts-color-emoji
        ];
      };

      # Match host sid UID 1001 so Jellyfin and qBittorrent share RW access to /home/sid/mnt
      users.users.sid = {
        isNormalUser = true;
        uid = 1001;
        group = "users";
        extraGroups = [ "video" "render" ];
      };

      users.users.cloudflared = {
        isSystemUser = true;
        group = "cloudflared";
      };
      users.groups.cloudflared = { };

      # --- 1. Jellyfin Server with AMD RX 7600 VA-API + ROCm OpenCL HDR Tone-Mapping ---
      services.jellyfin = {
        enable = true;
        user = "sid";
        group = "users";
        forceEncodingConfig = true;
        hardwareAcceleration = {
          enable = true;
          type = "vaapi";
          device = gpuRenderNode;
        };
        transcoding = {
          enableHardwareEncoding = true;
          enableToneMapping = true;
          deleteSegments = true;
          hardwareDecodingCodecs = {
            h264 = true;
            hevc = true;
            hevc10bit = true;
            vp9 = true;
            av1 = true;
          };
          hardwareEncodingCodecs = {
            hevc = true;
            av1 = true;
          };
        };
      };

      systemd.services.jellyfin = {
        restartTriggers = [ jellyfinNetworkXml ];
        preStart = lib.mkAfter ''
          ${pkgs.coreutils}/bin/install -m 0600 ${jellyfinNetworkXml} "${config.services.jellyfin.configDir}/network.xml"
          if [ -f "${config.services.jellyfin.configDir}/encoding.xml" ]; then
            if ${pkgs.gnugrep}/bin/grep -q "<EnableSegmentDeletion>" "${config.services.jellyfin.configDir}/encoding.xml"; then
              ${pkgs.gnused}/bin/sed -i 's|<EnableSegmentDeletion>false</EnableSegmentDeletion>|<EnableSegmentDeletion>true</EnableSegmentDeletion>|g' \
                "${config.services.jellyfin.configDir}/encoding.xml"
            else
              ${pkgs.gnused}/bin/sed -i 's|</EncodingOptions>|  <EnableSegmentDeletion>true</EnableSegmentDeletion>\n</EncodingOptions>|' \
                "${config.services.jellyfin.configDir}/encoding.xml"
            fi
          fi
        '';
        serviceConfig = {
          PrivateUsers = lib.mkForce false;
          ProcSubset = lib.mkForce "all";
          ProtectProc = lib.mkForce "default";
          DeviceAllow = lib.mkForce [
            "${gpuRenderNode} rw"
            "${gpuCardNode} rw"
            "/dev/kfd rw"
          ];
        };
      };

      # --- 2. qBittorrent Headless WebUI (qbittorrent-nox) ---
      services.qbittorrent = {
        enable = true;
        user = "sid";
        group = "users";
        webuiPort = 8080;
        torrentingPort = 51413;
        serverConfig = {
          LegalNotice.Accepted = true;
          BitTorrent.Session = {
            DefaultSavePath = "/home/sid/mnt/downloads";
            MaxConnections = 200;
            MaxConnectionsPerTorrent = 50;
          };
          Preferences = {
            Downloads.SavePath = "/home/sid/mnt/downloads";
            WebUI = {
              Address = "127.0.0.1";
              Username = "admin";
              Password_PBKDF2 = "@ByteArray(V7E4fzC8klcXE29ymCuc9w==:QDPS5ofHwrebzhiXB4QlzjMA4htjxtXcBZBXbw2EzEMFCHMWCLKjQtXrkbBuzfqbVeeZCdMvz16r4SiT+0FeSw==)";
              HostHeaderValidation = false;
              CSRFProtection = true;
            };
          };
        };
      };

      systemd.services.qbittorrent.serviceConfig = {
        ProtectHome = lib.mkForce false;
        ReadWritePaths = [ "/home/sid/mnt" ];
        PrivateUsers = lib.mkForce false;
        RestrictNamespaces = lib.mkForce false;
        ProtectControlGroups = lib.mkForce false;
        ProtectKernelTunables = lib.mkForce false;
        ProtectKernelModules = lib.mkForce false;
        ProtectKernelLogs = lib.mkForce false;
      };

      # --- 3. Wildcard Let's Encrypt SSL via Cloudflare DNS-01 (using Host Unbound) ---
      security.acme = {
        acceptTerms = true;
        defaults.email = "hyprsyd@gmail.com";
        certs."${domain}" = {
          domain = "*.${domain}";
          extraDomainNames = [ domain ];
          dnsProvider = "cloudflare";
          dnsResolver = "192.168.100.10:53";
          # Verify TXT propagation directly against Cloudflare's authoritative NS instead of
          # local Unbound, which caches pre-challenge NXDOMAIN (SOA minimum 1800s)
          extraLegoFlags = [ "--dns.propagation.disable-rns" ];
          environmentFile = "/run/secrets/cloudflare.env";
          group = config.services.nginx.group;
        };
      };

      # --- 4. Nginx Reverse Proxy with Security Headers & Real-IP Trust ---
      services.nginx = {
        enable = true;
        serverTokens = false;
        recommendedProxySettings = true;
        recommendedTlsSettings = true;
        recommendedOptimisation = true;
        recommendedGzipSettings = true;

        # Extract true visitor IP only when arriving from local cloudflared (127.0.0.1)
        commonHttpConfig = ''
          set_real_ip_from 127.0.0.1;
          real_ip_header CF-Connecting-IP;
          real_ip_recursive on;
        '';

        virtualHosts."hyprsyd.${domain}" = {
          useACMEHost = domain;
          acmeRoot = null;
          forceSSL = true;
          extraConfig = ''
            add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
            add_header X-Content-Type-Options "nosniff" always;
            add_header X-Frame-Options "SAMEORIGIN" always;
            add_header Cross-Origin-Resource-Policy "same-origin" always;
            add_header Referrer-Policy "no-referrer-when-downgrade" always;
            add_header Permissions-Policy "accelerometer=(), ambient-light-sensor=(), battery=(), bluetooth=(), camera=(), clipboard-read=(), display-capture=(), document-domain=(), encrypted-media=(), gamepad=(), geolocation=(), gyroscope=(), hid=(), idle-detection=(), interest-cohort=(), keyboard-map=(), local-fonts=(), magnetometer=(), microphone=(), payment=(), publickey-credentials-get=(), serial=(), sync-xhr=(), usb=(), xr-spatial-tracking=()" always;
          '';
          locations."= /metrics".extraConfig = ''
            return 403;
          '';
          locations."/" = {
            proxyPass = "http://127.0.0.1:8096";
            proxyWebsockets = true;
            extraConfig = ''
              client_max_body_size 20M;
              proxy_buffering off;
            '';
          };
        };

        virtualHosts."qbit-hyprsyd.${domain}" = {
          useACMEHost = domain;
          acmeRoot = null;
          forceSSL = true;
          extraConfig = ''
            add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
            add_header X-Content-Type-Options "nosniff" always;
            add_header X-Frame-Options "SAMEORIGIN" always;
            add_header Referrer-Policy "same-origin" always;
          '';
          locations."/" = {
            proxyPass = "http://127.0.0.1:8080";
            proxyWebsockets = true;
            extraConfig = ''
              client_max_body_size 100M;
            '';
          };
        };
      };

      # --- 5. Cloudflare Tunnel (CGNAT-safe public HTTPS ingress) ---
      services.cloudflared = {
        enable = true;
        tunnels.${tunnelId} = {
          credentialsFile = "/run/secrets/cloudflared.json";
          edgeIPVersion = "4";
          default = "http_status:404";
          ingress = {
            "hyprsyd.${domain}" = {
              service = "https://127.0.0.1:443";
              originRequest = {
                originServerName = "hyprsyd.${domain}";
                httpHostHeader = "hyprsyd.${domain}";
                noTLSVerify = true;
              };
            };
            "qbit-hyprsyd.${domain}" = {
              service = "https://127.0.0.1:443";
              originRequest = {
                originServerName = "qbit-hyprsyd.${domain}";
                httpHostHeader = "qbit-hyprsyd.${domain}";
                noTLSVerify = true;
              };
            };
          };
        };
      };

      systemd.services."cloudflared-tunnel-${tunnelId}".serviceConfig = {
        DynamicUser = lib.mkForce false;
        User = "cloudflared";
        Group = "cloudflared";
      };

      systemd.services."acme-order-renew-${domain}" = {
        path = [ pkgs.glibc.bin pkgs.gnugrep ];
        preStart = ''
          # Wait up to 15s for container DNS so initial ACME runs never race veth bring-up
          for _ in $(seq 1 15); do
            if getent ahostsv4 acme-v02.api.letsencrypt.org >/dev/null 2>&1; then
              break
            fi
            sleep 1
          done

          # Self-heal lego v5 orphaned accounts ("registration": null) if network ever drops mid-registration
          for acct in accounts/*/*/account.json; do
            if [ -f "$acct" ] && grep -q '"registration":[[:space:]]*null' "$acct"; then
              echo "Removing incomplete lego account directory $(dirname "$acct")..."
              rm -rf "$(dirname "$acct")"
            fi
          done
        '';
        serviceConfig = {
          RestartSec = lib.mkForce "60s";
        };
      };

      # Route container DNS strictly through host AdGuard Home + Unbound (192.168.100.10)
      networking = {
        firewall = {
          enable = true;
          allowedTCPPorts = [ 443 51413 ];
          allowedUDPPorts = [ 51413 ];
        };
        useHostResolvConf = lib.mkForce false;
        nameservers = [ "192.168.100.10" ];
      };
      services.resolved.enable = true;
    };
  };
}
