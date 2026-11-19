package main

import "core:fmt"
import "core:os"
import "core:strings"

CONFIG_PATH :: "run.patra"
STARTER_CONFIG :: "help:\n    printf '%s\\n' 'patra help'\n"

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
		fmt.println("patra - Odin-based task runner")
		fmt.println("Usage: patra <task> [subtask ...]")
		fmt.println("       patra setup")
		return 0
	}
	if len(path) == 1 && path[0] == "setup" {
		return setup()
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

setup :: proc() -> int {
	file, err := os.open(CONFIG_PATH, {.Write, .Create, .Excl}, os.Permissions_Default_File)
	if err != nil {
		fmt.eprintf("patra: cannot create %s: %s\n", CONFIG_PATH, os.error_string(err))
		return 1
	}

	written, write_err := os.write_string(file, STARTER_CONFIG)
	close_err := os.close(file)
	if write_err == nil && written != len(STARTER_CONFIG) {
		write_err = .Short_Write
	}
	if write_err == nil {
		write_err = close_err
	}
	if write_err != nil {
		os.remove(CONFIG_PATH)
		fmt.eprintf("patra: cannot write %s: %s\n", CONFIG_PATH, os.error_string(write_err))
		return 1
	}

	fmt.println("Created", CONFIG_PATH)
	return 0
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
	process, start_err := os.process_start({
		command = {"/bin/sh", "-e", "-c", script},
		stdin   = os.stdin,
		stdout  = os.stdout,
		stderr  = os.stderr,
	})
	if start_err != nil {
		fmt.eprintf("patra: cannot start /bin/sh: %v\n", start_err)
		return 1
	}
	state, wait_err := os.process_wait(process)
	if wait_err != nil {
		fmt.eprintf("patra: cannot wait for /bin/sh: %v\n", wait_err)
		return 1
	}
	return state.exit_code
}
