package router

import (
	"crypto/rand"
	"fmt"
	"net"
	"sort"
	"strings"

	"github.com/vmatveenko/nanopi-r5s/manager/internal/model"
)

func BuildPlan(cfg model.RouterConfig, available []model.Interface) (model.Plan, error) {
	if cfg.Bridge == "" {
		cfg.Bridge = model.DefaultBridge
	}
	if cfg.ManagerPort == 0 {
		cfg.ManagerPort = model.DefaultManagerPort
	}
	if cfg.PanelPort == 0 {
		cfg.PanelPort = model.DefaultPanelPort
	}
	if cfg.WANMACMode == "random" && cfg.WANMAC == "" {
		cfg.WANMAC = randomLocalMAC()
	}
	if cfg.WANMACMode == "factory" && cfg.WANMAC == "" {
		for _, item := range available {
			if item.Name == cfg.WANInterface {
				cfg.WANMAC = item.PermanentMAC
				break
			}
		}
	}
	if err := Validate(cfg, available); err != nil {
		return model.Plan{}, err
	}
	lanIP, lanNet, _ := net.ParseCIDR(cfg.LANCIDR)
	mask := net.IP(lanNet.Mask).String()
	network := lanNet.IP.String()
	broadcast := broadcastAddress(lanNet)

	files := []model.FileChange{
		{Path: "/etc/netplan/01-router.yaml", Content: "# Superseded by /etc/netplan/60-nanopi-manager.yaml.\n", Mode: 0o600},
		{Path: "/etc/netplan/60-nanopi-manager.yaml", Content: renderNetplan(cfg), Mode: 0o600},
		{Path: "/etc/dhcp/dhcpd.conf", Content: renderDHCP(cfg, network, mask, broadcast, lanIP.String()), Mode: 0o644},
		{Path: "/etc/default/isc-dhcp-server", Content: fmt.Sprintf("INTERFACESv4=\"%s\"\nINTERFACESv6=\"\"\n", cfg.Bridge), Mode: 0o644},
		{Path: "/etc/sysctl.d/90-nanopi-manager-router.conf", Content: renderSysctl(), Mode: 0o644},
		{Path: "/etc/nftables.conf", Content: renderNFTables(cfg), Mode: 0o600},
		{Path: "/etc/nanopi-manager/router.json", Content: renderConfigJSON(cfg), Mode: 0o600},
	}
	warnings := []string{
		"Applying network configuration can interrupt the current connection.",
		"The change must be confirmed within 120 seconds or it will be rolled back.",
		"Manager and 3x-ui panels remain blocked from WAN.",
	}
	return model.Plan{
		Config: cfg,
		Files:  files,
		Commands: []string{
			"netplan generate", "dhcpd -t", "nft -c", "systemd rollback timer (120s)",
			"sysctl --system", "systemctl restart nftables", "netplan apply", "systemctl restart isc-dhcp-server",
		},
		Warnings: warnings,
	}, nil
}

func renderNetplan(cfg model.RouterConfig) string {
	var b strings.Builder
	b.WriteString("# Managed by NanoPi Manager. Manual changes may be replaced.\n")
	b.WriteString("network:\n  version: 2\n  renderer: networkd\n  ethernets:\n")
	fmt.Fprintf(&b, "    %s:\n      dhcp4: true\n      dhcp6: false\n", cfg.WANInterface)
	if cfg.WANMACMode == "manual" || cfg.WANMACMode == "clone" || cfg.WANMACMode == "random" || cfg.WANMACMode == "factory" {
		fmt.Fprintf(&b, "      macaddress: %s\n", strings.ToLower(cfg.WANMAC))
	}
	for _, name := range cfg.LANInterfaces {
		fmt.Fprintf(&b, "    %s:\n      dhcp4: false\n      dhcp6: false\n      optional: true\n", name)
	}
	fmt.Fprintf(&b, "  bridges:\n    %s:\n      interfaces:\n", cfg.Bridge)
	for _, name := range cfg.LANInterfaces {
		fmt.Fprintf(&b, "        - %s\n", name)
	}
	fmt.Fprintf(&b, "      addresses:\n        - %s\n      dhcp4: false\n      dhcp6: false\n      parameters:\n        stp: false\n        forward-delay: 0\n", cfg.LANCIDR)
	return b.String()
}

func randomLocalMAC() string {
	value := make([]byte, 6)
	if _, err := rand.Read(value); err != nil {
		return "02:00:00:00:00:01"
	}
	value[0] = (value[0] | 2) & 0xfe
	return fmt.Sprintf("%02x:%02x:%02x:%02x:%02x:%02x", value[0], value[1], value[2], value[3], value[4], value[5])
}

func renderDHCP(cfg model.RouterConfig, network, mask, broadcast, routerIP string) string {
	dns := strings.Join(cfg.DNS, ", ")
	return fmt.Sprintf(`# Managed by NanoPi Manager.
authoritative;
default-lease-time 3600;
max-lease-time 86400;
ddns-update-style none;

subnet %s netmask %s {
  range %s %s;
  option subnet-mask %s;
  option broadcast-address %s;
  option routers %s;
  option domain-name-servers %s;
}
`, network, mask, cfg.DHCPStart, cfg.DHCPEnd, mask, broadcast, routerIP, dns)
}

func renderSysctl() string {
	return `# Managed by NanoPi Manager.
net.ipv4.ip_forward=1
net.ipv4.conf.all.rp_filter=0
net.ipv4.conf.default.rp_filter=0
net.ipv6.conf.all.disable_ipv6=1
net.ipv6.conf.default.disable_ipv6=1
`
}

func renderNFTables(cfg model.RouterConfig) string {
	tcpPorts := collectPorts(cfg.WANPorts, "tcp")
	udpPorts := collectPorts(cfg.WANPorts, "udp")
	var b strings.Builder
	b.WriteString("#!/usr/sbin/nft -f\n# Managed by NanoPi Manager.\nflush ruleset\n\n")
	b.WriteString("table inet nanopi_filter {\n")
	if len(tcpPorts) > 0 {
		fmt.Fprintf(&b, "  set wan_tcp_ports { type inet_service; elements = { %s } }\n", joinInts(tcpPorts))
	}
	if len(udpPorts) > 0 {
		fmt.Fprintf(&b, "  set wan_udp_ports { type inet_service; elements = { %s } }\n", joinInts(udpPorts))
	}
	b.WriteString("  chain input {\n    type filter hook input priority filter; policy drop;\n")
	b.WriteString("    iifname \"lo\" accept\n    ct state established,related accept\n    ct state invalid drop\n")
	b.WriteString("    ip protocol icmp accept\n")
	fmt.Fprintf(&b, "    iifname \"%s\" accept\n", cfg.Bridge)
	fmt.Fprintf(&b, "    iifname \"%s\" udp sport 67 udp dport 68 accept\n", cfg.WANInterface)
	if len(tcpPorts) > 0 {
		fmt.Fprintf(&b, "    iifname \"%s\" tcp dport @wan_tcp_ports ct state new accept\n", cfg.WANInterface)
	}
	if len(udpPorts) > 0 {
		fmt.Fprintf(&b, "    iifname \"%s\" udp dport @wan_udp_ports ct state new accept\n", cfg.WANInterface)
	}
	b.WriteString("  }\n  chain forward {\n    type filter hook forward priority filter; policy drop;\n")
	b.WriteString("    ct state established,related accept\n    ct state invalid drop\n")
	fmt.Fprintf(&b, "    iifname \"%s\" oifname \"%s\" accept\n", cfg.Bridge, cfg.WANInterface)
	fmt.Fprintf(&b, "    iifname \"%s\" oifname \"%s\" accept\n", cfg.Bridge, model.DefaultTUNName)
	fmt.Fprintf(&b, "    iifname \"%s\" oifname \"%s\" accept\n", model.DefaultTUNName, cfg.Bridge)
	b.WriteString("    ct status dnat accept\n  }\n}\n\n")
	b.WriteString("table inet nanopi_policy {\n  chain lan_mark {\n    type filter hook prerouting priority mangle; policy accept;\n")
	fmt.Fprintf(&b, "    iifname \"%s\" meta mark set 0x1\n  }\n}\n\n", cfg.Bridge)
	b.WriteString("table ip nanopi_nat {\n  chain prerouting { type nat hook prerouting priority dstnat; policy accept; }\n")
	b.WriteString("  chain postrouting {\n    type nat hook postrouting priority srcnat; policy accept;\n")
	fmt.Fprintf(&b, "    oifname \"%s\" masquerade\n  }\n}\n", cfg.WANInterface)
	return b.String()
}

func renderConfigJSON(cfg model.RouterConfig) string {
	// Deliberately small and deterministic; the state store keeps the full JSON.
	return fmt.Sprintf("{\n  \"wanInterface\": %q,\n  \"bridge\": %q,\n  \"lanCidr\": %q\n}\n", cfg.WANInterface, cfg.Bridge, cfg.LANCIDR)
}

func broadcastAddress(network *net.IPNet) string {
	ip := network.IP.To4()
	mask := network.Mask
	return net.IPv4(ip[0]|^mask[0], ip[1]|^mask[1], ip[2]|^mask[2], ip[3]|^mask[3]).String()
}

func collectPorts(rules []model.PortRule, protocol string) []int {
	var ports []int
	for _, rule := range rules {
		if strings.EqualFold(rule.Protocol, protocol) {
			ports = append(ports, rule.Port)
		}
	}
	sort.Ints(ports)
	return ports
}

func joinInts(values []int) string {
	parts := make([]string, len(values))
	for i, value := range values {
		parts[i] = fmt.Sprint(value)
	}
	return strings.Join(parts, ", ")
}
