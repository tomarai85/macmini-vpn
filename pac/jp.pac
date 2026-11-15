// jp.pac — which sites go through the Mac in Japan. Everything not listed here goes DIRECT.
//
// The installer copies this file to ~/.config/macmini-vpn/pac/jp.pac and replaces the port in
// PROXY with your SOCKS_PORT. To add a site, add its domain to `jp` (and, if its video comes from
// another domain, to `media`), then run ./install.sh again.
//
// NETFLIX: every Netflix host, sign-in included, goes through the same exit. If the sign-in came
// from your own country and the playback from Japan, the session would mix two countries, and
// Netflix refuses that (error M7037).
//
// SIGN-IN AND PAYMENT PAGES of the other services stay DIRECT (the `sensitive` list), so your
// account and card pages are never sent through the tunnel when they don't need to be.

function FindProxyForURL(url, host) {
  var h = ("" + host).toLowerCase();
  // A trailing dot is a legal form of a host name and would defeat a plain suffix match.
  if (h.charAt(h.length - 1) === ".") { h = h.substring(0, h.length - 1); }

  // Every label is checked, not only the first: foo.login.abema.tv is a sign-in host too.
  var sensitive = ["account", "accounts", "billing", "payment", "pay", "login", "signin",
                   "auth", "id", "my", "member", "mypage", "secure"];
  var nfExempt = (h === "netflix.com" || dnsDomainIs(h, ".netflix.com"));
  var labels = h.split(".");
  if (!nfExempt) {
    for (var L = 0; L < labels.length; L++) {
      for (var s = 0; s < sensitive.length; s++) {
        if (labels[L] === sensitive[s]) { return "DIRECT"; }
      }
    }
  }

  var PROXY = "SOCKS5 127.0.0.1:1082";

  var jp = ["tver.jp", "abema.tv", "abema.io", "radiko.jp", "nhk.or.jp", "nhk.jp",
            "netflix.com"];
  for (var i = 0; i < jp.length; i++) {
    if (h === jp[i] || dnsDomainIs(h, "." + jp[i])) {
      return PROXY;
    }
  }

  // The video does not come from the same domain as the page. ABEMA streams from akamaized.net,
  // radiko from smartstream.ne.jp and radiko-cf.com, NHK from drdi.st.nhk, Netflix from its own CDN.
  // With only the page domains, the page loads through Japan and the video is then requested from
  // your own country and refused.
  //
  // akamaized.net and smartstream.ne.jp are shared CDNs that carry other companies' traffic too, so
  // each pattern requires the service name at a hyphen or label boundary (ds-vod-abematv..., not
  // myabematvthing...). These host names were read from the services' own player configuration.
  var media = ["*-abematv.akamaized.net", "abematv.akamaized.net",
               "*-radiko.smartstream.ne.jp", "radiko.smartstream.ne.jp",
               "*.radiko-cf.com",
               "*.drdi.st.nhk",
               "*.nflxvideo.net", "*.nflxso.net", "*.nflximg.net"];
  for (var m = 0; m < media.length; m++) {
    if (shExpMatch(h, media[m])) {
      return PROXY;
    }
  }
  return "DIRECT";
}
