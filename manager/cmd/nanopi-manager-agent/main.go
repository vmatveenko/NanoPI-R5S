package main

import (
	"context"
	"fmt"
	"os"
	"os/signal"
	"syscall"

	"github.com/vmatveenko/nanopi-r5s/manager/internal/agent"
	"github.com/vmatveenko/nanopi-r5s/manager/internal/config"
)

func main() {
	cfg, mode, revision := config.ParseAgent(os.Args[1:])
	service := agent.NewService(cfg, agent.ExecRunner{DryRun: cfg.DryRun})
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	var err error
	switch mode {
	case "serve":
		err = service.Serve(ctx)
	case "rollback":
		err = service.Rollback(ctx, revision)
	case "reconcile":
		err = service.ReconcilePolicy(ctx)
	case "finish-update":
		err = service.FinishManagerUpdate(ctx)
	default:
		err = fmt.Errorf("unsupported mode %q", mode)
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
