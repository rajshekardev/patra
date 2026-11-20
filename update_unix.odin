#+build linux, darwin
package main

import "core:os"

update_curl_path :: proc() -> string {
	return "curl"
}

update_executable_path :: proc() -> (path: string, err: os.Error) {
	executable := os.get_executable_path(context.allocator) or_return
	return os.get_absolute_path(executable, context.allocator)
}

replace_executable :: proc(staged, executable: string) -> bool {
	if err := os.rename(staged, executable); err != nil {
		update_error("cannot replace the running executable", err)
		return false
	}
	return true
}
