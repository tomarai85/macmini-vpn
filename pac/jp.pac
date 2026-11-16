// jp.pac — which traffic leaves through the Mac in Japan. This is a template: mmvpn-proxy serves it on
// 127.0.0.1:PAC_PORT and fills in three things:
//   ROUTES  from the URL `mmvpn set` writes as the system's automatic-proxy URL
//           (http://127.0.0.1:1081/jp.pac?routes=sites,rest&v=...):
//             sites  the sites in ~/.config/macmini-vpn/sites
//             rest   everything else that follows the system proxy setting: browsers and most apps
//   SITES   from ~/.config/macmini-vpn/sites (edit that file, not this one)
//   the SOCKS port of the tunnel, from SOCKS_PORT in the config
// Terminal tools ignore PAC files; they use mmvpn-proxy's relay instead (HTTPS_PROXY). Anything not
// chosen goes DIRECT. Served unfilled, this file sends everything DIRECT.
var ROUTES = "__ROUTES__";
var SITES = [/*__SITES__*/];

function FindProxyForURL(url, host) {
  var h = ("" + host).toLowerCase();
  // A trailing dot is a legal form of a host name and would defeat a plain suffix match.
  if (h.charAt(h.length - 1) === ".") { h = h.substring(0, h.length - 1); }
  var on = "," + ROUTES + ",";
  // "SOCKS5" for Chromium browsers (the name is resolved in Japan); "SOCKS" for Safari and every app
  // that uses Apple's PAC engine, which drops "SOCKS5" as unknown: with CFNetwork, "SOCKS5 x" gives
  // no proxy at all and "SOCKS x" gives SOCKS x. Chromium reads "SOCKS" as SOCKS4 and tries it only
  // if SOCKS5 fails on the same port.
  var TUNNEL = "SOCKS5 127.0.0.1:__SOCKS_PORT__; SOCKS 127.0.0.1:__SOCKS_PORT__";

  // This Mac's own networks never go through Japan: names without a dot, IPv6 literals, local
  // suffixes, the tailnet, and loopback, private, link-local and CGNAT (Tailscale 100.64/10)
  // addresses. The address test applies only to a whole IPv4 literal, so 10.example.com is a name.
  var local = [".local", ".localhost", ".internal", ".lan", ".home.arpa", ".ts.net"];
  if (h.indexOf(".") < 0 || h.indexOf(":") >= 0) { return "DIRECT"; }
  for (var k = 0; k < local.length; k++) { if (dnsDomainIs(h, local[k])) { return "DIRECT"; } }
  if (/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/.test(h) &&
      /^(127|10)\.|^192\.168\.|^172\.(1[6-9]|2[0-9]|3[01])\.|^169\.254\.|^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\./.test(h)) {
    return "DIRECT";
  }

  // The listed sites leave by one exit, pages, sign-in and video alike, with no DIRECT fallback.
  // Some services refuse a session that signs in from one country and streams from another, and a
  // fallback would quietly do exactly that whenever the tunnel blinked. With "sites" off, the sites
  // go DIRECT even when "rest" is on: "rest" means everything except the switches above it.
  for (var i = 0; i < SITES.length; i++) {
    var s = SITES[i];
    if (s.indexOf("*") >= 0 ? shExpMatch(h, s) : (h === s || dnsDomainIs(h, "." + s))) {
      return on.indexOf(",sites,") >= 0 ? TUNNEL : "DIRECT";
    }
  }

  // Everything else, when chosen. DIRECT comes after the tunnel so that a site still opens while the
  // home Mac is down.
  return on.indexOf(",rest,") >= 0 ? TUNNEL + "; DIRECT" : "DIRECT";
}
