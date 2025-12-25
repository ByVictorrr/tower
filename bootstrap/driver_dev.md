### How to use it on Ubuntu Server LTS

```bash
chmod +x bootstrap_driver_dev.sh
sudo ./bootstrap_driver_dev.sh --with-ebpf --with-virt --with-sync
```

Options you can add:

* `--with-sync` installs **Syncthing** (great for syncing between desktop/laptop/tablet + other Linux boxes)
* `--with-containers` installs docker.io + podman
* `--with-firmware` adds common firmware tools
* `--enable-deb-src` enables `deb-src` lines for `apt source` / `apt build-dep`

---

## Syncing between tablet + desktop + other Linux computers (recommended: Syncthing)

Syncthing is the simplest “Dropbox-like” sync that you host yourself. A few important notes:

* Don’t try to sync *literally everything* (like `/etc`, `/usr`, the whole `/home` blindly). Sync **specific folders**: `Documents/`, `Projects/`, `Notes/`, maybe `Pictures/`.
* For dotfiles/configs, consider syncing a dedicated folder like `~/dotfiles/` (or use a dotfiles manager later).

### Set up Syncthing on the tower (headless)

After running the script with `--with-sync`:

1. Log in as your user on the tower, start Syncthing:

```bash
systemctl --user enable --now syncthing
```

2. Open the Syncthing web UI securely via SSH tunnel from your laptop:

```bash
ssh -L 8384:127.0.0.1:8384 youruser@your-tower
```

Then open `http://localhost:8384` in your browser.

3. Add your other devices (desktop/laptop/tablet) in the Syncthing UI and choose which folders to sync.

### Tablet

* If it’s Android: install **Syncthing-Fork** (commonly used).
* If it’s Linux tablet: install Syncthing normally (`apt install syncthing` / `pacman -S syncthing`) and run it as a user service.

### Networking tip (makes life way easier)

If your devices aren’t always on the same LAN, strongly consider a mesh VPN like **Tailscale** so Syncthing can connect reliably without opening ports.

If you tell me what your “tablet” OS is (Android vs Linux), I’ll give you the exact clean setup for that device too (and a good folder layout to avoid syncing junk).

