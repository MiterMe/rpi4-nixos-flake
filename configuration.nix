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

  # ── 分区标签 ──
  # 26.05 的 sd-image 模块打标签 FIRMWARE（FAT）+ NIXOS_SD（ext4），
  # 与下面 fileSystems 的期望一致（source: sd-image.nix @ nixos-26.05，
  # firmwarePartitionName / rootVolumeLabel 的默认值）。
  # 旧版那段 initrd 标签别名 hack（postDeviceCommands）已删：26.05 的
  # systemd stage 1 明令不支持该选项（求值门禁报错实锤），且标签已自洽。
  fileSystems = {
    "/" = {
      device = lib.mkDefault "/dev/disk/by-label/NIXOS_SD";
      fsType = "ext4";
      options = [ "noatime" "nodiratime" "discard" ];
    };

    # 26.05 布局：FAT 分区只放树莓派固件（config.txt / u-boot），挂 /boot/firmware；
    # 引导文件（extlinux.conf、内核引用）在 ext4 的 /boot——generic-extlinux-compatible
    # 的 mirroredBoots 默认 path = "/boot"（26.05 源码实锤）。
    # ⚠️ 不能把 FAT 挂在 /boot：会遮住 ext4 的 /boot，Pi 上 nixos-rebuild 会把
    # extlinux.conf 写进 FAT，u-boot 按相对路径在 FAT 里找不到 /nix/store 内核 ⇒ 砖。
    "/boot/firmware" = {
      device = "/dev/disk/by-label/FIRMWARE";
      fsType = "vfat";
      options = [ "noauto" "nofail" ];  # 与 26.05 sd-image 模块自身声明一致
    };
  };

  # ── 固件分区 U-Boot（必须显式开启！）──
  # nixos-hardware 新版（raspberry-pi/common/firmware.nix）用 mkForce 接管了
  # 固件分区的 populate：U-Boot 变成可选项，默认不拷 u-boot.bin、渲染出的
  # config.txt 也没有 kernel= ⇒ Pi 上电后 GPU 固件找不到内核，直接死。
  # （2026-09-27 首烧 26.05 镜像不启动的根因，源码实锤。）
  # 开启后：拷 u-boot.bin + config.txt 写 kernel=u-boot.bin / arm_64bit=1，
  # U-Boot 链式加载后读 ext4 /boot 里的 extlinux.conf。
  hardware.raspberry-pi.firmware.uboot.enable = true;
  
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

  # Enable dnsmasq
  services.dnsmasq = {
    enable = true;
    settings = {
      port = 5353;
      listen-address = [ "127.0.0.1" ];
      bind-interfaces = true;
      no-resolv = true;
      server = [ "192.168.1.1" ];              # 非 .lan 兜底（实际 dae 只会把 .lan 发来）
      address = [ "/.scidy.lan/192.168.1.201" ];  # 通配全部 *.scidy.lan
    };
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
    tmux
    # dae / sing-box 不走 nixpkgs（26.05 里版本过旧：dae 1.0.0 / sing-box 1.13.19）。
    # 改为从 GitHub releases 下载独立 Go 静态二进制，放 /home/nixos/bin/，
    # 不与系统捆绑、不受 flake.lock 版本约束（2026-09-27 翔哥决策）。
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
