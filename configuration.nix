{ config, pkgs, lib, ... }:

{
  # Basic system configuration for Raspberry Pi 4
  
  # Disable ZFS to avoid the build error
  # boot.supportedFilesystems.zfs = lib.mkForce false;
  boot.loader.timeout = 1;
  boot.supportedFilesystems = lib.mkForce [ "ext4" "vfat" ];
  boot.kernelParams = [ "boot.shell_on_fail" ];

  # Limit generations to save space
  boot.loader.systemd-boot.configurationLimit = 3;

  # Enable tmpfs for /tmp to save disk space
  boot.tmp.cleanOnBoot = true;
  boot.tmp.useTmpfs = true;

  # Create symbolic links for partition labels to handle different naming schemes
  boot.initrd.postDeviceCommands = lib.mkBefore ''
    # Create symlinks for partition labels to ensure compatibility
    mkdir -p /dev/disk/by-label
    for label in NIXOS_BOOT BOOT boot FIRMWARE; do
      if [ -e /dev/disk/by-label/$label ]; then
        # Create symlinks for all possible names
        for target in NIXOS_BOOT BOOT boot FIRMWARE; do
          if [ "$label" != "$target" ]; then
            ln -sf /dev/disk/by-label/$label /dev/disk/by-label/$target 2>/dev/null || true
          fi
        done
        break
      fi
    done
    
    # Similarly for root partition
    for label in NIXOS_SD nixos nixos-root root; do
      if [ -e /dev/disk/by-label/$label ]; then
        for target in NIXOS_SD nixos nixos-root root; do
          if [ "$label" != "$target" ]; then
            ln -sf /dev/disk/by-label/$label /dev/disk/by-label/$target 2>/dev/null || true
          fi
        done
        break
      fi
    done
  '';

  # Define file systems for the running system
  # The SD card typically uses these labels on a Raspberry Pi with NixOS
  fileSystems = {
    "/" = {
      device = lib.mkDefault "/dev/disk/by-label/NIXOS_SD";
      fsType = "ext4";
      options = [ "noatime" "nodiratime" "discard" ];
    };
    
    "/boot" = {
      # The SD image module uses FIRMWARE as the boot partition label
      device = "/dev/disk/by-label/FIRMWARE";
      fsType = "vfat";
      # Continue even if not mountable
      options = [ "defaults" "nofail" ]; 
    };
  };
  
  # Set hostname
  networking.hostName = "miters-rpi4";

  # ── 网络：有线（end0）静态 IPv4；IPv6 不做任何手动设置，保持内核 SLAAC/RA 自动配置 ──
  # （全球地址、默认路由均由主路由的 RA 下发，与现机实测行为一致。）
  # 实测依据（2026-09-25）：有线口名是 end0（不是 eth0，该版 nixpkgs 已移除
  # networking.usePredictableInterfaceNames 选项）；网关/主路由 192.168.1.1。
  # 注意：useDHCP = false 只是不在 end0 上跑 dhcpcd（那是 IPv4 的事），
  # 不影响 IPv6 的内核级 SLAAC。
  networking.interfaces.end0 = {
    useDHCP = false;   # 关闭 end0 上的 dhcpcd，防止 DHCP 再挂一个 .104 与静态 .200 并存
    ipv4.addresses = [
      { address = "192.168.1.200"; prefixLength = 24; }
    ];
  };
  networking.defaultGateway = { address = "192.168.1.1"; interface = "end0"; };

  # DNS 只写 v4；v6 的解析由 RA 下发的 RDNSS / 内核自动配置兜底
  networking.nameservers = [ "192.168.1.1" ];

  # 防火墙整体关闭（家庭内网无入站过滤需求）。
  # NAT 不受影响：nat-iptables.nix 在 firewall.enable=false 时自动改由
  # 独立的 nat.service 注入同一份 MASQUERADE/FORWARD 规则（nixpkgs 源码实锤）。
  networking.firewall.enable = false;

  # ── 用户与 SSH 公钥 ──
  # authorizedKeys 必须始终非空（PasswordAuthentication = false，
  # nixos 用户又是无密码状态，为空 = 烧完卡直接锁死）。
  users.users.nixos = {
    isNormalUser = true;
    extraGroups = [ "wheel" "networkmanager" ];
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGczhEZSH7HiuFNNkRSyha8m+U5jNNtAFqhVnm2x2+8R Miter_SSH_Key"
    ];
  };

  # ── 旁路由（网关角色）──
  # 拓扑：客户端 → 本机(192.168.1.200) → 主路由(192.168.1.1) → 外网
  boot.kernel.sysctl = {
    "net.ipv4.ip_forward" = 1;              # 允许转发目标不是自己的包
    "net.ipv4.conf.all.rp_filter" = 0;      # 同网段转发路径不对称，关严格反向路径校验
    "net.ipv4.conf.default.rp_filter" = 0;
    "net.ipv4.conf.all.send_redirects" = 0; # 不发 Redirect，防止客户端被"教坏"绕开本机
    "net.ipv4.conf.default.send_redirects" = 0;
    "net.ipv4.conf.all.accept_redirects" = 0;
    "net.ipv4.conf.default.accept_redirects" = 0;
  };

  # 声明式 NAT，等价于：
  #   iptables -t nat -A POSTROUTING -s 192.168.1.0/24 -o end0 -j MASQUERADE
  # FTTR 主路由加不了静态回程路由，客户端流量必须 MASQUERADE 才能出去。
  networking.nat = {
    enable = true;
    externalInterface = "end0";
    internalInterfaces = [ "end0" ];
    internalIPs = [ "192.168.1.0/24" ];
  };

  # Enable SSH
  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "prohibit-password";
      PasswordAuthentication = false;
    };
    # This option ensures SSH starts early in the boot process
    startWhenNeeded = false;
  };

  security.sudo.wheelNeedsPassword = false;

  # Enable experimental Nix flakes
  nix.settings = {
    experimental-features = [ "nix-command" "flakes" ];
    # Allow unsigned packages - needed for cross-deployment
    require-sigs = false;
    trusted-users = [ "root" "nixos" ];
  };

  # Basic bootloader configuration
  boot.loader.grub.enable = false;
  boot.loader.generic-extlinux-compatible.enable = true;

  # Use latest kernel packages as in your configuration
  boot.kernelPackages = pkgs.linuxPackages_latest;

  # Enable firmware for Raspberry Pi
  hardware.enableRedistributableFirmware = true;
  
  # Basic system packages including your additions
  environment.systemPackages = with pkgs; [
    vim
    git
    btop
    htop
    # Add some networking tools for troubleshooting
    inetutils
    iw
    wirelesstools
    # ↓ 补充的网络诊断工具（来源：rpi4-nixos-flake）+ 旁路由手工检查用
    iproute2      # ip / ss
    iputils       # ping / arping / tracepath
    dnsutils      # dig / nslookup / host
    mtr
    traceroute
    ethtool
    tcpdump
    socat
    jq
    lsof
    whois
    iptables      # 手工核对 NAT 规则（nixos-nat-* 链）
    dae           # eBPF 代理/分流工具：仅装软件，不自动启动（无 services.dae 模块即不自启）
    sing-box
    tmux
  ];

  # Automatic garbage collection
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 30d";
  };

  # Optimize storage by turning off some history
  nix.settings.auto-optimise-store = true;
  nix.optimise.automatic = true;

  # Set your timezone to Asia/Shanghai (UTC+8)
  time.timeZone = "Asia/Shanghai";

  # Audio configuration with pulseaudio as you specified
  services.pulseaudio.enable = true;

  # System settings
  system.stateVersion = "24.11"; # Keep this unchanged
}
