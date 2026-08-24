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
	Protocol    string   `json:"protocol"`
	Port        int      `json:"port"`
	Description string   `json:"description,omitempty"`
	Sources     []string `json:"sources,omitempty"`
	Disabled    bool     `json:"disabled,omitempty"`
}

type RouterConfig struct {
	WANInterface      string     `json:"wanInterface"`
	WANMACMode        string     `json:"wanMacMode"`
	WANMAC            string     `json:"wanMac,omitempty"`
	LANInterfaces     []string   `json:"lanInterfaces"`
	Bridge            string     `json:"bridge"`
	LANCIDR           string     `json:"lanCidr"`
	DHCPStart         string     `json:"dhcpStart"`
	DHCPEnd           string     `json:"dhcpEnd"`
	DNS               []string   `json:"dns"`
	ManagerPort       int        `json:"managerPort"`
	ManagerWANAccess  bool       `json:"managerWanAccess"`
	ManagerWANSources []string   `json:"managerWanSources,omitempty"`
	PanelPort         int        `json:"panelPort"`
	WANPorts          []PortRule `json:"wanPorts,omitempty"`
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
	ManagerPort     int       `json:"managerPort"`
	ManagerRestart  bool      `json:"managerRestart"`
}

type RouterStatus struct {
	State            string    `json:"state"`
	Active           bool      `json:"active"`
	Pending          bool      `json:"pending"`
	BaselineRevision string    `json:"baselineRevision,omitempty"`
	PendingRevision  string    `json:"pendingRevision,omitempty"`
	RollbackDueAt    time.Time `json:"rollbackDueAt,omitempty"`
}

type FirewallStatus struct {
	RouterActive bool       `json:"routerActive"`
	InSync       bool       `json:"inSync"`
	Rules        []PortRule `json:"rules"`
	ManagerWAN   bool       `json:"managerWanAccess"`
	ManagerPort  int        `json:"managerPort"`
	SystemRules  []string   `json:"systemRules"`
	Detail       string     `json:"detail,omitempty"`
}

type FirewallApplyResult struct {
	Applied bool   `json:"applied"`
	Message string `json:"message"`
}

type ContainerStatus struct {
	Name          string `json:"name"`
	Image         string `json:"image"`
	State         string `json:"state"`
	Status        string `json:"status"`
	RestartPolicy string `json:"restartPolicy,omitempty"`
}

type DockerStatus struct {
	Installed     bool              `json:"installed"`
	DaemonActive  bool              `json:"daemonActive"`
	Version       string            `json:"version,omitempty"`
	ServerVersion string            `json:"serverVersion,omitempty"`
	Containers    []ContainerStatus `json:"containers"`
	Error         string            `json:"error,omitempty"`
}

type ReleaseInfo struct {
	Version      string    `json:"version"`
	Name         string    `json:"name"`
	Prerelease   bool      `json:"prerelease"`
	PublishedAt  time.Time `json:"publishedAt"`
	ReleaseURL   string    `json:"releaseUrl"`
	ArchiveURL   string    `json:"-"`
	ChecksumsURL string    `json:"-"`
}

type ReleaseStatus struct {
	CurrentVersion string        `json:"currentVersion"`
	Releases       []ReleaseInfo `json:"releases"`
}

type UpdateRequest struct {
	Version     string `json:"version"`
	ConfirmRisk bool   `json:"confirmRisk"`
}

type UpdateResult struct {
	Scheduled bool   `json:"scheduled"`
	Version   string `json:"version"`
	Message   string `json:"message"`
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
