#+build linux, darwin
package main

import "core:os"
import "core:strings"
import "core:sys/posix"

Platform_Input :: struct {
	original: posix.termios,
}

has_project_terminal :: proc() -> bool {
	return os.is_tty(os.stdin) && os.is_tty(os.stdout)
}

read_project_name :: proc() -> (string, bool) {
	// A canonical terminal returns at most one line per read.
	buffer: [4096]byte
	n, err := os.read(os.stdin, buffer[:])
	if err != nil || n == 0 {
		return "", false
	}
	line := string(buffer[:n])
	if !strings.has_suffix(line, "\n") {
		return "", false
	}
	return strings.clone(line[:len(line) - 1]), true
}

begin_platform_input :: proc(input: ^Platform_Input) -> bool {
	if posix.tcgetattr(posix.STDIN_FILENO, &input.original) != .OK {
		return false
	}
	mode := input.original
	mode.c_lflag -= {.ICANON, .ECHO, .ISIG, .IEXTEN}
	mode.c_iflag -= {.IXON}
	mode.c_cc[.VMIN] = 1
	mode.c_cc[.VTIME] = 0
	return posix.tcsetattr(posix.STDIN_FILENO, .TCSANOW, &mode) == .OK
}

restore_platform_input :: proc(input: ^Platform_Input) {
	posix.tcsetattr(posix.STDIN_FILENO, .TCSANOW, &input.original)
}

read_platform_key :: proc(_: ^Platform_Input) -> Platform_Key {
	state: enum { Normal, Escape, Sequence }
	for {
		byte_read: [1]byte
		n, err := os.read(os.stdin, byte_read[:])
		if err == .EOF || (err == nil && n == 0) {
			return .Cancel
		}
		if err != nil {
			return .Error
		}
		key := byte_read[0]
		if key == 3 || key == 4 {
			return .Cancel
		}
		if key == 27 {
			state = .Escape
			continue
		}
		switch state {
		case .Escape:
			if key == '[' || key == 'O' {
				state = .Sequence
				continue
			}
			state = .Normal
		case .Sequence:
			switch key {
			case 'A': return .Up
			case 'B': return .Down
			case 0x40..=0x7e: state = .Normal
			}
			continue
		case .Normal:
		}
		switch key {
		case ' ': return .Toggle
		case '\r', '\n': return .Confirm
		}
	}
}
