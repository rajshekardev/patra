package main

import "core:fmt"
import "core:os"
import "core:sys/windows"
import "core:unicode/utf16"

update_curl_path :: proc() -> string {
	directory: [260]u16
	n := windows.GetSystemDirectoryW(&directory[0], len(directory))
	if n == 0 || n >= len(directory) {
		return ""
	}
	utf8_directory: [len(directory) * 4]byte
	length := utf16.decode_to_utf8(utf8_directory[:], directory[:n])
	return fmt.tprintf("%s\\curl.exe", string(utf8_directory[:length]))
}

update_executable_path :: proc() -> (path: string, err: os.Error) {
	executable := os.get_executable_path(context.allocator) or_return
	file := os.open(executable, {.Read}) or_return
	defer os.close(file)
	info := os.fstat(file, context.allocator) or_return
	return info.fullpath, nil
}

replace_executable :: proc(staged, executable: string) -> bool {
	lock_path := windows.utf8_to_wstring(fmt.tprintf("%s.patra-update-lock", executable))
	lock := windows.CreateFileW(lock_path, windows.DELETE, 0, nil, windows.CREATE_NEW,
		windows.FILE_ATTRIBUTE_NORMAL | windows.FILE_FLAG_DELETE_ON_CLOSE, nil)
	if lock == windows.INVALID_HANDLE_VALUE {
		err := os.Platform_Error(windows.GetLastError())
		update_error("cannot lock the executable for update", err)
		return false
	}
	defer windows.CloseHandle(lock)

	if os.rename(staged, executable) == nil {
		return true
	}

	// Windows can allow renaming a running image while blocking its replacement.
	backup := fmt.tprintf("%s.patra-old", executable)
	old_info, stat_err := os.lstat(backup, context.allocator)
	if stat_err != nil && stat_err != .Not_Exist {
		update_error("cannot inspect the previous backup", stat_err)
		return false
	}
	if stat_err == nil {
		if old_info.type != .Regular {
			fmt.eprintf("patra: the backup path is not a regular file: %s\n", backup)
			return false
		}
		if err := os.remove(backup); err != nil {
			update_error("cannot remove the previous backup", err)
			return false
		}
	}
	if err := os.rename(executable, backup); err != nil {
		update_error("cannot move the running executable aside", err)
		return false
	}
	if err := os.rename(staged, executable); err != nil {
		update_error("cannot install the updated executable", err)
		if restore_err := os.rename(backup, executable); restore_err != nil {
			update_error(fmt.tprintf("could not restore the executable from %s", backup), restore_err)
		}
		return false
	}
	return true
}
