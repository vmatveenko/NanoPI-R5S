package router

import (
	"errors"
	"fmt"
	"net"
	"regexp"
	"sort"
	"strings"

	"github.com/vmatveenko/nanopi-r5s/manager/internal/model"
)

var interfaceNamePattern = regexp.MustCompile(`^[A-Za-z0-9_.:-]{1,15}$`)

func Validate(cfg model.RouterConfig, available []model.Interface) error {
	var problems []string
	if !interfaceNamePattern.MatchString(cfg.WANInterface) {
		problems = append(problems, "invalid WAN interface")
	}
	if !interfaceNamePattern.MatchString(cfg.Bridge) {
		problems = append(problems, "invalid bridge name")
	}
	if cfg.WANInterface == cfg.Bridge {
		problems = append(problems, "WAN and bridge must differ")
	}
	if len(cfg.LANInterfaces) == 0 {
		problems = append(problems, "at least one LAN interface is required")
	}
	seen := map[string]bool{}
	for _, name := range cfg.LANInterfaces {
		if !interfaceNamePattern.MatchString(name) {
			problems = append(problems, "invalid LAN interface: "+name)
		}
		if name == cfg.WANInterface || name == cfg.Bridge {
			problems = append(problems, "interface has conflicting roles: "+name)
		}
		if seen[name] {
			problems = append(problems, "duplicate LAN interface: "+name)
		}
		seen[name] = true
	}

	availableNames := map[string]bool{}
	for _, item := range available {
		if item.Physical {
			availableNames[item.Name] = true
		}
	}
	if len(availableNames) > 0 {
		if availableNames[cfg.Bridge] {
			problems = append(problems, "bridge name conflicts with a physical interface")
		}
		if !availableNames[cfg.WANInterface] {
			problems = append(problems, "WAN interface is not a detected physical interface")
		}
		for _, name := range cfg.LANInterfaces {
			if !availableNames[name] {
				problems = append(problems, "LAN interface is not a detected physical interface: "+name)
			}
		}
	}

	lanIP, lanNet, err := net.ParseCIDR(cfg.LANCIDR)
	if err != nil || lanIP.To4() == nil {
		problems = append(problems, "LAN CIDR must be IPv4")
	} else {
		ones, bits := lanNet.Mask.Size()
		if bits != 32 || ones < 8 || ones > 30 {
			problems = append(problems, "LAN prefix must be between /8 and /30")
		}
		start := net.ParseIP(cfg.DHCPStart).To4()
		end := net.ParseIP(cfg.DHCPEnd).To4()
		broadcast := net.ParseIP(broadcastAddress(lanNet)).To4()
		if start == nil || !lanNet.Contains(start) {
			problems = append(problems, "DHCP start is outside LAN subnet")
		}
		if end == nil || !lanNet.Contains(end) {
			problems = append(problems, "DHCP end is outside LAN subnet")
		}
		if start != nil && end != nil && ipToUint(start) > ipToUint(end) {
			problems = append(problems, "DHCP start must not exceed DHCP end")
		}
		if start != nil && start.Equal(lanIP.To4()) || end != nil && end.Equal(lanIP.To4()) {
			problems = append(problems, "DHCP range must not include router address")
		}
		if start != nil && (start.Equal(lanNet.IP.To4()) || start.Equal(broadcast)) || end != nil && (end.Equal(lanNet.IP.To4()) || end.Equal(broadcast)) {
			problems = append(problems, "DHCP range must not include network or broadcast address")
		}
		for _, item := range available {
			if item.Name != cfg.WANInterface {
				continue
			}
			for _, address := range item.Addresses {
				_, wanNet, parseErr := net.ParseCIDR(address)
				if parseErr == nil && networksOverlap(lanNet, wanNet) {
					problems = append(problems, "LAN subnet overlaps the current WAN subnet")
				}
			}
		}
	}

	for _, dns := range cfg.DNS {
		if net.ParseIP(dns).To4() == nil {
			problems = append(problems, "DNS must be an IPv4 address: "+dns)
		}
	}
	if len(cfg.DNS) == 0 {
		problems = append(problems, "at least one DNS server is required")
	}
	if cfg.ManagerPort < 1 || cfg.ManagerPort > 65535 {
		problems = append(problems, "manager port must be between 1 and 65535")
	}
	if err := validateMAC(cfg); err != nil {
		problems = append(problems, err.Error())
	}
	portKeys := map[string]bool{}
	for _, rule := range cfg.WANPorts {
		protocol := strings.ToLower(rule.Protocol)
		if protocol != "tcp" && protocol != "udp" {
			problems = append(problems, "WAN port protocol must be tcp or udp")
		}
		if rule.Port < 1 || rule.Port > 65535 {
			problems = append(problems, "WAN port is outside 1..65535")
		}
		key := fmt.Sprintf("%s/%d", protocol, rule.Port)
		if portKeys[key] {
			problems = append(problems, "duplicate WAN port: "+key)
		}
		portKeys[key] = true
		if len(rule.Description) > 128 {
			problems = append(problems, "WAN port description is longer than 128 characters")
		}
		for _, source := range rule.Sources {
			if !validIPv4Source(source) {
				problems = append(problems, "invalid WAN source for "+key+": "+source)
			}
		}
	}
	if len(problems) > 0 {
		sort.Strings(problems)
		return errors.New(strings.Join(problems, "; "))
	}
	return nil
}

func validIPv4Source(value string) bool {
	value = strings.TrimSpace(value)
	if value == "" {
		return false
	}
	if ip := net.ParseIP(value); ip != nil {
		return ip.To4() != nil
	}
	ip, network, err := net.ParseCIDR(value)
	return err == nil && ip.To4() != nil && network.IP.To4() != nil
}

func networksOverlap(a, b *net.IPNet) bool {
	return a.Contains(b.IP) || b.Contains(a.IP)
}

func validateMAC(cfg model.RouterConfig) error {
	switch cfg.WANMACMode {
	case "", "current", "random":
		return nil
	case "manual", "clone", "factory":
		parsed, err := net.ParseMAC(cfg.WANMAC)
		if err != nil || len(parsed) != 6 || parsed[0]&1 != 0 {
			return errors.New("selected WAN MAC is unavailable or invalid")
		}
		return nil
	default:
		return errors.New("unsupported WAN MAC mode")
	}
}

func ipToUint(ip net.IP) uint32 {
	return uint32(ip[0])<<24 | uint32(ip[1])<<16 | uint32(ip[2])<<8 | uint32(ip[3])
}
