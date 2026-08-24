package model

import "time"

const (
	DefaultManagerPort = 8080
	DefaultPanelPort   = 2053
	DefaultBridge      = "br0"
	DefaultLANCIDR     = "192.168.10.1/24"
	DefaultDHCPStart   = "192.168.10.10"
	DefaultDHCPEnd     = "192.168.10.200"
	DefaultTUNName     = "xray0"
	DefaultTUNAddress  = "172.19.0.1/30"
)

type Interface struct {
	Name         string   `json:"name"`
	MAC          string   `json:"mac"`
	PermanentMAC string   `json:"permanentMac,omitempty"`
	State        string   `json:"state"`
	Carrier      bool     `json:"carrier"`
	Physical     bool     `json:"physical"`
	Addresses    []string `json:"addresses"`
	DefaultWAN   bool     `json:"defaultWan"`
}

type Inventory struct {
	Hostname       string      `json:"hostname"`
	Architecture   string      `json:"architecture"`
	OS             string      `json:"os"`
	Kernel         string      `json:"kernel"`
	DefaultRoute   string      `json:"defaultRoute"`
	DefaultGateway string      `json:"defaultGateway"`
	Interfaces     []Interface `json:"interfaces"`
	Warnings       []string    `json:"warnings,omitempty"`
}

type PortRule struct {
	Protocol    string `json:"protocol"`
	Port        int    `json:"port"`
	Description string `json:"description,omitempty"`
}

type RouterConfig struct {
	WANInterface  string     `json:"wanInterface"`
	WANMACMode    string     `json:"wanMacMode"`
	WANMAC        string     `json:"wanMac,omitempty"`
	LANInterfaces []string   `json:"lanInterfaces"`
	Bridge        string     `json:"bridge"`
	LANCIDR       string     `json:"lanCidr"`
	DHCPStart     string     `json:"dhcpStart"`
	DHCPEnd       string     `json:"dhcpEnd"`
	DNS           []string   `json:"dns"`
	ManagerPort   int        `json:"managerPort"`
	PanelPort     int        `json:"panelPort"`
	WANPorts      []PortRule `json:"wanPorts,omitempty"`
}

func DefaultRouterConfig() RouterConfig {
	return RouterConfig{
		WANMACMode:  "current",
		Bridge:      DefaultBridge,
		LANCIDR:     DefaultLANCIDR,
		DHCPStart:   DefaultDHCPStart,
		DHCPEnd:     DefaultDHCPEnd,
		DNS:         []string{"8.8.8.8", "1.1.1.1"},
		ManagerPort: DefaultManagerPort,
		PanelPort:   DefaultPanelPort,
	}
}

type FileChange struct {
	Path    string `json:"path"`
	Content string `json:"content"`
	Mode    uint32 `json:"mode"`
	Changed bool   `json:"changed"`
	Diff    string `json:"diff,omitempty"`
}

type Plan struct {
	Config   RouterConfig `json:"config"`
	Files    []FileChange `json:"files"`
	Commands []string     `json:"commands"`
	Warnings []string     `json:"warnings"`
}

type ApplyResult struct {
	RevisionID      string    `json:"revisionId"`
	RollbackDueAt   time.Time `json:"rollbackDueAt"`
	ConfirmationTTL int       `json:"confirmationTtlSeconds"`
}

type ComponentStatus struct {
	Name    string `json:"name"`
	OK      bool   `json:"ok"`
	Summary string `json:"summary"`
	Detail  string `json:"detail,omitempty"`
}

type Diagnostics struct {
	GeneratedAt time.Time         `json:"generatedAt"`
	Components  []ComponentStatus `json:"components"`
}

type XUITUNRequest struct {
	PanelURL string `json:"panelUrl"`
	APIToken string `json:"apiToken"`
	WAN      string `json:"wanInterface"`
}

type XUIActionRequest struct {
	Action    string `json:"action"`
	BackupID  string `json:"backupId,omitempty"`
	PanelPort int    `json:"panelPort,omitempty"`
}
