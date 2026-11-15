// Evaluate a PAC file for host names, the way a browser would. Run with macOS's built-in jsc:
//   jsc tests/pac-eval.js -- <pac file> <host>...
// The two helpers a browser supplies are modelled honestly: a permissive stand-in would let every
// look-alike test pass without the PAC being safe at all.
function dnsDomainIs(h, d) { return h.length >= d.length && h.substring(h.length - d.length) === d; }
function shExpMatch(s, p) {
  var re = new RegExp('^' + p.replace(/[.+^${}()|[\]\\]/g, '\\$&').replace(/\*/g, '.*').replace(/\?/g, '.') + '$');
  return re.test(s);
}
load(arguments[0]);
for (var i = 1; i < arguments.length; i++) {
  print(arguments[i] + ' ' + FindProxyForURL('https://' + arguments[i] + '/', arguments[i]));
}
