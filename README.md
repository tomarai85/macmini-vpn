# Mac mini VPN

A menu-bar app for Macs abroad. It chooses what goes through a Mac at home in Japan and what stays on your normal connection.

![The menu: sites and terminal tools on (dark), all off (light)](docs/panel.png)

- **Three switches, in any combination.**
  - **Chosen sites** are the sites in your list, with their sign-in and video hosts. The default list has a few Japanese video services.
  - **Terminal tools** are programs that read `HTTPS_PROXY`, such as Claude Code, `curl` and `git`.
  - **Everything else** is browsers and the other apps.

  Turn all three on and everything goes through Japan. Turn them all off and nothing does. The lamp in the menu bar is green when something is on, red when everything is off and orange when there's a problem.
- **Only what you switch on goes through Japan.** Search, mail, work apps and everything else stay on your normal connection. The site list is one small text file, [`sites.example`](sites.example).
- **The exit is a home line, not a data centre.** Japanese streaming services refuse addresses that belong to hosting companies and to commercial VPNs. A Mac on an ordinary home connection in Japan is just a home connection.
- **It keeps itself working.** A background job keeps the tunnel open, repairs it when it drops and never cuts a video that's playing. The health shown in the menu is ABEMA's own answer to "is this Japan?", not merely "connected".
- **Free.** You need two Macs, and everything else is free: [Tailscale](https://tailscale.com) (free plan), ssh, and optionally [kcptun](https://github.com/xtaci/kcptun).

## How it works

```
browsers and apps ── jp.pac ──┬─ chosen sites (if on) ───────────┐
                              ├─ everything else (if on) ────────┤
                              └─ the rest ─→ direct              ├─→ 127.0.0.1:1082 (ssh -D)
terminal tools ── HTTPS_PROXY ── mmvpn-proxy ─┬─ (if on) ────────┘       ─→ kcptun ─→ Tailscale
                                              └─ (if off) ─→ direct          ─→ the Mac in Japan
```

- **`jp.pac`** is a proxy auto-config file that browsers and Mac apps read. `mmvpn-proxy` serves it on `127.0.0.1:1081` and fills in your site list and the switches that are on. Each site goes through Japan with all of its hosts, sign-in and video included, and with no fallback, because some services refuse a session that signs in from one country and streams from another. *Everything else* falls back to direct when the home Mac is down, so pages still open. Every change of switches is also a change of the PAC's URL, because browsers and apps keep a PAC for as long as its URL stays the same.
- **`mmvpn-proxy`** also relays terminal tools. Claude Code, `curl`, `git` and most command-line tools ignore PAC files but follow `HTTPS_PROXY`. Once you point that at `http://127.0.0.1:1081`, the *Terminal tools* switch decides where they go, and the change applies to new connections at once, with no restart. The relay **fails open**: if the tunnel doesn't answer within 6 seconds, the connection goes direct, so a home Mac that is off never stops your work. Addresses on your own networks (`localhost`, private and Tailscale addresses, `.local`, `.ts.net`) always go direct.
- **`mmvpn-tunnel`** keeps `ssh -D` open to the Mac in Japan. It tries kcptun first, then plain ssh, then an optional relay host, and it repairs the tunnel by itself.
- **kcptun** carries the ssh connection over UDP with forward error correction. A long path between continents loses packets, and TCP slows down sharply when it does. On one such path, plain ssh gave 0.5–6 Mbit/s and ssh inside kcptun gave 11.6–19 Mbit/s. Netflix played in 1080p. kcptun is optional (`USE_KCP="no"`).
- **Only one setting on your Mac changes**: the automatic proxy configuration URL, on every network service. Turning everything off clears that setting. The routing table and DNS are never touched. *Terminal tools* changes nothing on your Mac, only where the relay sends new connections.

## What you need

- **The Mac in Japan.** It must stay on and awake. Ethernet is strongly recommended (see the tips below).
- **The Mac you travel with.** It needs macOS 13 or later and the Xcode Command Line Tools (`xcode-select --install`).
- **Tailscale on both Macs**, signed in to the same account. Any other way of reaching the home Mac by ssh also works.
- **Optional, for speed:** [Homebrew](https://brew.sh) and `brew install kcptun` on both Macs.

## Setup

### 1. On the Mac in Japan (once)

1. Install Tailscale and sign in.
2. Go to **System Settings › General › Sharing** and turn on **Remote Login**.
3. Go to **System Settings › Energy** and turn on **Prevent automatic sleeping when the display is off** and **Start up automatically after a power failure**.
4. For kcptun, run:
   ```sh
   brew install kcptun
   git clone https://github.com/tomarai85/macmini-vpn.git
   cd macmini-vpn/home && ./install-home.sh
   ```
   It asks for the Mac's password once. It runs kcptun at every boot, even when nobody is logged in, and lets it through the macOS firewall.

You can do all of this remotely over Screen Sharing once Tailscale is running.

### 2. On the Mac you travel with

1. Install Tailscale and sign in with the same account.
2. Let ssh in without a password, then check that it works:
   ```sh
   ssh-copy-id user@100.x.y.z       # the home Mac's user name and Tailscale address
   ssh user@100.x.y.z true          # must return without asking for a password
   ```
3. Install:
   ```sh
   brew install kcptun              # skip if you use USE_KCP="no"
   git clone https://github.com/tomarai85/macmini-vpn.git
   cd macmini-vpn && ./install.sh
   ```
   The first run writes `~/.config/macmini-vpn/config` and stops. Set `HOME_MAC="user@100.x.y.z"` in it, then run `./install.sh` again.
4. Click the Mac mini icon in the menu bar and turn on the switches you want.
5. Optional, for the *Terminal tools* switch, point the programs at the relay:
   - **In a shell:** add `export HTTPS_PROXY=http://127.0.0.1:1081 NO_PROXY=localhost,127.0.0.1,::1,.local,.ts.net` to your `~/.zshrc`.
   - **For Claude Code:** add the same two variables under `"env"` in `~/.claude/settings.json`:
     ```json
     "env": { "HTTPS_PROXY": "http://127.0.0.1:1081", "NO_PROXY": "localhost,127.0.0.1,::1,.local,.ts.net" }
     ```
     Running sessions pick this up without a restart.

   While the switch is off, the relay sends them direct.

## Use

The menu-bar switches are the normal way to use it. The same controls also work from a terminal:

```sh
~/.local/bin/mmvpn set sites tools    # the full set that goes through Japan: any of sites, tools, rest
~/.local/bin/mmvpn set                # everything direct, tunnel stopped
~/.local/bin/mmvpn up                 # same as: set sites
~/.local/bin/mmvpn down               # same as: set
~/.local/bin/mmvpn status
```

A switch goes on only after the exit has answered from Japan and the local server has answered. Otherwise nothing changes, so a failed check never cuts a video that is already playing.

The app and the tunnel start again by themselves after a restart. **Quit** in the menu closes only the icon. The switches stay as they were.

**To change the site list**, edit `~/.config/macmini-vpn/sites`: one domain per line (it covers its subdomains), or a pattern with `*`. List the domains the video streams from too, which are often not the site's own domain. Your browser's developer tools (Network tab) show them. Then switch *Chosen sites* off and on, or run `mmvpn set sites` (plus the other routes you want). Browsers fetch the new list at once. `./install.sh` never overwrites your list.

## Tips

- **On the home Mac, set AirDrop to Contacts Only, or use Ethernet.** With AirDrop set to *Everyone*, the Mac keeps AWDL (the Wi-Fi link behind AirDrop) listening, which takes the radio off its own channel for about 0.6 s of every second. On one home Mac this put the median round trip to its own router at 350 ms, and every new connection to the Japanese sites took 1.3–1.8 s while every other site stayed fast. Changing only AirDrop to *Contacts Only* or *No One* brought the median to 4 ms. Contacts Only lets your contacts AirDrop to the Mac only if it is signed in to an Apple Account and has their Apple Account email or phone number in Contacts. Otherwise, set it to Everyone while you need it.
- **"Not seen as Japan"** means the exit answers, but ABEMA doesn't accept it as Japan. Check that the home Mac isn't itself on a VPN.
- **"Home Mac not responding"** means the home Mac is off, asleep or offline, or that ssh asks for a password. Try `ssh user@address true`.
- **What the detour costs.** Through Japan, every request waits for the round trip to the home Mac. On one path between the US and Japan (a round trip of about 170 ms), this added about 0.15 s per request on an open connection and about 0.5 s per new connection. Claude Code turns took a median 9.2 s instead of 8.0 s. Uploads through the tunnel ran at about 5 Mbit/s. Turn *Terminal tools* on only when you need a Japanese address.
- `curl -s http://127.0.0.1:1081/status` shows the relay's counters: connections through Japan, direct, and fallbacks to direct when the tunnel didn't answer.
- Logs are in `~/.config/macmini-vpn/logs/`. The tunnel logs every route it tries.

## Uninstall

```sh
./uninstall.sh            # turns routing off, removes the app, scripts and launch agents (keeps your config)
./uninstall.sh --all      # also removes ~/.config/macmini-vpn
home/uninstall-home.sh    # on the Mac in Japan
```

## Other ways to do this

- **[Tailscale exit node](https://tailscale.com/kb/1103/exit-nodes).** The simplest setup: make the home Mac an exit node and turn it on wherever you are. It works on an Apple TV too. The drawback is that *all* traffic goes through Japan, so everything else gets slower too, and every site sees you as in Japan.
- **Tailscale App Connectors.** These route chosen domains through a connector node, but the connector has to run on Linux.
- **[Proxy Switchboard](https://ptrinh.github.io/proxy-switchboard-dist/).** The closest app to this one: per-site rules over SSH, SOCKS5, WireGuard and more, with failover and a menu-bar switch. You write the rules and set up the home end yourself.
- **[Clash Verge Rev](https://github.com/clash-verge-rev/clash-verge-rev) and ClashX Meta.** Rule-based proxy clients with a menu-bar toggle. You bring the server and the tunnel.
- **`ssh -D` plus a browser proxy extension.** The classic do-it-yourself setup. Nothing keeps the tunnel up, and it doesn't cope with a lossy long-distance path.
- **Your home router's VPN server.** Many Japanese routers have one (L2TP/IPsec). It routes the whole device and needs the router's admin settings.

What Mac mini VPN adds is the ready-made part. It comes with a list of Japanese video hosts, including the ones the video actually streams from. It sets up the home end, uses kcptun for a lossy path between continents, and checks the exit by asking ABEMA rather than by "connected". It turns on only when that check passes. It also covers terminal tools, which ignore PAC files, without making them depend on the tunnel.

## A note on terms

Each streaming service decides where its content may be watched, and some limit viewing to the country of your account. Read the terms of the services you use. You are responsible for how you use this tool.

## Tests

```sh
bash tests/run.sh
```

The tests never change your proxy setting or start a real tunnel. The scripts run against stubs, and the app is built into a temporary folder. They cover:
- the PAC's routing for every switch, including look-alike hosts, shared CDNs and your own networks, in both a browser engine and Apple's own (Safari and Mac apps);
- the local server: only the PAC and its status are served, and the relay falls back to direct when the tunnel is dead or silent;
- each switch changing only its own route, and nothing changing when the exit or the server doesn't answer;
- the tunnel's route choice: fallback, recovery, never cutting a playing video;
- the installer;
- the app's own checks.

## Credits and license

MIT, see [LICENSE](LICENSE). The icon is drawn from the geometry of [Phosphor Icons](https://github.com/phosphor-icons/core)' `hard-drive` (MIT, Copyright (c) 2023 Phosphor Icons). The tunnel uses [kcptun](https://github.com/xtaci/kcptun) (MIT) when it's installed.
