# rice

A minimal tool for managing dotfiles, downloading content, and installing binaries.

## Features

* Bare Git repository for dotfiles
* No symlinks
* Selective file and directory installation
* GitHub repository and URL support
* Archive extraction
* GitHub release binary installation
* Binary tracking and restoration
* Safe pull, restore, and discard operations
* Small native binary written in Zig

## Installation

### Binary

```bash
sudo curl -fL https://github.com/h-jangra/rice/releases/latest/download/rice-x86_64-linux -o /usr/local/bin/rice
```

### From Source

Requires Zig 0.15.1+.

```bash
git clone https://github.com/h-jangra/rice.git
cd rice
zig build -Doptimize=ReleaseSmall
sudo install -Dm755 zig-out/bin/rice /usr/local/bin/rice
```

## Quick Start

### Dotfiles

Initialize a bare repository:

```bash
rice init git@github.com:username/dotfiles.git
```

Or use the shorthand:

```bash
rice init username/dotfiles
```

Track files:

```bash
rice add ~/.config/nvim ~/.gitconfig ~/.zshrc
```

Commit and push:

```bash
rice commit -m "initial dotfiles"
rice push
```

Pull changes safely:

```bash
rice pull
```

Restore on a new machine:

```bash
rice i username/dotfiles
rice restore
```

### Install Files and Directories

Install from your configured repository:

```bash
rice install nvim
```

Install from a specific repository:

```bash
rice install config/tmux ~/.config/tmux \
  --repo https://github.com/username/dotfiles.git
```

Install directly from GitHub:

```bash
rice install https://github.com/username/dotfiles/blob/main/.zshrc ~/.zshrc
rice install https://github.com/username/dotfiles/tree/main/wallpapers ~/Pictures/wallpapers
```

Extract directory contents directly into a destination:

```bash
rice install -C https://github.com/username/dotfiles/tree/main/wallpapers ~/Pictures
```

Install an archive:

```bash
rice install https://example.com/package.zip package/
```

### Binaries

Install a GitHub release binary:

```bash
rice install -b sharkdp/bat
```

Or:

```bash
rice bin sharkdp/bat
```

Save a binary for restoration on other machines:

```bash
rice install -b junegunn/fzf --save
rice bin starship/starship --tag v1.18.0 --save
```

Manage tracked binaries:

```bash
rice bin list
rice bin remove bat
```

Restore all tracked binaries:

```bash
rice restore --bins
```

## Commands

| Command                  | Aliases                | Description                             |
| ------------------------ | ---------------------- | --------------------------------------- |
| `init [remote]`          |                        | Initialize a bare repository            |
| `add <path>...`          | `a`                    | Track files or directories              |
| `remove <path>`          | `rm`                   | Untrack a path                          |
| `list`                   | `ls`                   | List managed paths                      |
| `status`                 | `st`                   | Show Git status                         |
| `diff [path]`            | `d`                    | Show changes                            |
| `commit [-m] <msg>`      | `c`                    | Commit changes                          |
| `push [-m] [msg]`        | `p`                    | Push to origin (supports -m)            |
| `pull [-f]`              | `pl`                   | Pull changes safely                     |
| `switch [-c] <branch>`   | `sw`, `checkout`, `co` | Switch or create a branch               |
| `branches`               | `branch`, `br`         | List branches                           |
| `restore [--bins]`       | `rs`                   | Restore files or binaries               |
| `discard [path...]`      | `dis`                  | Discard local changes                   |
| `install <source> [dst]` | `i`                    | Install files, directories, or binaries |
| `bin [install] <source>` |                        | Manage binaries                         |
| `edit`                   | `e`                    | Edit `~/.rice.ini`                      |
| `doctor`                 |                        | Check repository health                 |
| `version`                | `-v`, `--version`      | Show version                            |

## License

MIT

