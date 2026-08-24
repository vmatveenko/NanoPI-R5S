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
	cfg.ManagerWANSources = normalizeSources(cfg.ManagerWANSources)
	for index := range cfg.WANPorts {
		cfg.WANPorts[index].Protocol = strings.ToLower(strings.TrimSpace(cfg.WANPorts[index].Protocol))
		cfg.WANPorts[index].Description = strings.TrimSpace(cfg.WANPorts[index].Description)
		cfg.WANPorts[index].Sources = normalizeSources(cfg.WANPorts[index].Sources)
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
		{Path: "/etc/netplan/60-nanopi-manager.yaml", Content: renderNetplan(cfg), Mode: 0o600},
		{Path: "/etc/dhcp/dhcpd.conf", Content: renderDHCP(cfg, network, mask, broadcast, lanIP.String()), Mode: 0o644},
		{Path: "/etc/default/isc-dhcp-server", Content: fmt.Sprintf("INTERFACESv4=\"%s\"\nINTERFACESv6=\"\"\n", cfg.Bridge), Mode: 0o644},
		{Path: "/etc/sysctl.d/90-nanopi-manager-router.conf", Content: renderSysctl(), Mode: 0o644},
		{Path: "/etc/nftables.conf", Content: renderNFTables(cfg), Mode: 0o600},
		{Path: "/etc/nanopi-manager/router.json", Content: renderConfigJSON(cfg), Mode: 0o600},
		{Path: "/etc/nanopi-manager/manager.env", Content: renderManagerEnvironment(cfg), Mode: 0o640},
	}
	warnings := []string{
		"Applying network configuration can interrupt the current connection.",
		"The change must be confirmed within 120 seconds or it will be rolled back.",
	}
	if cfg.ManagerWANAccess {
		warnings = append(warnings, "Manager is exposed on WAN over HTTP without TLS; use source filtering whenever possible.")
	} else {
		warnings = append(warnings, "Manager and 3x-ui panels remain blocked from WAN.")
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
	var b strings.Builder
	b.WriteString("#!/usr/sbin/nft -f\n# Managed by NanoPi Manager.\nflush ruleset\n\n")
	b.WriteString("table inet nanopi_filter {\n")
	b.WriteString("  chain input {\n    type filter hook input priority filter; policy drop;\n")
	b.WriteString("    iifname \"lo\" accept\n    ct state established,related accept\n    ct state invalid drop\n")
	b.WriteString("    ip protocol icmp accept\n")
	fmt.Fprintf(&b, "    iifname \"%s\" accept\n", cfg.Bridge)
	fmt.Fprintf(&b, "    iifname \"%s\" udp sport 67 udp dport 68 accept\n", cfg.WANInterface)
	if cfg.ManagerWANAccess {
		writeWANAcceptRule(&b, cfg.WANInterface, "tcp", cfg.ManagerPort, cfg.ManagerWANSources, "NanoPi Manager WAN")
	}
	for _, rule := range cfg.WANPorts {
		if !rule.Disabled {
			writeWANAcceptRule(&b, cfg.WANInterface, rule.Protocol, rule.Port, rule.Sources, rule.Description)
		}
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

func RenderNFTables(cfg model.RouterConfig) string { return renderNFTables(cfg) }

func writeWANAcceptRule(b *strings.Builder, wan, protocol string, port int, sources []string, description string) {
	fmt.Fprintf(b, "    iifname \"%s\" ", wan)
	if len(sources) > 0 {
		fmt.Fprintf(b, "ip saddr { %s } ", strings.Join(sources, ", "))
	}
	fmt.Fprintf(b, "%s dport %d ct state new accept", protocol, port)
	if description != "" {
		fmt.Fprintf(b, " comment \"%s\"", strings.NewReplacer(`\`, `\\`, `"`, `\"`).Replace(description))
	}
	b.WriteString("\n")
}

func renderManagerEnvironment(cfg model.RouterConfig) string {
	return fmt.Sprintf("# Managed by NanoPi Manager.\nNANOPI_MANAGER_PORT=%d\nNANOPI_MANAGER_STATE_DIR=/var/lib/nanopi-manager\nNANOPI_MANAGER_SOCKET=/run/nanopi-manager/agent.sock\n", cfg.ManagerPort)
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

func normalizeSources(values []string) []string {
	seen := map[string]bool{}
	result := make([]string, 0, len(values))
	for _, value := range values {
		value = strings.TrimSpace(value)
		if value != "" && !seen[value] {
			seen[value] = true
			result = append(result, value)
		}
	}
	sort.Strings(result)
	return result
}
