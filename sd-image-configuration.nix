{ config, pkgs, lib, ... }:

{
  # ── 网络：弃用 WiFi，有线（end0）静态接入 ──
  # 不写 networking.wireless 即为关闭：base-configuration.nix 和
  # nixos-hardware 都不会打开它，wpa_supplicant 不会运行（固件包仍在，仅不用）。
  #
  # 实测依据（2026-09-25，rpi4-nixos-flake 仓库验证）：
  #   有线口名是 end0（不是 eth0，该版 nixpkgs 已移除
  #   networking.usePredictableInterfaceNames 选项）；网关/主路由 192.168.1.1。
  #
  # IPv4 手动静态；IPv6 不做任何手动设置，保持内核 SLAAC/RA 自动配置
  # （全球地址、默认路由均由主路由的 RA 下发，与现机实测行为一致）。
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

  # ── 用户与 SSH 公钥 ──
  # 烧卡后唯一的进系统方式；authorizedKeys 必须始终非空
  # （base-configuration.nix 里 PasswordAuthentication = false，
  #   nixos 用户又是无密码状态，为空 = dd 完直接锁死）。
  users.users.nixos = {
    isNormalUser = true;
    extraGroups = [ "wheel" "networkmanager" ];
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGczhEZSH7HiuFNNkRSyha8m+U5jNNtAFqhVnm2x2+8R Miter_SSH_Key"
    ];
  };
}
