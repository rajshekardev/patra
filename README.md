# Patra

Patra is an Odin-based task runner. Define commands in a `run.patra` file and run them by name.

## Downloads

| Platform | Standalone executable | Installer |
| --- | --- | --- |
| Linux x86-64 | [patra-linux-amd64](https://github.com/rajshekardev/patra/releases/latest/download/patra-linux-amd64) | [tar.gz](https://github.com/rajshekardev/patra/releases/latest/download/patra-linux-amd64.tar.gz) |
| Linux ARM64 | [patra-linux-arm64](https://github.com/rajshekardev/patra/releases/latest/download/patra-linux-arm64) | [tar.gz](https://github.com/rajshekardev/patra/releases/latest/download/patra-linux-arm64.tar.gz) |
| macOS 13+ (Apple Silicon and Intel) | [patra-macos-universal](https://github.com/rajshekardev/patra/releases/latest/download/patra-macos-universal) | |
| Windows x86-64 | [patra-windows-amd64.exe](https://github.com/rajshekardev/patra/releases/latest/download/patra-windows-amd64.exe) | |
| Source | [patra-source.zip](https://github.com/rajshekardev/patra/releases/latest/download/patra-source.zip) | |

Extract the Linux installer archive and run `sh install.sh` from the extracted directory. It copies Patra to `~/.local/bin/patra`, runs it, and prints instructions if your shell needs a PATH update.

For manual installation on Linux or macOS, rename the downloaded file to `patra`, run `chmod +x patra`, and place it in a directory on your PATH. On Windows, rename it to `patra.exe` and place it in a directory on your PATH. The release binaries are unsigned.

## Usage

Run these commands from your project directory.

```sh
patra setup
patra help
```

`patra setup` creates a starter `run.patra`. Use `patra <task> [subtask ...]` to run a task. Task scripts use `/bin/sh` on Linux and macOS and Windows PowerShell on Windows. When a Windows task calls a native executable and needs to stop after a failure before running the next command, check `$LASTEXITCODE` in the task.

## Releases

[GitHub Releases](https://github.com/rajshekardev/patra/releases) lists published versions and their downloads. The Distribution workflow builds and smoke-tests the executables. Push a version tag such as `v0.1.0` on a commit containing the workflow to publish a release.
