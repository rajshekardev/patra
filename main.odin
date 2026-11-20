package main

import "core:encoding/base64"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:unicode/utf16"
import "core:unicode/utf8"

CONFIG_PATH :: "run.patra"
STARTER_CONFIG :: "help:\n    echo 'patra help'\n"
VERSION :: #load("VERSION", string)
HELP :: `patra - Odin-based task runner
Usage: patra <task> [subtask ...]

Built-in commands
  --help      Show this help
  --init      Create a starter run.patra
  --version   Show the Patra version
  --new       Create a project configuration
  --update    Install the latest Patra release
`

Task :: struct {
	name:     string,
	children: []Task,
	script:   string,
}

Parser :: struct {
	lines: []string,
	next:  int,
}

main :: proc() {
	os.exit(run(os.args[1:]))
}

run :: proc(path: []string) -> int {
	if len(path) == 0 {
		fmt.print(HELP)
		return 0
	}

	if strings.has_prefix(path[0], "--") {
		return run_builtin(path)
	}

	context.allocator = context.temp_allocator
	config, read_err := os.read_entire_file(CONFIG_PATH, context.allocator)
	if read_err != nil {
		fmt.eprintf("patra: cannot read %s: %v\n", CONFIG_PATH, read_err)
		return 1
	}

	parser := Parser{lines = strings.split_lines(string(config))}
	for line, index in parser.lines {
		if strings.index_byte(line, 0) >= 0 {
			config_error(index + 1, "unexpected NUL byte")
			return 1
		}
	}
	tasks, parsed := parse_tasks(&parser, 0)
	if !parsed {
		return 1
	}
	if len(tasks) == 0 {
		config_error(1, "expected at least one task")
		return 1
	}
	task := resolve_task(tasks, path)
	if task == nil {
		return 1
	}

	return run_script(task.script)
}

run_builtin :: proc(path: []string) -> int {
	if len(path) != 1 {
		fmt.eprintln("patra: built-in commands take no arguments. See patra --help.")
		return 2
	}
	switch path[0] {
	case "--help":
		fmt.print(HELP)
		return 0
	case "--init":
		return init_task_file()
	case "--version":
		fmt.println("patra", patra_version())
		return 0
	case "--new":
		return new_project()
	case "--update":
		return update_patra()
	case:
		fmt.eprintf("patra: unknown built-in command %q. See patra --help.\n", path[0])
		return 2
	}
}

patra_version :: proc() -> string {
	return strings.trim_space(VERSION)
}

init_task_file :: proc() -> int {
	if !write_new_file(CONFIG_PATH, STARTER_CONFIG) {
		return 1
	}
	fmt.println("Created", CONFIG_PATH)
	return 0
}

write_new_file :: proc(path, contents: string) -> bool {
	file, err := os.open(path, {.Write, .Create, .Excl}, os.Permissions_Default_File)
	if err != nil {
		fmt.eprintf("patra: cannot create %s: %s\n", path, os.error_string(err))
		return false
	}

	written, write_err := os.write_string(file, contents)
	close_err := os.close(file)
	if write_err == nil && written != len(contents) {
		write_err = .Short_Write
	}
	if write_err == nil {
		write_err = close_err
	}
	if write_err != nil {
		os.remove(path)
		fmt.eprintf("patra: cannot write %s: %s\n", path, os.error_string(write_err))
		return false
	}
	return true
}

parse_tasks :: proc(parser: ^Parser, indent: int) -> ([]Task, bool) {
	tasks: [dynamic]Task
	for skip_blank_lines(parser) {
		line := parser.lines[parser.next]
		line_indent := count_indent(line)
		if line_indent < indent {
			break
		}
		if line_indent != indent {
			return nil, config_error(parser.next + 1, "unexpected indentation")
		}

		name := header_name(line[indent:])
		if name == "" {
			return nil, config_error(parser.next + 1, "expected a task header such as 'dev:'")
		}
		for task in tasks {
			if task.name == name {
				return nil, config_error(parser.next + 1, fmt.tprintf("duplicate task %q", name))
			}
		}

		header_line := parser.next + 1
		parser.next += 1
		if !skip_blank_lines(parser) {
			return nil, config_error(header_line, "expected an indented task body")
		}
		body := parser.lines[parser.next]
		body_indent := count_indent(body)
		if body_indent <= indent {
			return nil, config_error(header_line, "expected an indented task body")
		}
		if body[body_indent] == '\t' {
			return nil, config_error(parser.next + 1, "use spaces for task indentation")
		}

		task := Task{name = name}
		ok: bool
		if header_name(body[body_indent:]) != "" {
			task.children, ok = parse_tasks(parser, body_indent)
		} else {
			task.script, ok = parse_script(parser, body_indent)
		}
		if !ok {
			return nil, false
		}
		append(&tasks, task)
	}
	return tasks[:], true
}

parse_script :: proc(parser: ^Parser, indent: int) -> (string, bool) {
	script := strings.builder_make()
	for parser.next < len(parser.lines) {
		line := parser.lines[parser.next]
		line_indent := count_indent(line)
		if strings.trim_space(line) != "" {
			if line_indent < indent {
				break
			}
			if line_indent == indent && header_name(line[indent:]) != "" {
				return "", config_error(parser.next + 1, "cannot mix commands and subtasks in one block")
			}
		}
		strings.write_string(&script, line[min(line_indent, indent):])
		strings.write_byte(&script, '\n')
		parser.next += 1
	}
	return strings.to_string(script), true
}

skip_blank_lines :: proc(parser: ^Parser) -> bool {
	for parser.next < len(parser.lines) {
		if strings.trim_space(parser.lines[parser.next]) != "" {
			return true
		}
		parser.next += 1
	}
	return false
}

count_indent :: proc(line: string) -> int {
	indent := 0
	for indent < len(line) && line[indent] == ' ' {
		indent += 1
	}
	return indent
}

header_name :: proc(line: string) -> string {
	line := strings.trim_right_space(line)
	if len(line) < 2 || line[len(line) - 1] != ':' {
		return ""
	}
	name := line[:len(line) - 1]
	for character in name {
		switch character {
		case 'a'..='z', 'A'..='Z', '0'..='9', '_', '-', '.':
		case:
			return ""
		}
	}
	return name
}

config_error :: proc(line: int, message: string) -> bool {
	fmt.eprintf("patra: %s:%d: %s\n", CONFIG_PATH, line, message)
	return false
}

resolve_task :: proc(root: []Task, path: []string) -> ^Task {
	tasks := root
	for name, index in path {
		found: ^Task
		for &task in tasks {
			if task.name == name {
				found = &task
				break
			}
		}
		if found == nil {
			fmt.eprintf("patra: unknown task %q\n", strings.join(path[:index + 1], " "))
			return nil
		}

		last := index == len(path) - 1
		if len(found.children) == 0 {
			if last {
				return found
			}
			fmt.eprintf("patra: task %q has no subtasks\n", strings.join(path[:index + 1], " "))
			return nil
		}
		tasks = found.children
		if last {
			fmt.eprintf("patra: %q is a task group. Available subtasks:", strings.join(path, " "))
			for task in tasks {
				fmt.eprintf(" %s", task.name)
			}
			fmt.eprintln()
			return nil
		}
	}
	return nil
}

run_script :: proc(script: string) -> int {
	command: []string
	when ODIN_OS == .Windows {
		// PowerShell expects UTF-16LE for -EncodedCommand.
		source := strings.join({
			"$ErrorActionPreference = 'Stop'",
			script,
			"if (-not $?) { if ($LASTEXITCODE) { exit $LASTEXITCODE }; exit 1 }",
		}, "\n")
		if !utf8.valid_string(source) {
			fmt.eprintln("patra: task script is not valid UTF-8")
			return 1
		}
		wide := make([]u16, len(source))
		length := utf16.encode_string(wide, source)
		encoded := base64.encode(mem.slice_to_bytes(wide[:length]))
		command = {"powershell.exe", "-NoLogo", "-NoProfile", "-EncodedCommand", encoded}
	} else {
		command = {"/bin/sh", "-e", "-c", script}
	}

	process, start_err := os.process_start({
		command = command,
		stdin   = os.stdin,
		stdout  = os.stdout,
		stderr  = os.stderr,
	})
	if start_err != nil {
		fmt.eprintf("patra: cannot start %s: %v\n", command[0], start_err)
		return 1
	}
	state, wait_err := os.process_wait(process)
	if wait_err != nil {
		fmt.eprintf("patra: cannot wait for %s: %v\n", command[0], wait_err)
		return 1
	}
	return state.exit_code
}
