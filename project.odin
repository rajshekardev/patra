package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:unicode/utf8"

PLATFORMS :: [?]struct { label, id: string } {
	{"Android", "android"},
	{"iOS", "ios"},
	{"Windows", "windows"},
	{"Linux", "linux"},
	{"macOS", "macos"},
	{"Server", "server"},
	{"Website", "website"},
}

Project_Config :: struct {
	name:      string,
	platforms: []string,
}

Platform_Key :: enum {
	Up,
	Down,
	Toggle,
	Confirm,
	Cancel,
	Error,
}

new_project :: proc() -> int {
	if !has_project_terminal() {
		fmt.eprintln("patra: --new requires an interactive terminal")
		return 1
	}
	context.allocator = context.temp_allocator

	name: string
	for {
		fmt.print("Project name: ")
		read_name, complete := read_project_name()
		if !complete {
			fmt.eprintln("\npatra: project creation cancelled")
			return 130
		}
		if valid_project_name(read_name) {
			name = read_name
			break
		}
		fmt.eprintln("patra: enter a name that can be used as a single directory on Linux, macOS, and Windows")
	}

	platforms, status := choose_platforms()
	if status != 0 {
		return status
	}
	data, json_err := json.marshal(
		Project_Config{name, platforms},
		{pretty = true, use_spaces = true, spaces = 2},
	)
	if json_err != nil {
		fmt.eprintf("patra: cannot encode project configuration: %v\n", json_err)
		return 1
	}

	config_path, path_err := filepath.join({name, "config.json"})
	if path_err != nil {
		fmt.eprintf("patra: cannot construct the configuration path: %v\n", path_err)
		return 1
	}
	if err := os.make_directory(name); err != nil {
		fmt.eprintf("patra: cannot create project directory %q: %s\n", name, os.error_string(err))
		return 1
	}
	if !write_new_file(config_path, fmt.tprintf("%s\n", string(data))) {
		os.remove(name)
		return 1
	}
	fmt.println("Created", config_path)
	return 0
}

valid_project_name :: proc(name: string) -> bool {
	if strings.trim_space(name) == "" || len(name) > 255 || !utf8.valid_string(name) {
		return false
	}
	if strings.has_suffix(name, ".") || strings.has_suffix(name, " ") {
		return false
	}
	for character in name {
		if character < 32 || character == 127 || strings.contains_rune(`<>:"/\|?*`, character) {
			return false
		}
	}
	// Check the basename too, since Windows reserves device names with extensions.
	base, _, _ := strings.partition(name, ".")
	base = strings.to_upper(strings.trim_right_space(base))
	switch base {
	case "CON", "PRN", "AUX", "NUL", "CONIN$", "CONOUT$":
		return false
	}
	if strings.has_prefix(base, "COM") || strings.has_prefix(base, "LPT") {
		switch base[3:] {
		case "1", "2", "3", "4", "5", "6", "7", "8", "9", "¹", "²", "³":
			return false
		}
	}
	return true
}

choose_platforms :: proc() -> ([]string, int) {
	input: Platform_Input
	if !begin_platform_input(&input) {
		fmt.eprintln("patra: cannot start the interactive platform selector")
		return nil, 1
	}
	defer restore_platform_input(&input)

	fmt.println("Select platforms")
	fmt.println("Up/Down move, Space toggles, Enter confirms")
	cursor := 0
	selected: [len(PLATFORMS)]bool
	show_error := false
	redraw := false

	for {
		if !draw_platforms(selected, cursor, show_error, redraw) {
			fmt.eprintln("patra: cannot display the platform selector")
			return nil, 1
		}
		redraw = true
		switch read_platform_key(&input) {
		case .Up:
			cursor = (cursor + len(PLATFORMS) - 1) % len(PLATFORMS)
		case .Down:
			cursor = (cursor + 1) % len(PLATFORMS)
		case .Toggle:
			selected[cursor] = !selected[cursor]
			show_error = false
		case .Confirm:
			platforms: [dynamic]string
			for platform, i in PLATFORMS {
				if selected[i] {
					append(&platforms, platform.id)
				}
			}
			if len(platforms) > 0 {
				return platforms[:], 0
			}
			show_error = true
		case .Cancel:
			fmt.eprintln("patra: project creation cancelled")
			return nil, 130
		case .Error:
			fmt.eprintln("patra: cannot read platform selection")
			return nil, 1
		}
	}
}

draw_platforms :: proc(
	selected: [len(PLATFORMS)]bool, cursor: int, show_error, redraw: bool,
) -> bool {
	buffer: [256]byte
	frame := strings.builder_from_bytes(buffer[:])
	if redraw {
		fmt.sbprintf(&frame, "\x1b[%dA", len(PLATFORMS) + 1)
	}
	for platform, i in PLATFORMS {
		pointer := ">" if cursor == i else " "
		mark := "x" if selected[i] else " "
		fmt.sbprintf(&frame, "\r\x1b[K%s [%s] %s\r\n", pointer, mark, platform.label)
	}
	strings.write_string(&frame, "\r\x1b[K")
	if show_error {
		strings.write_string(&frame, "Select at least one platform.")
	}
	strings.write_string(&frame, "\r\n")
	output := strings.to_string(frame)
	written, err := os.write_string(os.stdout, output)
	return err == nil && written == len(output)
}
