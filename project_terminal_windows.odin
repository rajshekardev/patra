package main

import "core:strings"
import "core:sys/windows"
import "core:unicode/utf16"

Platform_Input :: struct {
	stdin, stdout: windows.HANDLE,
	input_mode, output_mode: windows.DWORD,
}

has_project_terminal :: proc() -> bool {
	mode: windows.DWORD
	return bool(windows.GetConsoleMode(windows.GetStdHandle(windows.STD_INPUT_HANDLE), &mode)) &&
	       bool(windows.GetConsoleMode(windows.GetStdHandle(windows.STD_OUTPUT_HANDLE), &mode))
}

read_project_name :: proc() -> (string, bool) {
	stdin := windows.GetStdHandle(windows.STD_INPUT_HANDLE)
	buffer: [4096]u16
	n: windows.DWORD
	if !windows.ReadConsoleW(stdin, &buffer[0], len(buffer), &n, nil) || n == 0 || buffer[0] == 26 {
		return "", false
	}
	if buffer[n - 1] == '\n' && n <= 257 {
		utf8_buffer: [4 * 257]byte
		length := utf16.decode_to_utf8(utf8_buffer[:], buffer[:n])
		return strings.clone(strings.trim_right(string(utf8_buffer[:length]), "\r\n")), true
	}

	// Discard the remainder of a line too long to be a directory name.
	for buffer[n - 1] != '\n' {
		if !windows.ReadConsoleW(stdin, &buffer[0], len(buffer), &n, nil) || n == 0 {
			return "", false
		}
	}
	return "", true
}

begin_platform_input :: proc(input: ^Platform_Input) -> bool {
	input.stdin = windows.GetStdHandle(windows.STD_INPUT_HANDLE)
	input.stdout = windows.GetStdHandle(windows.STD_OUTPUT_HANDLE)
	if !windows.GetConsoleMode(input.stdin, &input.input_mode) ||
	   !windows.GetConsoleMode(input.stdout, &input.output_mode) {
		return false
	}

	output_mode := input.output_mode | windows.ENABLE_PROCESSED_OUTPUT | windows.ENABLE_VIRTUAL_TERMINAL_PROCESSING
	if !windows.SetConsoleMode(input.stdout, output_mode) {
		return false
	}
	input_mode := input.input_mode &~ (windows.ENABLE_PROCESSED_INPUT | windows.ENABLE_VIRTUAL_TERMINAL_INPUT)
	if !windows.SetConsoleMode(input.stdin, input_mode) {
		windows.SetConsoleMode(input.stdout, input.output_mode)
		return false
	}
	return true
}

restore_platform_input :: proc(input: ^Platform_Input) {
	windows.SetConsoleMode(input.stdin, input.input_mode)
	windows.SetConsoleMode(input.stdout, input.output_mode)
}

read_platform_key :: proc(input: ^Platform_Input) -> Platform_Key {
	for {
		record: windows.INPUT_RECORD
		n: windows.DWORD
		if !windows.ReadConsoleInputW(input.stdin, &record, 1, &n) {
			return .Error
		}
		if n == 0 || record.EventType != .KEY_EVENT || !record.Event.KeyEvent.bKeyDown {
			continue
		}
		key := record.Event.KeyEvent
		ctrl := key.dwControlKeyState & {.LEFT_CTRL_PRESSED, .RIGHT_CTRL_PRESSED}
		if key.uChar.UnicodeChar == 3 || key.uChar.UnicodeChar == 4 ||
		   (ctrl != {} && (key.wVirtualKeyCode == windows.VK_C || key.wVirtualKeyCode == windows.VK_D)) {
			return .Cancel
		}
		switch key.wVirtualKeyCode {
		case windows.VK_UP:     return .Up
		case windows.VK_DOWN:   return .Down
		case windows.VK_SPACE:  return .Toggle
		case windows.VK_RETURN: return .Confirm
		}
	}
}
