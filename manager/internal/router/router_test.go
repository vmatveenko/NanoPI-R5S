package router

import (
	"strings"
	"testing"

	"github.com/vmatveenko/nanopi-r5s/manager/internal/model"
)

func validConfig() model.RouterConfig {
	cfg := model.DefaultRouterConfig()
	cfg.WANInterface = "eth0"
	cfg.LANInterfaces = []string{"eth1", "eth2"}
	return cfg
}

func TestBuildPlanUsesDynamicInterfacesAndProtectsPanels(t *testing.T) {
	cfg := validConfig()
	cfg.WANPorts = []model.PortRule{{Protocol: "tcp", Port: 443, Description: "VLESS"}, {Protocol: "udp", Port: 8443, Description: "Hysteria2"}}
	plan, err := BuildPlan(cfg, nil)
	if err != nil {
		t.Fatal(err)
	}
	var nft, netplan string
	for _, file := range plan.Files {
		if file.Path == "/etc/nftables.conf" {
			nft = file.Content
		}
		if strings.Contains(file.Path, "netplan") {
			netplan = file.Content
		}
	}
	for _, expected := range []string{`iifname "br0"`, `oifname "eth0"`, `tcp dport 443 ct state new accept comment "VLESS"`, `udp dport 8443 ct state new accept comment "Hysteria2"`, `meta mark set 0x1`, `oifname "xray0"`} {
		if !strings.Contains(nft, expected) {
			t.Errorf("nftables missing %q", expected)
		}
	}
	if !strings.Contains(nft, `iifname "eth0" udp sport 67 udp dport 68 accept`) {
		t.Fatal("WAN DHCP reply rule missing")
	}
	if strings.Contains(nft, "8080") || strings.Contains(nft, "2053") {
		t.Fatal("management panel port leaked into WAN rules")
	}
	for _, expected := range []string{"eth0:", "eth1:", "eth2:", "br0:"} {
		if !strings.Contains(netplan, expected) {
			t.Errorf("netplan missing %q", expected)
		}
	}
}

func TestWANRulesSupportSourcesDisableAndManagerAccess(t *testing.T) {
	cfg := validConfig()
	cfg.WANPorts = []model.PortRule{
		{Protocol: "tcp", Port: 8080, Description: "NanoPi Manager", Sources: []string{"203.0.113.10", "198.51.100.0/24"}},
		{Protocol: "tcp", Port: 443, Description: "VLESS", Sources: []string{"203.0.113.0/24"}},
		{Protocol: "udp", Port: 8443, Description: "disabled", Disabled: true},
	}
	plan, err := BuildPlan(cfg, nil)
	if err != nil {
		t.Fatal(err)
	}
	var nft string
	for _, file := range plan.Files {
		if file.Path == "/etc/nftables.conf" {
			nft = file.Content
		}
	}
	for _, expected := range []string{
		`ip saddr { 198.51.100.0/24, 203.0.113.10 } tcp dport 8080 ct state new accept comment "NanoPi Manager"`,
		`ip saddr { 203.0.113.0/24 } tcp dport 443 ct state new accept comment "VLESS"`,
	} {
		if !strings.Contains(nft, expected) {
			t.Errorf("nftables missing %q", expected)
		}
	}
	if strings.Contains(nft, "8443") {
		t.Fatal("disabled rule was rendered")
	}
}

func TestRejectsUnsafeConfiguration(t *testing.T) {
	cfg := validConfig()
	cfg.LANInterfaces = []string{"eth0"}
	if err := Validate(cfg, nil); err == nil {
		t.Fatal("conflicting WAN/LAN accepted")
	}
	cfg = validConfig()
	cfg.DHCPStart = "10.0.0.2"
	if err := Validate(cfg, nil); err == nil {
		t.Fatal("out-of-range DHCP accepted")
	}
	cfg = validConfig()
	interfaces := []model.Interface{{Name: "eth0", Physical: true, Addresses: []string{"192.168.10.222/24"}}, {Name: "eth1", Physical: true}, {Name: "eth2", Physical: true}}
	if err := Validate(cfg, interfaces); err == nil {
		t.Fatal("overlapping WAN/LAN subnet accepted")
	}
}

func TestRandomMACIsLocallyAdministered(t *testing.T) {
	cfg := validConfig()
	cfg.WANMACMode = "random"
	plan, err := BuildPlan(cfg, nil)
	if err != nil {
		t.Fatal(err)
	}
	if plan.Config.WANMAC == "" {
		t.Fatal("random MAC not generated")
	}
	var netplan string
	for _, file := range plan.Files {
		if strings.Contains(file.Path, "60-nanopi-manager") {
			netplan = file.Content
		}
	}
	if !strings.Contains(netplan, "macaddress: "+plan.Config.WANMAC) {
		t.Fatal("random MAC not rendered")
	}
}

func TestFactoryMACComesFromInventory(t *testing.T) {
	cfg := validConfig()
	cfg.WANMACMode = "factory"
	interfaces := []model.Interface{{Name: "eth0", Physical: true, PermanentMAC: "00:11:22:33:44:55"}, {Name: "eth1", Physical: true}, {Name: "eth2", Physical: true}}
	plan, err := BuildPlan(cfg, interfaces)
	if err != nil {
		t.Fatal(err)
	}
	if plan.Config.WANMAC != "00:11:22:33:44:55" {
		t.Fatalf("unexpected factory MAC %q", plan.Config.WANMAC)
	}
}
