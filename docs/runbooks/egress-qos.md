# Egress QoS for seeding traffic

This runbook shapes outbound bandwidth so bulk seeding cannot starve customer traffic, while allowing bulk to borrow the full link when the cluster is idle.

## Deploy
1. Set the WAN interface and rates in `platform/networking/egress-qos/daemonset.yaml` (`WAN_IFACE`, `LINK_CEIL`, `BULK_RATE`, `BULK_CEIL`). `BULK_RATE` is the guaranteed share; `BULK_CEIL` lets bulk borrow up to the ceiling (keep it equal to `LINK_CEIL` to allow 100% usage when idle).
2. Apply the DaemonSet: `kubectl apply -k platform/networking/egress-qos`.
3. Label bulk pods (already added for the seeding job) with `traffic-tier=bulk-seed`.

## Verify it’s active
- Check tc: `tc qdisc show dev <WAN_IFACE>` and `tc class show dev <WAN_IFACE>` (you should see root `htb` and classes `1:10` default, `1:20` bulk).
- Check mark/filter: `iptables -t mangle -L PREROUTING -n -v | grep bulkseed` (rule matching the ipset and setting mark 0x1).
- Check ipset contents: `ipset list bulkseed-pods`.

## Functional test (borrow-when-idle, yield-on-load)
Pick any reachable iperf3 server (LAN box or an internet test host).
1. Start a high-priority flow:  
   `kubectl run user-iperf --rm -i --restart=Never --image=ghcr.io/networkstatic/iperf3 -- iperf3 -c <SERVER> -t 40`
2. In another terminal, start a bulk flow (labelled):  
   `kubectl run bulk-iperf --rm -i --restart=Never --labels=traffic-tier=bulk-seed --image=ghcr.io/networkstatic/iperf3 -- iperf3 -c <SERVER> -t 60`
3. Observe `tc -s class show dev <WAN_IFACE>` during the run: bytes in `1:20` should grow, but when `user-iperf` is active, `1:10` holds its share and `1:20` is capped near `BULK_RATE`. When `user-iperf` stops, `1:20` can climb toward the full link up to `BULK_CEIL`.

## Static cap fallback
If you prefer a hard cap instead of priority: enable the CNI `bandwidth` plugin in flannel’s conflist (`/etc/cni/net.d/10-flannel.conflist`) and annotate seeding pods with `kubernetes.io/egress-bandwidth: 50M`. This enforces a per-pod ceiling without tc shaping.
