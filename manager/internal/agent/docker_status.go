package agent

import (
	"bufio"
	"context"
	"encoding/json"
	"strings"

	"github.com/vmatveenko/nanopi-r5s/manager/internal/model"
)

func (s *Service) DockerStatus(ctx context.Context) model.DockerStatus {
	if s.cfg.DryRun {
		return model.DockerStatus{Installed: true, DaemonActive: true, Version: "dry-run", ServerVersion: "dry-run", Containers: []model.ContainerStatus{}}
	}
	status := model.DockerStatus{Containers: []model.ContainerStatus{}}
	if output, err := s.runner.Run(ctx, "docker", "version", "--format", "{{.Client.Version}}"); err == nil {
		status.Installed = true
		status.Version = strings.TrimSpace(output)
	} else {
		status.Error = err.Error()
		return status
	}
	if output, err := s.runner.Run(ctx, "systemctl", "is-active", "docker.service"); err == nil && strings.TrimSpace(output) == "active" {
		status.DaemonActive = true
	}
	if output, err := s.runner.Run(ctx, "docker", "version", "--format", "{{.Server.Version}}"); err == nil {
		status.ServerVersion = strings.TrimSpace(output)
	} else if status.Error == "" {
		status.Error = err.Error()
	}
	if !status.DaemonActive {
		return status
	}
	output, err := s.runner.Run(ctx, "docker", "ps", "-a", "--no-trunc", "--format", "{{json .}}")
	if err != nil {
		status.Error = err.Error()
		return status
	}
	scanner := bufio.NewScanner(strings.NewReader(output))
	for scanner.Scan() {
		var row struct {
			ID     string `json:"ID"`
			Names  string `json:"Names"`
			Image  string `json:"Image"`
			State  string `json:"State"`
			Status string `json:"Status"`
		}
		if json.Unmarshal([]byte(scanner.Text()), &row) != nil {
			continue
		}
		container := model.ContainerStatus{Name: row.Names, Image: row.Image, State: row.State, Status: row.Status}
		if policy, inspectErr := s.runner.Run(ctx, "docker", "inspect", "-f", "{{.HostConfig.RestartPolicy.Name}}", row.ID); inspectErr == nil {
			container.RestartPolicy = strings.TrimSpace(policy)
		}
		status.Containers = append(status.Containers, container)
	}
	return status
}
