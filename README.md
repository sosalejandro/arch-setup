# g7-setup

Post-install scripts for a headless, remote-accessed EndeavourOS dev laptop.

Target: Dell G7 (or any UEFI laptop), Xfce minimal install, LUKS-encrypted,
mainly used over SSH + xRDP from a Windows main laptop.

## Run order

| Script | When | Where |
|---|---|---|
| `phase1-base.sh` | First boot, physical keyboard/monitor attached | On the G7 |
| `phase2-dev.sh`  | After phase 1 + SSH from Windows confirmed working | On the G7 (over SSH) |
| `phase3-harden.sh` | Optional, after SSH key auth is confirmed working | On the G7 (over SSH) |
| `phase4-tailscale.sh` | Optional, anytime — best after phase 3 | On the G7 (over SSH) |
| `phase5-languages.sh` | Optional. Languages: Go, Rust, Python, .NET, Scala 3, pnpm, Task | On the G7 (over SSH) |
| `phase6-infrastructure.sh` | Optional. IaC, cloud CLIs, k8s, Docker, SOPS, age | On the G7 (over SSH) |
| `phase7-mobile.sh` | Optional. JDK, Android SDK, Gradle, ADB, RN/Watchman | On the G7 (over SSH) |
| `phase8-vms.sh` | Optional. KVM/QEMU + libvirt + virt-manager for VMs | On the G7 (over SSH) |
| `vm-ephemeral-browser.sh` | Optional utility. Creates a hardened ephemeral Lubuntu Live VM for isolated browsing | On the G7 (over SSH), after phase 8 |
| `vm-ephemeral-kali.sh` | Optional utility. Creates an ephemeral Kali Live VM for pentest / CTF / forensics work | On the G7 (over SSH), after phase 8 |
| `vm-work-windows.sh` | Optional utility. Creates a stateful Windows 11 VM (lightweight: 40 GB disk, 8 GB RAM, for .NET + VS Code workload) | On the G7 (over SSH), after phase 8. Requires Win11 ISO downloaded manually first. |
| `verify.sh` | Anytime, to sanity-check the setup | On the G7 |

All scripts are idempotent — re-running them is safe.

## How to get the scripts onto the G7

Pick one:

**A. Push this folder to a Git repo, then clone on the G7:**

```bash
# On Windows (in this folder)
git init && git add . && git commit -m "g7 setup"
gh repo create g7-setup --private --source=. --push
# Or: create the repo manually on GitHub, then:
# git remote add origin git@github.com:<you>/g7-setup.git && git push -u origin main

# On the G7
git clone https://github.com/<you>/g7-setup.git
cd g7-setup && chmod +x *.sh
```

**B. scp from Windows:**

```powershell
# From the Windows main laptop
scp -r "$env:USERPROFILE\path\to\g7-setup" <user>@<g7-host>:~/
# On the G7
cd ~/g7-setup && chmod +x *.sh
```

**C. One-shot curl** (if you push to a public repo):

```bash
# On the G7
curl -fsSL https://raw.githubusercontent.com/<you>/g7-setup/main/phase1-base.sh | bash
```

## Running

```bash
./phase1-base.sh                # Phase 1: at the G7 directly
# (test SSH + RDP from Windows here, then close the lid)
./phase2-dev.sh                 # Phase 2: over SSH
./phase3-harden.sh              # Phase 3: optional — SSH key-only, ufw firewall
./phase4-tailscale.sh           # Phase 4: optional — Tailscale mesh
./phase4-tailscale.sh g7        # Phase 4 variant: also renames hostname to 'g7'
./phase5-languages.sh           # Phase 5: optional — programming languages
./phase6-infrastructure.sh      # Phase 6: optional — cloud / IaC / k8s / Docker
./phase7-mobile.sh              # Phase 7: optional — Android / RN
./phase8-vms.sh                 # Phase 8: optional — KVM/QEMU VMs
./verify.sh                     # Sanity check
```

## Phase 4 details

`phase4-tailscale.sh` adds [Tailscale](https://tailscale.com) — a zero-config
WireGuard mesh. After completion:

- The G7 is reachable from any Tailscale-connected device by short hostname
  (e.g. `ssh <user>@<g7-host>`), no LAN-IP or `.local` mDNS dance.
- Works from anywhere in the world, not just home WiFi.
- Tailscale also opens `tailscale0` in `ufw` automatically, and phase3 detects
  Tailscale if it was installed first — order between phase3 and phase4 doesn't
  matter, both end up with the same firewall state.

You also need to install Tailscale on the Windows main laptop (or any other
device you want to reach the G7 from):
<https://tailscale.com/download/windows>. Sign in with the same account.
