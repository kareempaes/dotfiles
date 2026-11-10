.DEFAULT_GOAL := help

# Neovim names its Linux builds x86_64 and arm64
ARCH := $(shell uname -m | sed 's/aarch64/arm64/')

.PHONY: help macos linux
help: ## List targets
	@grep -hE '^[a-zA-Z_-]+:.*## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*## "}; {printf "  %-10s %s\n", $$1, $$2}'

macos: ## Install the programs with Homebrew, then link the configs
	brew install neovim tmux ripgrep fd
	brew install --cask ghostty
	./install.sh macos

linux: ## Install the programs with apt and Neovim's own build (Linux Mint, Ubuntu), then link the configs
	sudo apt-get update
	sudo apt-get install -y tmux ripgrep fd-find xclip curl python3 build-essential pulseaudio-utils sound-theme-freedesktop
	sudo apt-get install -y ghostty || echo "Ghostty is not in this system's apt: https://ghostty.org/docs/install/binary"
	sudo rm -rf /opt/nvim-linux-$(ARCH)
	curl -fsSL https://github.com/neovim/neovim/releases/latest/download/nvim-linux-$(ARCH).tar.gz | sudo tar -xz -C /opt
	sudo ln -sf /opt/nvim-linux-$(ARCH)/bin/nvim /usr/local/bin/nvim
	mkdir -p ~/.local/bin && ln -sf "$$(command -v fdfind)" ~/.local/bin/fd
	./install.sh linux

-include publish.mk
