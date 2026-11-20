# Patra

Patra is an Odin-based task runner. Define commands in a `run.patra` file and run them by name.

## Demo

From your project directory, run `patra --init` to generate `run.patra`, then run its starter task.

```sh
patra --init
patra help
```

`patra help` runs the starter task and prints `patra help`. Initialization reports an error if the file already exists and preserves its contents. You can also create `run.patra` in a text editor. To try tasks and groups, replace the starter contents with this example.

```text
help:
    echo 'patra help'

dev:
    echo 'Starting dev'
    echo 'Dev is ready'

build:
    linux:
        echo 'Building for Linux'
    windows:
        echo 'Building for Windows'
    release:
        package:
            echo 'Packaging release'

check.v1-fast_2:
    echo 'Checking status: ready'
```

```sh
patra dev                    # Runs both commands in order
patra build linux            # Runs a task in a group
patra build release package  # Runs a task in a nested group
patra check.v1-fast_2        # Runs a task with punctuation in its name
```

### File format

- Start each top-level header at the left margin. Write the name followed immediately by `:`. Names are case-sensitive and may contain ASCII letters, digits, underscores, hyphens, and periods. The `--` prefix is reserved for built-ins at the top level.
- Indent each body with spaces. The demo uses four spaces per level. Sibling headers must align and have unique names within their group. Blank lines can separate tasks.
- Give each header either an indented shell script or a group of indented task headers. Each runnable task executes as one shell script, so its lines share variables and working-directory changes.
- Write shell comments inside a script body. At the file level and inside groups, Patra expects task headers. A line that looks like a task header at the script’s base indentation is reserved for the file format.
- Patra reads `run.patra` from your current directory and validates the entire file before running the selected task.

### Invalid examples

Each numbered example below is a separate invalid `run.patra` fragment. The numbered comment lines label the examples.

```text
# 1. Empty body
dev:

# 2. Missing colon
dev
    echo 'Starting dev'

# 3. Invalid character in the name
build linux:
    echo 'Building for Linux'

# 4. Command on the header line
dev: echo 'Starting dev'

# 5. Indented top-level header
    dev:
        echo 'Starting dev'

# 6. A tab instead of spaces for indentation
dev:
	echo 'Starting dev'

# 7. Misaligned sibling headers
build:
    linux:
        echo 'Building for Linux'
  windows:
      echo 'Building for Windows'

# 8. Duplicate names in the same group
build:
    linux:
        echo 'First build'
    linux:
        echo 'Second build'

# 9. A script and a subtask in the same body
build:
    echo 'Building'
    linux:
        echo 'Building for Linux'

# 10. File-level comment
# Build tasks
dev:
    echo 'Starting dev'
```

These commands also fail with the valid demo file above.

```sh
patra build        # A group requires a subtask
patra build ios    # The group has no task named ios
patra dev extra    # A runnable task has no subtasks
patra Dev          # Names are case-sensitive
```

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

Run `patra --update` to install the latest stable release from GitHub for your platform. Patra checks the download against GitHub's SHA-256 digest before replacing the executable you ran. Updating requires write access to its directory and uses `curl` on Linux and macOS or the system `curl.exe` on Windows. On Windows, if the running executable needs to be moved aside, Patra keeps it next to the updated executable with a `.patra-old` suffix.

## Usage

`patra --help` lists built-in commands. `patra --version` prints the Patra version. From your project directory, run `patra --init` to create a starter `run.patra`, and use `patra <task> [subtask ...]` to run a task. Bare names such as `patra init` are task lookups.

Task scripts use `/bin/sh` on Linux and macOS and Windows PowerShell on Windows. When a Windows task calls a native executable and needs to stop after a failure before running the next command, check `$LASTEXITCODE` in the task.

### New projects

Run `patra --new` in an interactive terminal and enter a project name. Use Up and Down to highlight a platform, Space to toggle it, and Enter to confirm at least one selection. Use Ctrl+C to cancel.

The available platforms are Android, iOS, Windows, Linux, macOS, Server, and Website. Server is for an Odin web server. Website is for an Odin frontend using the Patra UI library.

Patra creates a new project directory containing only `config.json`. The configuration stores the project name and the selected platforms in menu order.

```json
{
  "name": "My Project",
  "platforms": ["linux", "website"]
}
```

## Releases

[GitHub Releases](https://github.com/rajshekardev/patra/releases) lists published versions and their downloads. Every build embeds `VERSION`. To publish a release, update `VERSION`, commit it, and push a matching Git tag. The Distribution workflow validates the tag, builds and smoke-tests the executables, and publishes them with the source archive.
