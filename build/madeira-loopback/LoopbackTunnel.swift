// SPDX-License-Identifier: GPL-3.0-or-later
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
//
// Madeira's own VPN, in place of LocalDevVPN (app/Madeira/MadeiraVPN.swift): a packet
// tunnel that hands this device's own traffic back to it. The JIT helper connects to
// 10.7.0.1; the tunnel swaps each packet's addresses, so lockdownd sees a connection from
// 10.7.0.1 to its tunnel address 10.7.0.0 and answers it as it would a computer's, and
// the answer comes back the same way. Swapping the two addresses leaves the IP and TCP
// checksums as they were. (The same tunnel as Lucid's LucidLoopback and UTM's
// UTMLoopback, which reached lockdownd this way on the iPhone Duo.)

import NetworkExtension

final class LoopbackTunnel: NEPacketTunnelProvider {
    private static let device = "10.7.0.0"
    private static let peer = "10.7.0.1"

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: Self.device)
        let ipv4 = NEIPv4Settings(addresses: [Self.device], subnetMasks: ["255.255.255.0"])
        ipv4.includedRoutes = [NEIPv4Route(destinationAddress: Self.device, subnetMask: "255.255.255.0")]
        settings.ipv4Settings = ipv4
        setTunnelNetworkSettings(settings) { [weak self] error in
            completionHandler(error)
            if error == nil { self?.relay() }
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        completionHandler()
    }

    private func relay() {
        packetFlow.readPackets { [weak self] packets, protocols in
            guard let self else { return }
            var back: [Data] = []
            var families: [NSNumber] = []
            for (packet, family) in zip(packets, protocols) {
                // IPv4 only; anything else has nowhere to go.
                guard packet.count >= 20, packet[packet.startIndex] >> 4 == 4 else { continue }
                var swapped = packet
                let s = swapped.startIndex
                let source = swapped[(s + 12)..<(s + 16)]
                swapped.replaceSubrange((s + 12)..<(s + 16), with: swapped[(s + 16)..<(s + 20)])
                swapped.replaceSubrange((s + 16)..<(s + 20), with: source)
                back.append(swapped)
                families.append(family)
            }
            if !back.isEmpty { self.packetFlow.writePackets(back, withProtocols: families) }
            self.relay()
        }
    }
}
