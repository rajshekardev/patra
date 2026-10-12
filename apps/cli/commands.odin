package main

import "core:bufio"
import "core:fmt"
import "core:net"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import patra_compiler "../patra"

CONFIG_FILE :: "patra.config.odin"
dev_tailwind_revision: string
dev_build_revision: string
SERVER_PLATFORMS := [2]string{"Render", "Fly"}
EDGE_PLATFORMS := [2]string{"Vercel", "Cloudflare"}
STATIC_RUNTIME := [1]string{"None"}
WORKER_RUNTIME := [1]string{"Worker"}
FUNCTION_RUNTIMES := [2]string{"Bun", "Node"}
SERVER_RUNTIMES := [3]string{"Native", "Bun", "Node"}

Project_Choices :: enum {Full_Stack, Split}
Deploy_Choices  :: enum {CLI, Manual}

Project_Config :: struct {
	name: string,
	architecture: string,
	backend_mode: string,
	backend_runtime: string,
	backend_platform: string,
	backend_deploy: string,
	frontend_mode: string,
	frontend_runtime: string,
	frontend_platform: string,
	frontend_deploy: string,
	ssr: bool,
	port: int,
	vite: bool,
	tailwind: string,
	effect: bool,
}

prompt :: proc(reader: ^bufio.Reader, question: string) -> string {
	fmt.printf("%s: ", question)
	os.flush(os.stdout)
	line, err := bufio.reader_read_string(reader, '\n', context.temp_allocator)
	if err != nil do return ""
	return strings.trim_space(line)
}

choose :: proc(reader: ^bufio.Reader, question: string, choices: []string, default_index: int = 0) -> int {
	for {
		fmt.println(question)
		for choice, i in choices {
			marker := " "
			if i == default_index do marker = " (default)"
			fmt.printf("  %d) %s%s\n", i+1, choice, marker)
		}
		answer := prompt(reader, "Select")
		if answer == "" do return default_index
		n, parsed := strconv.parse_int(answer)
		if parsed && n >= 1 && n <= len(choices) do return n-1
		fmt.eprintln("Enter a number from 1 to", len(choices))
	}
}

yes_no :: proc(reader: ^bufio.Reader, question: string, default_yes: bool) -> bool {
	for {
		default := "y/N"
		if default_yes do default = "Y/n"
		answer := strings.to_lower(prompt(reader, fmt.tprintf("%s [%s]", question, default)))
		if answer == "" do return default_yes
		if answer == "y" || answer == "yes" do return true
		if answer == "n" || answer == "no" do return false
		fmt.eprintln("Please answer y or n")
	}
}

init_project :: proc() {
	reader: bufio.Reader
	bufio.reader_init(&reader, os.to_stream(os.stdin))
	defer bufio.reader_destroy(&reader)

	name := prompt(&reader, "Project name")
	if !valid_project_name(name) {
		fmt.eprintln("Use a non-empty folder name containing letters, numbers, spaces, dots, hyphens, or underscores")
		return
	}
	if os.exists(name) {
		fmt.eprintln("Project folder already exists:", name)
		return
	}

	architecture_choice := choose(&reader, "Project architecture", []string{"Full stack (one deployable)", "Split frontend and backend (independent deployables)"})
	architecture := "Full_Stack"
	if architecture_choice == int(Project_Choices.Split) do architecture = "Split"

	backend_mode_choices := []string{"Server", "Serverless"}
	backend_mode_index := choose(&reader, "Backend mode", backend_mode_choices)
	backend_mode := backend_mode_choices[backend_mode_index]

	frontend_mode_choices := []string{"Server", "Serverless", "Static"}
	if architecture == "Full_Stack" {
		if backend_mode == "Server" {
			frontend_mode_choices = []string{"Server", "Static"}
		} else {
			frontend_mode_choices = []string{"Serverless", "Static"}
		}
	}
	ssr := true
	frontend_mode := ""
	for {
		frontend_mode_index := choose(&reader, "Frontend mode", frontend_mode_choices)
		frontend_mode = frontend_mode_choices[frontend_mode_index]
		if frontend_mode == "Static" {
			fmt.println("Static frontends cannot use SSR.")
			if !yes_no(&reader, "Disable SSR for this project?", false) {
				fmt.println("Choose another frontend mode.")
				continue
			}
			ssr = false
			break
		}
		ssr = !yes_no(&reader, "Disable SSR?", false)
		break
	}

	backend_platform := ""
	frontend_platform := ""
	if architecture == "Full_Stack" {
		platforms := []string{"Render", "Fly", "Vercel", "Cloudflare"}
		if backend_mode == "Server" {
			platforms = []string{"Render", "Fly"}
		} else if frontend_mode == "Serverless" {
			platforms = []string{"Vercel", "Cloudflare"}
		} else {
			platforms = []string{"Vercel", "Cloudflare"}
		}
		selected := platforms[choose(&reader, "Deployment platform", platforms)]
		backend_platform = selected
		frontend_platform = selected
	} else {
		backend_platforms := platform_options(backend_mode)
		backend_platform = backend_platforms[choose(&reader, "Backend deployment platform", backend_platforms)]
		frontend_platforms := platform_options(frontend_mode)
		frontend_platform = frontend_platforms[choose(&reader, "Frontend deployment platform", frontend_platforms)]
	}

	backend_runtimes := runtime_options(backend_mode, backend_platform)
	runtime_question := "Backend runtime"
	if architecture == "Full_Stack" do runtime_question = "Application runtime"
	backend_runtime := backend_runtimes[choose(&reader, runtime_question, backend_runtimes)]
	frontend_runtime := "None"
	if frontend_mode != "Static" {
		if architecture == "Full_Stack" {
			frontend_runtime = backend_runtime
		} else {
			frontend_runtimes := runtime_options(frontend_mode, frontend_platform)
			frontend_runtime = frontend_runtimes[choose(&reader, "Frontend runtime", frontend_runtimes)]
		}
	}

	port_text := prompt(&reader, "Development port [3000]")
	port := 3000
	if port_text != "" {
		parsed, valid := strconv.parse_int(port_text)
		if !valid || parsed < 1 || parsed > 65535 {
			fmt.eprintln("Port must be a number from 1 to 65535")
			return
		}
		port = parsed
	}

	deploy_mode := choose_deployment_preference(&reader, "Deployment preference")
	frontend_deploy_mode := deploy_mode
	if architecture == "Split" {
		frontend_deploy_mode = choose_deployment_preference(&reader, "Frontend deployment preference")
	}
	vite := yes_no(&reader, "Use Vite and npm packages?", false)
	tailwind := "None"
	if yes_no(&reader, "Use Tailwind CSS?", true) {
		tailwind = "CLI"
		if vite do tailwind = "Vite"
	}
	effect := yes_no(&reader, "Add Effect?", false)
	if effect && !vite {
		fmt.println("Effect uses npm packages. Vite is required for npm imports.")
		vite = yes_no(&reader, "Enable Vite for Effect?", true)
		if !vite { effect = false; fmt.println("Effect was skipped because Vite is disabled.") }
	}
	if tailwind == "CLI" do fmt.println("Install the standalone Tailwind CLI to build CSS: https://tailwindcss.com/docs/installation/tailwind-cli")

	if err := os.make_directory(name); err != nil {
		fmt.eprintln("Could not create project folder:", err)
		return
	}
	project := Project_Config{
		name = name,
		architecture = architecture,
		backend_mode = backend_mode,
		backend_runtime = backend_runtime,
		backend_platform = backend_platform,
		backend_deploy = deploy_mode,
		frontend_mode = frontend_mode,
		frontend_runtime = frontend_runtime,
		frontend_platform = frontend_platform,
		frontend_deploy = frontend_deploy_mode,
		ssr = ssr,
		port = port,
		vite = vite,
		tailwind = tailwind,
		effect = effect,
	}
	if !write_project_files(name, project) {
		fmt.eprintln("Could not finish scaffolding", name)
		return
	}
	if vite {
		packages: [dynamic]string
		append(&packages, "vite")
		if tailwind == "Vite" { append(&packages, "tailwindcss"); append(&packages, "@tailwindcss/vite") }
		if effect do append(&packages, "effect")
		if !npm_packages_at(name, packages[:]) { fmt.println("Install the generated dependencies later with npm install.") }
	}
	fmt.println("Created Patra project:", name)
	fmt.println("Next: cd", name, "&& patra dev")
}

choose_deployment_preference :: proc(reader: ^bufio.Reader, question: string) -> string {
	choice := choose(reader, question, []string{"Use platform CLI when supported", "Manual deployment instructions"})
	if choice == int(Deploy_Choices.Manual) do return "Manual"
	return "CLI"
}

valid_project_name :: proc(name: string) -> bool {
	if name == "" || name == "." || name == ".." do return false
	for c in name {
		if !((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-' || c == '_' || c == '.' || c == ' ') do return false
	}
	return true
}

platform_options :: proc(mode: string) -> []string {
	if mode == "Server" do return SERVER_PLATFORMS[:]
	return EDGE_PLATFORMS[:]
}

runtime_options :: proc(mode, platform: string) -> []string {
	if mode == "Static" do return STATIC_RUNTIME[:]
	if platform == "Cloudflare" do return WORKER_RUNTIME[:]
	if mode == "Serverless" do return FUNCTION_RUNTIMES[:]
	return SERVER_RUNTIMES[:]
}

write_project_files :: proc(root: string, project: Project_Config) -> bool {
	root_config, _ := filepath.join({root, CONFIG_FILE}, context.allocator)
	routes_dir, _ := filepath.join({root, "src", "routes"}, context.allocator)
	if os.make_directory_all(routes_dir) != nil do return false
	config_text := `package config

Architecture :: enum {Full_Stack, Split}
Mode :: enum {Server, Serverless, Static}
Runtime :: enum {Native, Bun, Node, Worker, None}
Platform :: enum {Render, Fly, Vercel, Cloudflare}
Deployment_Method :: enum {CLI, Manual}

Dev_Config :: struct {port: int}
Backend_Config :: struct {mode: Mode, runtime: Runtime, platform: Platform, deployment: Deployment_Method}
Frontend_Config :: struct {mode: Mode, ssr: bool, runtime: Runtime, platform: Platform, deployment: Deployment_Method}

App :: struct {
	name: string,
	architecture: Architecture,
	dev: Dev_Config,
	backend: Backend_Config,
	frontend: Frontend_Config,
	vite: bool,
	tailwind: string,
	effect: bool,
}

app :: App{
	name = "__NAME__",
	architecture = .__ARCHITECTURE__,
	dev = {
		port = __PORT__,
	},
	backend = {
		mode = .__BACKEND_MODE__,
		runtime = .__BACKEND_RUNTIME__,
		platform = .__BACKEND_PLATFORM__,
		deployment = .__BACKEND_DEPLOY__,
	},
	frontend = {
		mode = .__FRONTEND_MODE__,
		ssr = __SSR__,
		runtime = .__FRONTEND_RUNTIME__,
		platform = .__FRONTEND_PLATFORM__,
		deployment = .__FRONTEND_DEPLOY__,
	},
	vite = __VITE__,
	tailwind = "__TAILWIND__",
	effect = __EFFECT__,
}
`
	config_text, _ = strings.replace_all(config_text, "__NAME__", project.name)
	config_text, _ = strings.replace_all(config_text, "__ARCHITECTURE__", project.architecture)
	config_text, _ = strings.replace_all(config_text, "__PORT__", fmt.tprintf("%d", project.port))
	config_text, _ = strings.replace_all(config_text, "__BACKEND_MODE__", project.backend_mode)
	config_text, _ = strings.replace_all(config_text, "__BACKEND_RUNTIME__", project.backend_runtime)
	config_text, _ = strings.replace_all(config_text, "__BACKEND_PLATFORM__", project.backend_platform)
	config_text, _ = strings.replace_all(config_text, "__BACKEND_DEPLOY__", project.backend_deploy)
	config_text, _ = strings.replace_all(config_text, "__FRONTEND_MODE__", project.frontend_mode)
	ssr_text := "false"
	if project.ssr do ssr_text = "true"
	config_text, _ = strings.replace_all(config_text, "__SSR__", ssr_text)
	config_text, _ = strings.replace_all(config_text, "__FRONTEND_RUNTIME__", project.frontend_runtime)
	config_text, _ = strings.replace_all(config_text, "__FRONTEND_PLATFORM__", project.frontend_platform)
	config_text, _ = strings.replace_all(config_text, "__FRONTEND_DEPLOY__", project.frontend_deploy)
	vite_text := "false"
	if project.vite do vite_text = "true"
	config_text, _ = strings.replace_all(config_text, "__VITE__", vite_text)
	config_text, _ = strings.replace_all(config_text, "__TAILWIND__", project.tailwind)
	effect_text := "false"
	if project.effect do effect_text = "true"
	config_text, _ = strings.replace_all(config_text, "__EFFECT__", effect_text)
	tailwind_link := ""
	if project.tailwind != "None" do tailwind_link = `<link rel="stylesheet" href="/assets/patra.css">`
	layout_text := `<!doctype html>
<html lang="en">
	<head>
		<meta charset="utf-8">
		<meta name="viewport" content="width=device-width, initial-scale=1">
		<title>Patra app</title>
		__TAILWIND_LINK__
	</head>
	<body>
		<slot />
	</body>
</html>
`
	layout_text, _ = strings.replace_all(layout_text, "__TAILWIND_LINK__", tailwind_link)
	page_text := `---
title: "Welcome to Patra"
---
<main>
	<h1>Welcome to Patra</h1>
	<p>Your project is ready.</p>
</main>
`
	if os.write_entire_file(root_config, config_text) != nil do return false
	layout_path, _ := filepath.join({routes_dir, "layout.patra"}, context.allocator)
	page_path, _ := filepath.join({routes_dir, "page.patra"}, context.allocator)
	if os.write_entire_file(layout_path, layout_text) != nil do return false
	if os.write_entire_file(page_path, page_text) != nil do return false
	if project.tailwind != "None" {
		css_path, _ := filepath.join({root, "src", "input.css"}, context.allocator)
		if os.write_entire_file(css_path, "@import \"tailwindcss\";\n@source \"./routes\";\n") != nil do return false
	}
	if project.vite {
		package_path, _ := filepath.join({root, "package.json"}, context.allocator)
		if os.write_entire_file(package_path, "{\n  \"private\": true,\n  \"type\": \"module\"\n}\n") != nil do return false
		vite_path, _ := filepath.join({root, "vite.config.ts"}, context.allocator)
		vite_config_builder := strings.builder_make()
		strings.write_string(&vite_config_builder, "import { defineConfig } from 'vite'\n")
		if project.tailwind == "Vite" do strings.write_string(&vite_config_builder, "import tailwindcss from '@tailwindcss/vite'\n")
		strings.write_string(&vite_config_builder, "export default defineConfig({ plugins: [")
		if project.tailwind == "Vite" do strings.write_string(&vite_config_builder, "tailwindcss()")
		strings.write_string(&vite_config_builder, "] })\n")
		vite_config := strings.to_string(vite_config_builder)
		if os.write_entire_file(vite_path, vite_config) != nil do return false
	}
	return true
}

read_project_config :: proc() -> (config: Project_Config, source: string, ok: bool) {
	data, err := os.read_entire_file(CONFIG_FILE, context.allocator)
	if err != nil do return {}, "", false
	source = string(data)
	config = Project_Config{port = 3000}
	section := ""
	for raw_line in strings.split_lines(source) {
		line := strings.trim_space(raw_line)
		if strings.has_prefix(line, "name =") do config.name = quoted_value(line)
		if strings.has_prefix(line, "architecture =") do config.architecture = enum_value(line)
		if strings.has_prefix(line, "vite =") do config.vite = strings.contains(line, "true")
		if strings.has_prefix(line, "tailwind =") do config.tailwind = quoted_value(line)
		if strings.has_prefix(line, "effect =") do config.effect = strings.contains(line, "true")
		if strings.has_prefix(line, "port =") {
			value := after_equal(line)
			parsed, valid := strconv.parse_int(value)
			if valid do config.port = parsed
		}
		if line == "backend = {" { section = "backend"; continue }
		if line == "frontend = {" { section = "frontend"; continue }
		if line == "}," || line == "}" { section = ""; continue }
		if section == "backend" {
			if strings.has_prefix(line, "mode =") do config.backend_mode = enum_value(line)
			if strings.has_prefix(line, "runtime =") do config.backend_runtime = enum_value(line)
			if strings.has_prefix(line, "platform =") do config.backend_platform = enum_value(line)
			if strings.has_prefix(line, "deployment =") do config.backend_deploy = enum_value(line)
		}
		if section == "frontend" {
			if strings.has_prefix(line, "mode =") do config.frontend_mode = enum_value(line)
			if strings.has_prefix(line, "ssr =") do config.ssr = strings.contains(line, "true")
			if strings.has_prefix(line, "runtime =") do config.frontend_runtime = enum_value(line)
			if strings.has_prefix(line, "platform =") do config.frontend_platform = enum_value(line)
			if strings.has_prefix(line, "deployment =") do config.frontend_deploy = enum_value(line)
		}
	}
	return config, source, validate_config(config)
}

after_equal :: proc(line: string) -> string {
	i := strings.index(line, "=")
	if i < 0 do return ""
	value := strings.trim_space(line[i+1:])
	comma := strings.index(value, ",")
	if comma >= 0 do value = value[:comma]
	return strings.trim_space(value)
}

quoted_value :: proc(line: string) -> string {
	i := strings.index(line, "\"")
	if i < 0 do return ""
	end := strings.index(line[i+1:], "\"")
	if end < 0 do return ""
	return line[i+1:i+1+end]
}

enum_value :: proc(line: string) -> string {
	value := after_equal(line)
	if strings.has_prefix(value, ".") do value = value[1:]
	return value
}

validate_config :: proc(config: Project_Config) -> bool {
	if config.name == "" { fmt.eprintln("Config is missing app.name"); return false }
	if config.architecture != "Full_Stack" && config.architecture != "Split" { fmt.eprintln("Config architecture must be Full_Stack or Split"); return false }
	if config.port < 1 || config.port > 65535 { fmt.eprintln("Config dev.port must be between 1 and 65535"); return false }
	if config.backend_mode != "Server" && config.backend_mode != "Serverless" { fmt.eprintln("Config backend.mode is invalid"); return false }
	if config.frontend_mode != "Server" && config.frontend_mode != "Serverless" && config.frontend_mode != "Static" { fmt.eprintln("Config frontend.mode is invalid"); return false }
	if config.frontend_mode == "Static" && config.ssr { fmt.eprintln("Static frontend cannot use SSR"); return false }
	if config.backend_runtime == "" || config.frontend_runtime == "" { fmt.eprintln("Config is missing a runtime"); return false }
	if config.backend_platform == "" || config.frontend_platform == "" { fmt.eprintln("Config is missing a platform"); return false }
	if config.backend_deploy == "" || config.frontend_deploy == "" { fmt.eprintln("Config is missing deployment preferences"); return false }
	if config.architecture == "Full_Stack" && config.backend_platform != config.frontend_platform { fmt.eprintln("Full stack projects must use one deployment platform"); return false }
	if !valid_target(config.backend_mode, config.backend_runtime, config.backend_platform) {
		fmt.eprintln("Backend runtime and platform do not support the selected mode")
		return false
	}
	frontend_target_ok := valid_target(config.frontend_mode, config.frontend_runtime, config.frontend_platform)
	if config.architecture == "Full_Stack" && config.frontend_mode == "Static" && config.frontend_runtime == "None" && (config.frontend_platform == "Render" || config.frontend_platform == "Fly") && config.backend_mode == "Server" {
		frontend_target_ok = true
	}
	if !frontend_target_ok {
		fmt.eprintln("Frontend runtime and platform do not support the selected mode")
		return false
	}
	return true
}

valid_target :: proc(mode, runtime, platform: string) -> bool {
	if mode == "Static" do return runtime == "None" && (platform == "Vercel" || platform == "Cloudflare")
	if mode == "Server" {
		return (platform == "Render" || platform == "Fly") && (runtime == "Native" || runtime == "Bun" || runtime == "Node")
	}
	if mode == "Serverless" {
		return (platform == "Vercel" && (runtime == "Bun" || runtime == "Node")) || (platform == "Cloudflare" && runtime == "Worker")
	}
	return false
}

build_project_cli :: proc() {
	config, source, ok := read_project_config()
	if !ok {
		fmt.eprintln("Missing or invalid", CONFIG_FILE, "in the current folder")
		return
	}
	if !os.is_directory("src/routes") {
		fmt.eprintln("Missing src/routes folder")
		return
	}
	fmt.println("Building", config.name)
	if !patra_compiler.build_project(".", "build") do fmt.eprintln("Patra build failed")
}

setup_project :: proc() {
	if len(os.args) < 3 {
		fmt.println("Usage: patra setup <vite|tailwindcss|effect|remove>")
		return
	}
	option := os.args[2]
	config, source, ok := read_project_config()
	if !ok { fmt.eprintln("Missing or invalid", CONFIG_FILE, "in the current folder"); return }
	old_tailwind := config.tailwind
	if option == "vite" {
		config.vite = true
		if config.tailwind == "CLI" {
			reader: bufio.Reader
			bufio.reader_init(&reader, os.to_stream(os.stdin))
			defer bufio.reader_destroy(&reader)
			if yes_no(&reader, "Migrate Tailwind from CLI to Vite?", true) do config.tailwind = "Vite"
		}
	} else if option == "tailwindcss" {
		if config.vite { config.tailwind = "Vite" } else { config.tailwind = "CLI"; fmt.println("Install the standalone Tailwind CLI: https://tailwindcss.com/docs/installation/tailwind-cli") }
	} else if option == "effect" {
		config.effect = true
		config.vite = true
	} else if option == "remove" {
		if len(os.args) < 4 { fmt.eprintln("Usage: patra setup remove <vite|tailwindcss|effect>"); return }
		remove := os.args[3]
		if remove == "tailwindcss" { config.tailwind = "None" }
		else if remove == "effect" { config.effect = false }
		else if remove == "vite" {
			if config.tailwind == "Vite" {
				reader: bufio.Reader
				bufio.reader_init(&reader, os.to_stream(os.stdin))
				defer bufio.reader_destroy(&reader)
				choice := choose(&reader, "Tailwind currently uses Vite", []string{"Move Tailwind to standalone CLI", "Remove Tailwind integration", "Cancel"}, 0)
				if choice == 0 { config.tailwind = "CLI" }
				else if choice == 1 { config.tailwind = "None" }
				else { return }
			}
			config.vite = false
		} else { fmt.eprintln("Unknown integration:", remove); return }
	} else { fmt.eprintln("Unknown setup option:", option); return }
	updated := update_tooling_config(source, config)
	if os.write_entire_file(CONFIG_FILE, updated) != nil { fmt.eprintln("Could not update", CONFIG_FILE); return }
	setup_generated_files(config)
	sync_generated_vite_config(config)
	if config.vite { _ = npm_packages({"vite"}) }
	if config.tailwind == "Vite" { _ = npm_packages({"tailwindcss", "@tailwindcss/vite"}) }
	if config.effect { _ = npm_packages({"effect"}) }
	if option == "remove" && os.args[3] == "vite" && !os.exists("vite.config.ts") { _ = npm_remove({"vite"}) }
	if option == "remove" && os.args[3] == "tailwindcss" && old_tailwind == "Vite" && !vite_config_uses_tailwind() { _ = npm_remove({"tailwindcss", "@tailwindcss/vite"}) }
	if option == "remove" && os.args[3] == "vite" && old_tailwind == "Vite" && config.tailwind == "CLI" && !vite_config_uses_tailwind() { _ = npm_remove({"tailwindcss", "@tailwindcss/vite"}) }
	if option == "remove" && os.args[3] == "effect" { _ = npm_remove({"effect"}) }
	if config.tailwind == "None" {
		layout, exists := read_cli_text("src/routes/layout.patra")
		if exists { layout, _ = strings.replace_all(layout, "<link rel=\"stylesheet\" href=\"/assets/patra.css\">", ""); _ = os.write_entire_file("src/routes/layout.patra", layout) }
		css, css_exists := read_cli_text("src/input.css")
		if css_exists && strings.trim_space(css) == "@import \"tailwindcss\";\n@source \"./routes\";" { _ = os.remove("src/input.css") }
	} else if config.tailwind != "" {
		if !os.exists("src/input.css") { _ = os.write_entire_file("src/input.css", "@import \"tailwindcss\";\n@source \"./routes\";\n") }
		layout, exists := read_cli_text("src/routes/layout.patra")
		if exists && !strings.contains(layout, "patra.css") { layout, _ = strings.replace_all(layout, "<title>", "<link rel=\"stylesheet\" href=\"/assets/patra.css\">\n\t\t<title>"); _ = os.write_entire_file("src/routes/layout.patra", layout) }
	}
	fmt.println("Updated setup. Existing page classes and source files are preserved.")
}

remove_generated_vite_config :: proc() {
	content, exists := read_cli_text("vite.config.ts")
	if !exists do return
	plain := "import { defineConfig } from 'vite'\nexport default defineConfig({ plugins: [] })"
	with_tailwind := "import { defineConfig } from 'vite'\nimport tailwindcss from '@tailwindcss/vite'\nexport default defineConfig({ plugins: [tailwindcss()] })"
	trimmed := strings.trim_space(content)
	if trimmed == plain || trimmed == with_tailwind { _ = os.remove("vite.config.ts") }
}

vite_config_uses_tailwind :: proc() -> bool {
	content, exists := read_cli_text("vite.config.ts")
	return exists && strings.contains(content, "@tailwindcss/vite")
}

sync_generated_vite_config :: proc(config: Project_Config) {
	content, exists := read_cli_text("vite.config.ts")
	if !exists do return
	plain := "import { defineConfig } from 'vite'\nexport default defineConfig({ plugins: [] })"
	with_tailwind := "import { defineConfig } from 'vite'\nimport tailwindcss from '@tailwindcss/vite'\nexport default defineConfig({ plugins: [tailwindcss()] })"
	trimmed := strings.trim_space(content)
	if trimmed != plain && trimmed != with_tailwind do return
	if !config.vite { _ = os.remove("vite.config.ts"); return }
	desired := plain
	if config.tailwind == "Vite" do desired = with_tailwind
	if desired != trimmed {
		updated, _ := strings.concatenate({desired, "\n"})
		_ = os.write_entire_file("vite.config.ts", updated)
	}
}

setup_generated_files :: proc(config: Project_Config) {
	if config.tailwind != "None" {
		if !os.exists("src/input.css") { _ = os.write_entire_file("src/input.css", "@import \"tailwindcss\";\n@source \"./routes\";\n") }
		layout, exists := read_cli_text("src/routes/layout.patra")
		if exists && !strings.contains(layout, "patra.css") {
			layout, _ = strings.replace_all(layout, "<title>", "<link rel=\"stylesheet\" href=\"/assets/patra.css\">\n\t\t<title>")
			_ = os.write_entire_file("src/routes/layout.patra", layout)
		}
	}
	if config.vite && !os.exists("vite.config.ts") {
		builder := strings.builder_make()
		strings.write_string(&builder, "import { defineConfig } from 'vite'\n")
		if config.tailwind == "Vite" do strings.write_string(&builder, "import tailwindcss from '@tailwindcss/vite'\n")
		strings.write_string(&builder, "export default defineConfig({ plugins: [")
		if config.tailwind == "Vite" do strings.write_string(&builder, "tailwindcss()")
		strings.write_string(&builder, "] })\n")
		_ = os.write_entire_file("vite.config.ts", strings.to_string(builder))
	}
}

npm_packages :: proc(packages: []string) -> bool {
	return npm_packages_at(".", packages)
}

npm_packages_at :: proc(working_dir: string, packages: []string) -> bool {
	command: [dynamic]string
	append(&command, "npm"); append(&command, "install"); append(&command, "--save-dev")
	for package_name in packages do append(&command, package_name)
	state, stdout, stderr, process_err := os.process_exec({command=command[:], working_dir=working_dir}, context.allocator)
	if process_err != nil || state.exit_code != 0 {
		fmt.eprintln("Could not install npm dependencies. Run:", strings.join(command[1:], " "))
		fmt.println(string(stderr)); fmt.println(string(stdout)); return false
	}
	return true
}

npm_remove :: proc(packages: []string) -> bool {
	command: [dynamic]string
	append(&command, "npm"); append(&command, "uninstall")
	for package_name in packages do append(&command, package_name)
	state, stdout, stderr, process_err := os.process_exec({command=command[:], working_dir="."}, context.allocator)
	if process_err != nil || state.exit_code != 0 {
		fmt.eprintln("Could not remove npm dependencies; you can run:", strings.join(command[1:], " "))
		fmt.println(string(stderr)); fmt.println(string(stdout)); return false
	}
	return true
}

update_tooling_config :: proc(source: string, config: Project_Config) -> string {
	updated := source
	if !strings.contains(updated, "vite: bool") {
		updated, _ = strings.replace_all(updated, "\tfrontend: Frontend_Config,\n}", "\tfrontend: Frontend_Config,\n\tvite: bool,\n\ttailwind: string,\n\teffect: bool,\n}")
	}
	if !strings.contains(updated, "vite = ") {
		end := strings.last_index(updated, "}\n")
		if end >= 0 {
			vite := "false"; if config.vite do vite = "true"
			effect := "false"; if config.effect do effect = "true"
			tailwind := config.tailwind; if tailwind == "" do tailwind = "None"
			addition := fmt.tprintf("\tvite = %s,\n\ttailwind = \"%s\",\n\teffect = %s,\n", vite, tailwind, effect)
			updated, _ = strings.concatenate({updated[:end], addition, updated[end:]})
		}
	} else {
		vite := "false"; if config.vite do vite = "true"
		effect := "false"; if config.effect do effect = "true"
		updated, _ = strings.replace_all(updated, "vite = false", fmt.tprintf("vite = %s", vite))
		updated, _ = strings.replace_all(updated, "vite = true", fmt.tprintf("vite = %s", vite))
		updated, _ = strings.replace_all(updated, "effect = false", fmt.tprintf("effect = %s", effect))
		updated, _ = strings.replace_all(updated, "effect = true", fmt.tprintf("effect = %s", effect))
	}
	tailwind := config.tailwind; if tailwind == "" do tailwind = "None"
	updated, _ = strings.replace_all(updated, "tailwind = \"CLI\"", fmt.tprintf("tailwind = \"%s\"", tailwind))
	updated, _ = strings.replace_all(updated, "tailwind = \"Vite\"", fmt.tprintf("tailwind = \"%s\"", tailwind))
	updated, _ = strings.replace_all(updated, "tailwind = \"None\"", fmt.tprintf("tailwind = \"%s\"", tailwind))
	return updated
}

dev_project :: proc() {
	config, _, ok := read_project_config()
	if !ok {
		fmt.eprintln("Missing or invalid", CONFIG_FILE, "in the current folder")
		return
	}
	if !os.is_directory("src/routes") {
		fmt.eprintln("Missing src/routes folder")
		return
	}
	dev_server(config)
}

dev_server :: proc(config: Project_Config) {
	listener, listen_err := net.listen_tcp({net.IP4_Loopback, config.port})
	if listen_err != nil {
		fmt.eprintln("Could not start development server:", listen_err)
		return
	}
	defer net.close(net.Any_Socket(listener))
	fmt.printf("Patra dev server: http://127.0.0.1:%d\n", config.port)
	fmt.println("Watching routes, tooling config, and selected CSS/Vite inputs; press Ctrl-C to stop.")
	for {
		client, _, accept_err := net.accept_tcp(listener)
		if accept_err != .None do continue
		serve_dev_request(client, config)
		net.close(net.Any_Socket(client))
	}
}

serve_dev_request :: proc(client: net.TCP_Socket, config: Project_Config) {
	if config.vite {
		revision := dev_revision()
		if revision != dev_build_revision {
			if patra_compiler.build_project(".", "build") do dev_build_revision = revision
		}
	}
	if config.tailwind == "CLI" {
		revision := dev_revision()
		if revision != dev_tailwind_revision {
			if compile_tailwind_dev() do dev_tailwind_revision = revision
		}
	}
	request_buffer: [8192]u8
	read, recv_err := net.recv_tcp(client, request_buffer[:])
	if recv_err != .None || read <= 0 do return
	request := string(request_buffer[:read])
	line_end := strings.index(request, "\r\n")
	if line_end < 0 do return
	line := request[:line_end]
	path_start := strings.index(line, " ")
	if path_start < 0 do return
	remaining := line[path_start+1:]
	path_end := strings.index(remaining, " ")
	if path_end < 0 do return
	path := remaining[:path_end]
	status := "200 OK"
	body := ""
	content_type := "text/html; charset=utf-8"
	if path == "/__patra/revision" {
		content_type = "text/plain"
		body = dev_revision()
	} else if path == "/assets/patra.css" && config.tailwind == "CLI" {
		content_type = "text/css; charset=utf-8"
		css, exists := read_cli_text("build/assets/patra.css")
		body = css
		if !exists { status = "503 Service Unavailable"; body = "Tailwind CSS is not ready" }
	} else if config.vite {
		file := path
		if file == "/" do file = "/index.html"
		if !strings.has_prefix(file, "/assets/") && !strings.contains(filepath.base(file), ".") && !strings.has_suffix(file, "/") { file, _ = strings.concatenate({file, "/"}) }
		if strings.has_suffix(file, "/") { file, _ = strings.concatenate({file, "index.html"}) }
		if strings.contains(file, "..") { status = "400 Bad Request"; body = "Bad path" }
		else {
			file_path, _ := strings.concatenate({"build", file})
			body, exists := read_cli_text(file_path)
			if !exists { status = "404 Not Found"; body = "Not found" }
			else if strings.has_suffix(file, ".css") { content_type = "text/css; charset=utf-8" }
			else if strings.has_suffix(file, ".js") { content_type = "text/javascript; charset=utf-8" }
			else if strings.has_suffix(file, ".wasm") { content_type = "application/wasm" }
			else if strings.has_suffix(file, ".html") {
				body, _ = strings.replace_all(body, "</body>", "<script>(()=>{let v='';setInterval(async()=>{try{const n=await(await fetch('/__patra/revision',{cache:'no-store'})).text();if(v&&v!==n)location.reload();v=n}catch{}},700)})()</script></body>")
			}
		}
	} else {
		route_file, param_name, param_value, route_found := dev_route_file(path)
		if route_found {
			body = render_dev_page(config, route_file, param_name, param_value)
			if body == "" { status = "500 Internal Server Error"; body = fmt.tprintf("Could not render %s", route_file) }
		} else {
			status = "404 Not Found"
			body = "Not found"
		}
	}
	response := fmt.tprintf("HTTP/1.1 %s\r\nContent-Type: %s\r\nContent-Length: %d\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n%s", status, content_type, len(body), body)
	_, _ = net.send_tcp(client, transmute([]u8)response)
}

compile_tailwind_dev :: proc() -> bool {
	if !os.is_directory("build/assets") {
		if os.make_directory_all("build/assets") != nil do return false
	}
	command := []string{"tailwindcss", "-i", "src/input.css", "-o", "build/assets/patra.css"}
	state, stdout, stderr, process_err := os.process_exec({command=command, working_dir="."}, context.allocator)
	if process_err != nil || state.exit_code != 0 {
		fmt.eprintln("Tailwind CLI is missing or failed. Install the standalone CLI: https://tailwindcss.com/docs/installation/tailwind-cli")
		fmt.println(string(stderr)); fmt.println(string(stdout)); return false
	}
	return true
}

dev_route_file :: proc(request_path: string) -> (string, param_name, param_value: string, found: bool) {
	route := request_path
	query := strings.index(route, "?")
	if query >= 0 do route = route[:query]
	if route == "/" || route == "/index.html" do return "src/routes/page.patra", "", "", os.exists("src/routes/page.patra")
	if !strings.has_prefix(route, "/") || strings.contains(route, "..") || strings.contains(route, "\\") do return "", "", "", false
	relative := route[1:]
	if strings.has_suffix(relative, "/") do relative = relative[:len(relative)-1]
	if relative == "" do return "src/routes/page.patra", "", "", os.exists("src/routes/page.patra")
	folder_page, _ := filepath.join({"src/routes", relative, "page.patra"}, context.temp_allocator)
	if os.exists(folder_page) do return folder_page, "", "", true
	flat_name, _ := strings.concatenate({relative, ".patra"})
	flat_page, _ := filepath.join({"src/routes", flat_name}, context.temp_allocator)
	if os.exists(flat_page) do return flat_page, "", "", true
	if !strings.contains(relative, "/") {
		entries, err := os.read_all_directory_by_path("src/routes", context.temp_allocator)
		if err == nil {
			for entry in entries {
				if entry.type != .Directory || len(entry.name) < 3 || entry.name[0] != '[' || entry.name[len(entry.name)-1] != ']' do continue
				dynamic_page, _ := filepath.join({"src/routes", entry.name, "page.patra"}, context.temp_allocator)
				if os.exists(dynamic_page) do return dynamic_page, entry.name[1:len(entry.name)-1], relative, true
			}
		}
	}
	return "", "", "", false
}

render_dev_page :: proc(config: Project_Config, page_path, param_name, param_value: string) -> string {
	page_source, page_ok := read_cli_text(page_path)
	if !page_ok do return ""
	route, _, parsed := patra_compiler.parse_document(page_path, page_source)
	if !parsed do return ""
	if !patra_compiler.apply_layouts("src/routes", page_path, &route) do return ""
	values: [dynamic]patra_compiler.Value
	for value in route.data do append(&values, value)
	if param_name != "" do append(&values, patra_compiler.Value{name=param_name, value=param_value})
	patra_compiler.parse_script_values(route.script, &values)
	layout := patra_compiler.render_markup(route.markup, values[:])
	title := route.title
	if title == "" do title = config.name
	title_tag := fmt.tprintf("<title>%s</title>", patra_compiler.escape_html(title))
	if strings.contains(layout, "<title>") {
		start := strings.index(layout, "<title>")
		end := strings.index(layout[start:], "</title>")
		if end >= 0 {
			end += start + len("</title>")
			layout, _ = strings.concatenate({layout[:start], title_tag, layout[end:]})
		}
	} else {
		head_end := strings.index(layout, "</head>")
		if head_end >= 0 do layout = fmt.tprintf("%s%s%s", layout[:head_end], title_tag, layout[head_end:])
	}
	if !strings.contains(layout, "property=\"og:title\"") {
		seo := patra_compiler.seo_tags(route, title)
		head_end := strings.index(layout, "</head>")
		if head_end >= 0 do layout = fmt.tprintf("%s%s%s", layout[:head_end], seo, layout[head_end:])
	}
	if config.tailwind != "None" {
		stylesheet_link := `<link rel="stylesheet" href="/assets/patra.css">`
		if !strings.contains(layout, "patra.css") {
			head_end := strings.index(layout, "</head>")
			if head_end >= 0 {
				layout = fmt.tprintf("%s%s%s", layout[:head_end], stylesheet_link, layout[head_end:])
			} else {
				layout, _ = strings.concatenate({stylesheet_link, layout})
			}
		}
	}
	if strings.trim_space(route.script) != "" {
		inline_script := fmt.tprintf(`<script type="module">%s</script>`, strings.replace_all(route.script, "</script", "<\\/script"))
		body_end := strings.index(layout, "</body>")
		if body_end >= 0 { layout = fmt.tprintf("%s%s%s", layout[:body_end], inline_script, layout[body_end:]) }
		else { layout, _ = strings.concatenate({layout, inline_script}) }
	}
	live_reload := "<script>(()=>{let v=\"\";setInterval(async()=>{try{const n=await(await fetch('/__patra/revision',{cache:'no-store'})).text();if(v&&v!==n)location.reload();v=n}catch{}},700)})()</script>"
	reload_at := strings.index(layout, "</body>")
	if reload_at >= 0 {
		layout = fmt.tprintf("%s%s%s", layout[:reload_at], live_reload, layout[reload_at:])
	} else {
		layout, _ = strings.concatenate({layout, live_reload})
	}
	return layout
}

dev_revision :: proc() -> string {
	config, _ := read_cli_text(CONFIG_FILE)
	sum: u64
	for c in config do sum += u64(c)
	sum = revision_directory("src/routes", sum)
	watched_files := [3]string{"src/input.css", "package.json", "vite.config.ts"}
	for path in watched_files {
		contents, exists := read_cli_text(path)
		if exists {
			for c in contents do sum += u64(c)
			sum += u64(len(contents))
		}
	}
	return fmt.tprintf("%d-%d", sum, len(config))
}

revision_directory :: proc(path: string, initial: u64) -> u64 {
	sum := initial
	entries, err := os.read_all_directory_by_path(path, context.temp_allocator)
	if err != nil do return sum
	for entry in entries {
		entry_path, _ := filepath.join({path, entry.name}, context.temp_allocator)
		if entry.type == .Directory {
			sum = revision_directory(entry_path, sum)
		} else if filepath.ext(entry_path) == ".patra" {
			contents, _ := read_cli_text(entry_path)
			for c in contents do sum += u64(c)
			sum += u64(len(contents))
		}
	}
	return sum
}

read_cli_text :: proc(path: string) -> (string, bool) {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil do return "", false
	return string(data), true
}

deploy_project_cli :: proc() {
	config, _, ok := read_project_config()
	if !ok {
		fmt.eprintln("Missing or invalid", CONFIG_FILE, "in the current folder")
		return
	}
	fmt.println("Preparing deployment build for", config.name)
	if !patra_compiler.build_project(".", "build") {
		fmt.eprintln("Build failed; deployment instructions were not generated.")
		return
	}
	fmt.println("Deployment instructions for", config.name)
	print_deploy_instructions("backend", config.backend_mode, config.backend_runtime, config.backend_platform, config.backend_deploy)
	if config.architecture == "Split" {
		print_deploy_instructions("frontend", config.frontend_mode, config.frontend_runtime, config.frontend_platform, config.frontend_deploy)
	} else {
		fmt.println("Frontend is included in the backend deployment.")
	}
	fmt.println("Build artifacts are in ./build.")
	if config.backend_deploy == "CLI" || config.frontend_deploy == "CLI" {
		fmt.println("The build is ready in ./build. Patra does not invoke platform deploy commands yet; use the platform CLI with these artifacts.")
	}
}

print_deploy_instructions :: proc(component, mode, runtime, platform, preference: string) {
	fmt.printf("\n%s: %s / %s on %s\n", component, mode, runtime, platform)
	if preference == "Manual" do fmt.println("Preference: manual")
	if mode == "Static" {
		fmt.println("Deploy the generated static output directory using the platform dashboard or its CLI.")
		return
	}
	if mode == "Server" {
		if runtime == "Node" {
			fmt.println("Run node server.mjs from ./build as a long-running service.")
		} else if runtime == "Bun" {
			fmt.println("Run bun server.mjs from ./build as a long-running service.")
		} else {
			fmt.println("Compile the generated server entrypoint for the selected native runtime.")
		}
		return
	}
	if runtime == "Worker" {
		fmt.println("Deploy the generated Worker entrypoint and WebAssembly module with Wrangler.")
	} else if platform == "Vercel" {
		fmt.println("Deploy the generated function wrapper and WebAssembly module with the Vercel CLI or dashboard.")
	} else {
		fmt.println("Deploy the generated serverless wrapper and WebAssembly module with the platform CLI or dashboard.")
	}
}
