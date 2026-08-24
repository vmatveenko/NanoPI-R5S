package model

import "strings"

func TCPPortRuleIndex(rules []PortRule, port int) int {
	for index, rule := range rules {
		if strings.EqualFold(rule.Protocol, "tcp") && rule.Port == port {
			return index
		}
	}
	return -1
}

func TCPPortOpen(rules []PortRule, port int) bool {
	index := TCPPortRuleIndex(rules, port)
	return index >= 0 && !rules[index].Disabled
}

// SetTCPPortAccess keeps a panel rule ordinary and editable while moving it
// with the service port. An existing rule on the destination port wins because
// it represents an explicit firewall choice made by the user.
func SetTCPPortAccess(rules []PortRule, previousPort, port int, enabled bool, description string) []PortRule {
	result := append([]PortRule(nil), rules...)
	oldIndex := TCPPortRuleIndex(result, previousPort)
	newIndex := TCPPortRuleIndex(result, port)

	if previousPort != port && oldIndex >= 0 {
		if newIndex >= 0 {
			result = append(result[:oldIndex], result[oldIndex+1:]...)
			newIndex = TCPPortRuleIndex(result, port)
		} else {
			result[oldIndex].Port = port
			newIndex = oldIndex
		}
	}
	if newIndex < 0 {
		newIndex = TCPPortRuleIndex(result, port)
	}
	if newIndex >= 0 {
		result[newIndex].Disabled = !enabled
		return result
	}
	if enabled {
		result = append(result, PortRule{Protocol: "tcp", Port: port, Description: description})
	}
	return result
}
