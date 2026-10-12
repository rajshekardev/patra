package main

import "core:fmt"
import "core:os"
import patra_compiler "../patra"

main :: proc() {
	args := os.args
	if len(args) < 2 {
		usage()
		return
	}

	switch args[1] {
	case "init":
		init_project()
	case "dev":
		dev_project()
	case "build":
		build_project_cli()
	case "deploy":
		deploy_project_cli()
	case "setup":
		setup_project()
	case "help", "--help", "-h":
		usage()
	case:
		fmt.eprintln("Unknown command:", args[1])
		usage()
	}
}

usage :: proc() {
	fmt.println("Patra CLI")
	fmt.println("Usage: patra <init|dev|build|deploy|setup>")
	fmt.println("  patra setup <vite|tailwindcss|effect>")
	fmt.println("  patra setup remove <vite|tailwindcss|effect>")
}
