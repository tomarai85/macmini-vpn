// paceval <pac-file> <host>...: evaluate a PAC file with Apple's own engine, the one Safari and every
// CFNetwork app use. Prints "  host: verdict" per host. Used by pac.test.sh.
import Foundation
let script = try! String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
for host in CommandLine.arguments.dropFirst(2) {
    var err: Unmanaged<CFError>?
    let url = URL(string: "https://\(host)/")! as CFURL
    let list = CFNetworkCopyProxiesForAutoConfigurationScript(script as CFString, url, &err)?.takeRetainedValue() as? [[String: Any]] ?? []
    let v = list.map { d -> String in
        let t = (d[kCFProxyTypeKey as String] as? String) ?? "?"
        return t == (kCFProxyTypeNone as String) ? "DIRECT" : "\(t.replacingOccurrences(of: "kCFProxyType", with: "")) \(d[kCFProxyHostNameKey as String] ?? ""):\(d[kCFProxyPortNumberKey as String] ?? "")"
    }.joined(separator: "; ")
    print("  \(host): \(v)")
}
