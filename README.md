# rpi4-nixos-flake

NixOS flake for my Raspberry Pi 4

- `configuration.nix` — the whole machine config (network, SSH key, packages). Shared by the SD image and the running system.
- `sd-image.nix` — SD image build parameters.

## Build an SD image

GitHub → Actions → **Build SD image** → **Run workflow** (manual trigger). Download the artifact, `zstd -d`, `dd` to the card. Boot with ethernet, then:

## Rebuild a running Pi

```bash
sudo nixos-rebuild switch --flake github:MiterMe/rpi4-nixos-flake#rpi4
```

The Pi's `/etc/nixos` is overwritten from this flake on every rebuild — edit files here only, never on the Pi.
