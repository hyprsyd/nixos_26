{
  config,
  lib,
  pkgs,
  antigravity-nix,
  zen-browser,
  claude-code,
  ...
}:

{
  home.username = "sid";
  home.homeDirectory = "/home/sid";
  home.stateVersion = "26.05";

  home.sessionVariables = {
    EDITOR = "nvim";
    VISUAL = "nvim";
  };

  programs = {
    obsidian = {
      enable = true;
      vaults.notes.target = "Documents/Obsidian";
    };

    zsh = {
      enable = true;
      enableCompletion = true;
      autosuggestion = {
        enable = true;
        highlight = "fg=#665c54";
        strategy = [
          "history"
          "completion"
        ];
      };
      syntaxHighlighting.enable = true;
      history = {
        size = 100000;
        save = 100000;
        ignoreAllDups = true;
        ignoreSpace = true;
        share = true;
        extended = true;
      };
      setOptions = [
        "AUTO_CD"
        "AUTO_PUSHD"
        "PUSHD_IGNORE_DUPS"
        "HIST_REDUCE_BLANKS"
        "INTERACTIVE_COMMENTS"
        "COMPLETE_IN_WORD"
      ];
      oh-my-zsh = {
        enable = true;
        theme = "";
        plugins = [
          "git"
          "gitfast"
          "golang"
          "docker"
          "docker-compose"
          "sudo"
          "extract"
          "command-not-found"
          "colored-man-pages"
          "history-substring-search"
          "flutter"
        ];
      };
      shellAliases = {
        vi = "nvim";
        vim = "nvim";
        ll = "ls -lah --color=auto";
        la = "ls -A";
        gs = "git status -sb";
        gundo = "git reset --soft HEAD~1";
        dc = "docker compose";
        dcu = "docker compose up -d";
        dcd = "docker compose down";
        dcl = "docker compose logs -f --tail=100";
        dps = ''docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"'';
        gotest = "go test ./...";
        gor = "go run .";
        gomt = "go mod tidy";
        reload = "exec zsh";
      };
      initContent = ''
        # Source local untracked secrets (e.g. GEMINI_API_KEY) if present
        [[ -f ~/.secrets ]] && source ~/.secrets

        source ${pkgs.zsh-powerlevel10k}/share/zsh-powerlevel10k/powerlevel10k.zsh-theme
        [[ -f ~/.p10k.zsh ]] && source ~/.p10k.zsh
        source ${pkgs.zsh-fzf-tab}/share/fzf-tab/fzf-tab.plugin.zsh
        bindkey '^ ' autosuggest-accept
        bindkey '^[[A' history-substring-search-up
        bindkey '^[[B' history-substring-search-down
        zstyle ':completion:*:git-checkout:*' sort false
        zstyle ':completion:*:descriptions' format '[%d]'
        zstyle ':completion:*' list-colors "''${(s.:.)LS_COLORS}"
        zstyle ':completion:*' menu no
        zstyle ':fzf-tab:*' fzf-flags --color=bg+:#3c3836,bg:#282828,spinner:#fe8019,hl:#928374 \
          --color=fg:#ebdbb2,header:#928374,info:#83a598,pointer:#fe8019 \
          --color=marker:#8ec07c,fg+:#ebdbb2,prompt:#fe8019,hl+:#fe8019
        zstyle ':fzf-tab:*' switch-group ',' '.'
        zstyle ':fzf-tab:complete:cd:*' fzf-preview 'ls -lah --color=always -- $realpath 2>/dev/null | head -n 80'
        export GOPATH="$HOME/go"
        export GOBIN="$HOME/go/bin"
        export PATH="$GOBIN:$HOME/.local/bin:$PATH"
        export EDITOR="nvim"
        export VISUAL="nvim"
        export GPG_TTY="$(tty)"
        export SSH_AUTH_SOCK="$(gpgconf --list-dirs agent-ssh-socket)"
      '';
    };
  };

  systemd.user.services.hyprpolkitagent = {
    Unit = {
      Description = "hyprpolkitagent";
      After = [ "graphical-session.target" ];
      PartOf = [ "graphical-session.target" ];
    };
    Install.WantedBy = [ "graphical-session.target" ];
    Service = {
      Type = "simple";
      ExecStart = "${pkgs.hyprpolkitagent}/libexec/hyprpolkitagent";
      Restart = "on-failure";
      RestartSec = 1;
      TimeoutStopSec = 10;
    };
  };

  # Symlink entire nvim directory so colorschemes and configs are available
  xdg.configFile."nvim" = {
    source = config.lib.file.mkOutOfStoreSymlink "/home/sid/nvim";
    force = true;
  };

  home.packages = with pkgs; [
    neovim
    claude-code.packages.${pkgs.stdenv.hostPlatform.system}.default
    alacritty
    foot
    waybar
    hyprpaper
    zapzap
    hypridle
    rofi-unwrapped
    nwg-look
    dunst
    wl-clipboard
    wl-gammarelay-rs
    networkmanagerapplet
    luarocks
    kdePackages.dolphin
    pavucontrol
    dconf-editor
    chromium
    playwright
    teams-for-linux
    postman
    bruno
    bruno-cli
    zen-browser.packages.${pkgs.stdenv.hostPlatform.system}.default

    # Antigravity CLI and FHS IDE (with Chromium override; removed conflicting no-fhs build)
    antigravity-nix.packages.${pkgs.stdenv.hostPlatform.system}.google-antigravity-cli
    (antigravity-nix.packages.${pkgs.stdenv.hostPlatform.system}.google-antigravity-ide.override {
      browserPkg = zen-browser.packages.${pkgs.stdenv.hostPlatform.system}.default;
      useUserProfile = false;
    })

    git
    git-lfs
    gh
    wget
    curl
    tree
    fzf
    jq
    yq
    eza
    tmux
    ripgrep
    fd
    unzip
    p7zip
    bottom
    gcc
    gnumake
    cmake
    websocat
    zig
    go
    grim
    gimp
    spotify
    spotify-tray
    gopls
    nodejs_22
    nodenv
    lua
    (lib.lowPrio luajit)
    lua-language-server
    tree-sitter
    nil
    sassc
    docker-compose
    (python3.withPackages (ps: [
      ps.python-lsp-server
      ps.pylsp-rope
      ps.python-lsp-black
    ]))
    (google-cloud-sdk.withExtraComponents [
      google-cloud-sdk.components.gke-gcloud-auth-plugin
      google-cloud-sdk.components.kubectl
    ])
    zsh-fzf-tab
    zsh-powerlevel10k
    zsh-completions
    fastfetch
    cargo
    blueman
  ];
}
