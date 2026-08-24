package router

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"runtime"
	"sort"
	"strings"

	"github.com/vmatveenko/nanopi-r5s/manager/internal/model"
)

type linkRecord struct {
	IfName    string   `json:"ifname"`
	Address   string   `json:"address"`
	OperState string   `json:"operstate"`
	LinkType  string   `json:"link_type"`
	Flags     []string `json:"flags"`
	AddrInfo  []struct {
		Family    string `json:"family"`
		Local     string `json:"local"`
		PrefixLen int    `json:"prefixlen"`
	} `json:"addr_info"`
}

type routeRecord struct {
	Dst     string `json:"dst"`
	Gateway string `json:"gateway"`
	Dev     string `json:"dev"`
}

func InventoryFromSystem() (inventory model.Inventory, err error) {
	inventory.Hostname, _ = os.Hostname()
	inventory.Architecture = runtime.GOARCH
	inventory.Kernel = commandOutput("uname", "-r")
	inventory.OS = readOSRelease()

	linksRaw, err := exec.Command("ip", "-json", "address", "show").Output()
	if err != nil {
		return inventory, fmt.Errorf("read interfaces: %w", err)
	}
	var links []linkRecord
	if err := json.Unmarshal(linksRaw, &links); err != nil {
		return inventory, fmt.Errorf("decode interfaces: %w", err)
	}
	routesRaw, _ := exec.Command("ip", "-json", "-4", "route", "show", "default").Output()
	var routes []routeRecord
	_ = json.Unmarshal(routesRaw, &routes)
	if len(routes) > 0 {
		inventory.DefaultRoute = routes[0].Dev
		inventory.DefaultGateway = routes[0].Gateway
	}
	for _, link := range links {
		if link.IfName == "lo" {
			continue
		}
		item := model.Interface{
			Name: link.IfName, MAC: link.Address, State: strings.ToLower(link.OperState),
			Carrier: contains(link.Flags, "LOWER_UP"), Physical: isPhysical(link.IfName),
			DefaultWAN: link.IfName == inventory.DefaultRoute,
		}
		if item.Physical {
			item.PermanentMAC = permanentMAC(link.IfName)
		}
		for _, addr := range link.AddrInfo {
			if addr.Family == "inet" {
				item.Addresses = append(item.Addresses, fmt.Sprintf("%s/%d", addr.Local, addr.PrefixLen))
			}
		}
		inventory.Interfaces = append(inventory.Interfaces, item)
	}
	sort.Slice(inventory.Interfaces, func(i, j int) bool { return inventory.Interfaces[i].Name < inventory.Interfaces[j].Name })
	return inventory, nil
}

func permanentMAC(name string) string {
	out, err := exec.Command("ethtool", "-P", name).Output()
	if err != nil {
		return ""
	}
	parts := strings.Fields(string(out))
	if len(parts) == 0 {
		return ""
	}
	return strings.ToLower(parts[len(parts)-1])
}

func isPhysical(name string) bool {
	_, err := os.Stat("/sys/class/net/" + name + "/device")
	return err == nil
}

func contains(values []string, expected string) bool {
	for _, value := range values {
		if value == expected {
			return true
		}
	}
	return false
}

func readOSRelease() string {
	f, err := os.Open("/etc/os-release")
	if err != nil {
		return runtime.GOOS
	}
	defer f.Close()
	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := scanner.Text()
		if strings.HasPrefix(line, "PRETTY_NAME=") {
			return strings.Trim(strings.TrimPrefix(line, "PRETTY_NAME="), "\"")
		}
	}
	return runtime.GOOS
}

func commandOutput(name string, args ...string) string {
	out, err := exec.Command(name, args...).Output()
	if err != nil && !errors.Is(err, exec.ErrNotFound) {
		return "unknown"
	}
	return strings.TrimSpace(string(out))
}
