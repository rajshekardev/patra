package main

import "core:bytes"
import "core:crypto/sha2"
import "core:encoding/hex"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"

LATEST_RELEASE_URL :: "https://api.github.com/repos/rajshekardev/patra/releases/latest"
RELEASE_DOWNLOAD_PREFIX :: "https://github.com/rajshekardev/patra/releases/download/"

Release :: struct {
	tag_name: string,
	assets:   []Release_Asset,
}

Release_Asset :: struct {
	name:                 string,
	browser_download_url: string,
	digest:               string,
	size:                 i64,
}

update_patra :: proc() -> int {
	context.allocator = context.temp_allocator
	asset_name := release_asset_name()
	if asset_name == "" {
		fmt.eprintln("patra: no release binary is available for this platform")
		return 1
	}
	curl := update_curl_path()
	if curl == "" {
		fmt.eprintln("patra: could not locate the system curl executable")
		return 1
	}
	state, metadata, stderr, fetch_err := os.process_exec({
		command = curl_command(curl, LATEST_RELEASE_URL, 2 * 1024 * 1024),
	}, context.allocator)
	if fetch_err != nil {
		return update_error("could not run curl to check for updates", fetch_err)
	}
	if state.exit_code != 0 {
		fmt.eprintf("patra: could not fetch the latest release: %s\n", strings.trim_space(string(stderr)))
		return 1
	}

	release: Release
	if json.unmarshal(metadata, &release) != nil || release.tag_name == "" {
		fmt.eprintln("patra: GitHub returned invalid release metadata")
		return 1
	}
	installed := patra_version()
	latest_parts, valid_latest := stable_version_parts(release.tag_name)
	installed_parts, valid_installed := stable_version_parts(installed)
	if !valid_latest || !valid_installed {
		fmt.eprintln("patra: cannot compare the installed version with the published release")
		return 1
	}
	if !version_is_newer(latest_parts, installed_parts) {
		fmt.printf("Patra is already up to date (%s)\n", installed)
		return 0
	}

	asset: Release_Asset
	for candidate in release.assets {
		if candidate.name == asset_name {
			asset = candidate
			break
		}
	}
	if asset.name == "" {
		fmt.eprintf("patra: release %s has no binary named %s\n", release.tag_name, asset_name)
		return 1
	}
	digest, valid_digest := hex.decode(transmute([]byte)strings.trim_prefix(asset.digest, "sha256:"))
	if !strings.has_prefix(asset.digest, "sha256:") || !valid_digest ||
	   len(digest) != sha2.DIGEST_SIZE_256 || asset.size <= 0 ||
	   !strings.has_prefix(asset.browser_download_url, RELEASE_DOWNLOAD_PREFIX) {
		fmt.eprintf("patra: release %s has invalid download metadata for %s\n", release.tag_name, asset_name)
		return 1
	}

	executable, path_err := update_executable_path()
	if path_err != nil {
		return update_error("cannot locate the running executable", path_err)
	}
	info, stat_err := os.stat(executable, context.allocator)
	if stat_err != nil {
		return update_error("cannot inspect the running executable", stat_err)
	}
	if info.type != .Regular {
		fmt.eprintln("patra: the running executable path is not a regular file")
		return 1
	}
	dir, _ := os.split_path(executable)
	file, stage_err := os.create_temp_file(dir, ".patra-update-*", {.Inheritable})
	if stage_err != nil {
		return update_error(fmt.tprintf("cannot stage an update in %s", dir), stage_err)
	}
	staged := strings.clone(os.name(file))
	defer os.remove(staged)

	downloaded := download_release(curl, asset, digest, file)
	close_err := os.close(file)
	if !downloaded {
		return 1
	}
	if close_err != nil {
		return update_error("cannot close the staged binary", close_err)
	}
	when ODIN_OS != .Windows {
		if err := os.chmod(staged, info.mode & os.Permissions_All); err != nil {
			return update_error("cannot set permissions on the staged binary", err)
		}
	}
	if !replace_executable(staged, executable) {
		return 1
	}
	fmt.printf("Updated Patra to %s\n", release.tag_name)
	return 0
}

stable_version_parts :: proc(tag: string) -> (parts: [3]u64, ok: bool) {
	if !strings.has_prefix(tag, "v") {
		return {}, false
	}
	fields := strings.split(tag[1:], ".")
	if len(fields) != len(parts) {
		return {}, false
	}
	for field, i in fields {
		if len(field) == 0 || (len(field) > 1 && field[0] == '0') {
			return {}, false
		}
		for digit in field {
			if digit < '0' || digit > '9' {
				return {}, false
			}
		}
		value, parsed := strconv.parse_u64(field, 10)
		if !parsed {
			return {}, false
		}
		parts[i] = value
	}
	return parts, true
}

version_is_newer :: proc(candidate, installed: [3]u64) -> bool {
	for part, i in candidate {
		if part != installed[i] {
			return part > installed[i]
		}
	}
	return false
}

release_asset_name :: proc() -> string {
	when ODIN_OS == .Linux && ODIN_ARCH == .amd64 {
		return "patra-linux-amd64"
	} else when ODIN_OS == .Linux && ODIN_ARCH == .arm64 {
		return "patra-linux-arm64"
	} else when ODIN_OS == .Darwin && (ODIN_ARCH == .amd64 || ODIN_ARCH == .arm64) {
		return "patra-macos-universal"
	} else when ODIN_OS == .Windows && ODIN_ARCH == .amd64 {
		return "patra-windows-amd64.exe"
	} else {
		return ""
	}
}

curl_command :: proc(curl, url: string, max_bytes: i64) -> []string {
	return slice.clone([]string{
		curl, "--disable", "--fail", "--silent", "--show-error", "--location",
		"--proto", "=https", "--proto-redir", "=https", "--globoff",
		"--connect-timeout", "10", "--max-time", "120",
		"--max-filesize", fmt.tprintf("%d", max_bytes), "--url", url,
	})
}

download_release :: proc(curl: string, asset: Release_Asset, digest: []byte, file: ^os.File) -> bool {
	process, start_err := os.process_start({
		command = curl_command(curl, asset.browser_download_url, asset.size),
		stdout  = file,
		stderr  = os.stderr,
	})
	if start_err != nil {
		update_error("could not start the release download", start_err)
		return false
	}
	state, wait_err := os.process_wait(process)
	if wait_err != nil {
		update_error("could not wait for the release download", wait_err)
		return false
	}
	if state.exit_code != 0 {
		fmt.eprintf("patra: release download failed (curl exit %d)\n", state.exit_code)
		return false
	}
	if err := verify_download(file, asset.size, digest); err != nil {
		if err == .Invalid_File {
			fmt.eprintln("patra: downloaded binary did not match the published size or SHA-256 digest")
		} else {
			update_error("cannot verify the downloaded binary", err)
		}
		return false
	}
	return true
}

verify_download :: proc(file: ^os.File, size: i64, digest: []byte) -> os.Error {
	_, seek_err := os.seek(file, 0, .Start)
	if seek_err != nil {
		return seek_err
	}

	hash: sha2.Context_256
	sha2.init_256(&hash)
	buffer: [32 * 1024]byte
	total: i64
	for {
		n, err := os.read(file, buffer[:])
		total += i64(n)
		if total > size {
			break
		}
		sha2.update(&hash, buffer[:n])
		if err == .EOF || (err == nil && n == 0) {
			break
		}
		if err != nil {
			return err
		}
	}
	actual: [sha2.DIGEST_SIZE_256]byte
	sha2.final(&hash, actual[:])
	if total != size || !bytes.equal(actual[:], digest) {
		return .Invalid_File
	}
	return os.sync(file)
}

update_error :: proc(action: string, err: os.Error) -> int {
	fmt.eprintf("patra: %s: %s\n", action, os.error_string(err))
	return 1
}
