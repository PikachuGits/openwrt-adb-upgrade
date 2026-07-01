# Debug Session: openwrt-no-uplink

- Status: OPEN
- Started: 2026-06-13
- Target: OpenWrt `192.168.6.1`
- Symptom: Source `192.168.2.41` can reach OpenWrt, but traffic forwarded through OpenWrt cannot access the Internet.

## Context

- OpenWrt address: `192.168.6.1`
- Login user: `root`
- Password: none
- Upstream related device: iKuai `192.168.1.1`
- Observed fact: traffic from `192.168.2.41` can enter OpenWrt, but cannot reach external network.

## Falsifiable Hypotheses

1. OpenWrt default route or WAN route is missing, so forwarded packets from `192.168.2.41` never leave the router.
2. OpenWrt forwarding is enabled, but NAT/masquerade on the egress zone is missing, so return traffic does not know how to get back.
3. OpenWrt firewall zone forwarding or policy routing blocks packets sourced from `192.168.2.41`.
4. The phone tethering interface is up, but DNS or upstream connectivity on OpenWrt itself is broken, so clients appear to have "no network".
5. Reverse path or asymmetric routing exists between iKuai and OpenWrt, so packets enter OpenWrt but replies are sent to the wrong next hop.

## Evidence Plan

- Check OpenWrt interface, addresses, routes, and policy routing rules.
- Check firewall zones, forwarding, and masquerade settings.
- Check whether OpenWrt itself can ping public IP and resolve DNS.
- Check packet path from OpenWrt for traffic related to `192.168.2.41`.

## Notes

- No configuration changes have been made yet.

## Evidence Collected

- OpenWrt itself has Internet access:
  - `ping 223.5.5.5` succeeds.
  - `nslookup openwrt.org 223.5.5.5` succeeds.
  - `ping openwrt.org` succeeds.
- Kernel forwarding is enabled:
  - `net.ipv4.ip_forward = 1`
- Reverse path filtering is not blocking this path:
  - `net.ipv4.conf.all.rp_filter = 0`
  - `net.ipv4.conf.br-lan.rp_filter = 0`
- Firewall forwarding and NAT are present:
  - `lan -> wan` forwarding exists.
  - `wan` zone has `masq='1'`.
  - `usb0..usb6` are all attached to `wan` zone.
- Critical routing evidence:
  - Main table contains `default via 192.168.1.1 dev br-lan`
  - Route lookup for Internet traffic resolves to `192.168.1.1 dev br-lan`
  - `ip route get 223.5.5.5 from 192.168.2.41 iif br-lan` returns:
    - `via 192.168.1.1 dev br-lan`

## Hypothesis Status

1. Missing default route on OpenWrt: REJECTED
2. Missing NAT/masquerade on egress zone: REJECTED
3. Firewall blocks forwarding from LAN to WAN: REJECTED
4. OpenWrt upstream or DNS is broken: REJECTED
5. Wrong egress selection / asymmetric routing via iKuai and OpenWrt: CONFIRMED

## Current Conclusion

- Traffic from `192.168.2.41` reaches OpenWrt.
- OpenWrt then chooses `192.168.1.1` on `br-lan` as next hop for Internet traffic.
- Therefore the packet does not leave through the phone tethering interfaces in the `wan` zone.
- Because egress remains `br-lan`, WAN masquerade does not apply, and the intended "OpenWrt as mobile uplink" path is never taken.

## USB Phone App Findings

- The LuCI page stores mappings in `usb_port_manager`, not in a dedicated `usb-phone` config.
- Current saved binding exists:
  - `phone1` / alias `手机1`
  - interface `usb1`
  - target IP `192.168.2.41`
- The dashboard `save` action only writes config and does not apply runtime rules.
- Runtime rule application depends on `/usr/bin/usb-phone-apply`.
- Current kernel state shows `fwmark` routing rules exist for tables `10` and `11`, but no active nft rule was found to mark packets from `192.168.2.41`.
- This strongly indicates the saved UI binding did not translate into an active packet-marking rule.

## Practical Root Cause

- The intended policy routing path is:
  - `192.168.2.41` -> mark packet -> `ip rule` -> table `10` -> `usb1`
- The currently active path is:
  - `192.168.2.41` -> no effective mark match -> main table -> `192.168.1.1` on `br-lan`

## Fix Applied

- Replaced the old `nft mark + fwmark rule` approach in `/usr/bin/usb-phone-apply`.
- New logic uses direct source-based policy routing:
  - `ip rule add from <target_ip> lookup <table>`
  - `ip route replace default via <gateway> dev <usbX> table <table>`
- Removed dependency on the missing/non-active `inet fw4 mangle_prerouting` chain.
- Updated `/www/cgi-bin/usb-phone` so page `save` also triggers `/usr/bin/usb-phone-apply`.

## Post-Fix Evidence

- `ip rule show` now contains:
  - `10010: from 192.168.2.41 lookup 10`
- `ip route show table 10` now contains:
  - `default via 192.168.70.194 dev usb1 src 192.168.70.58`
- Route resolution now confirms the expected egress:
  - `ip route get 223.5.5.5 from 192.168.2.41 iif br-lan`
  - Result: `via 192.168.70.194 dev usb1`
- Simulated page save via:
  - `/cgi-bin/usb-phone?action=save&phone=phone1&ip=192.168.2.41`
  - Result remains correct after save; no manual apply needed.

## Additional Root Cause Found

- After the routing fix, client traffic still failed.
- Runtime inspection showed:
  - `/etc/init.d/firewall status` returned `inactive`
  - `nft list ruleset` returned an empty live ruleset
- This means OpenWrt had firewall configuration on disk, but no active NAT/forwarding rules loaded in kernel.

## Additional Fix Applied

- Restarted and enabled the firewall service:
  - `fw4 restart`
  - `/etc/init.d/firewall enable`
  - `/etc/init.d/firewall start`
- Post-fix runtime evidence:
  - `/etc/init.d/firewall status` -> `active with no instances`
  - `nft list tables` -> `table inet fw4`
  - `nft list chain inet fw4 srcnat` shows WAN source NAT chain is active

## UI Mapping Bug Found

- The USB phone dashboard listed rows in live interface order: `usb0`, `usb1`, `usb2`, ...
- But the save action used synthetic ids `phone1`, `phone2`, ... based on row index.
- These ids do not match the actual UCI section order.
- Result:
  - Clicking the second row could save into `phone2` even when the actual row belonged to `phone1`
  - The same client IP could end up bound to the wrong USB port, or even to multiple phones

## UI Mapping Fix Applied

- `/usr/bin/usb-phone-status` now returns the real config `section` for each displayed phone row.
- LuCI dashboard save logic now uses the real section id instead of row index.
- Existing duplicate binding was cleaned:
  - `192.168.2.41` remains only on `phone1 / usb1`
  - Wrong duplicate entry on `phone2 / usb5` was cleared

## Unbind Support Applied

- Dashboard save now always submits the `ip` parameter, even when the field is empty.
- CGI save logic now treats an explicit empty `ip=` as "clear this binding".
- Validation:
  - Temporary binding on `phone3` was cleared successfully
  - `uci get usb_port_manager.phone3.target_ip` became empty
  - `/usr/bin/usb-phone-status` also reported `target_ip` as empty
