package model

import "testing"

func TestSetTCPPortAccessCreatesDisablesAndMovesOrdinaryRule(t *testing.T) {
	rules := SetTCPPortAccess(nil, 8080, 8080, true, "NanoPi Manager")
	if len(rules) != 1 || rules[0].Port != 8080 || rules[0].Disabled {
		t.Fatalf("rule was not created: %#v", rules)
	}
	rules[0].Sources = []string{"203.0.113.0/24"}
	rules = SetTCPPortAccess(rules, 8080, 9090, true, "NanoPi Manager")
	if len(rules) != 1 || rules[0].Port != 9090 || len(rules[0].Sources) != 1 {
		t.Fatalf("rule metadata was not moved: %#v", rules)
	}
	rules = SetTCPPortAccess(rules, 9090, 9090, false, "NanoPi Manager")
	if !rules[0].Disabled || TCPPortOpen(rules, 9090) {
		t.Fatalf("rule was not disabled: %#v", rules)
	}
}

func TestSetTCPPortAccessKeepsExistingDestinationRule(t *testing.T) {
	rules := []PortRule{{Protocol: "tcp", Port: 8080, Description: "manager"}, {Protocol: "tcp", Port: 9090, Description: "explicit", Sources: []string{"192.0.2.4"}}}
	rules = SetTCPPortAccess(rules, 8080, 9090, true, "manager")
	if len(rules) != 1 || rules[0].Description != "explicit" || rules[0].Disabled {
		t.Fatalf("destination rule did not win: %#v", rules)
	}
}
