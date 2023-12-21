# ==============================================================================
# Deployment

NETWORK ?= auto

# Output for generated Solidity artifacts. Generation and commit is done in the `bindings.yaml` workflow.
# Do not edit locally, it's separate from `out` to avoid any merge conflicts due to formatting differences.
OUTPUT ?= .out

deploy-ipc:
	./ops/deploy.sh $(NETWORK)

deploy-subnet-registry:
	./ops/deploy-subnet-registry.sh $(NETWORK)

deploy-subnet:
	./ops/deploy-subnet.sh $(NETWORK)

upgrade-gw-diamond:
	./ops/upgrade-gw-diamond.sh $(NETWORK)

upgrade-sa-diamond:
	./ops/upgrade-sa-diamond.sh $(NETWORK)

upgrade-sr-diamond:
	./ops/upgrade-sr-diamond.sh $(NETWORK)

# ==============================================================================
# Code generation on CI

gen: compile-abi rust-binding

compile-abi: | forge
	rm -rf $(OUTPUT)
	mkdir -p $(OUTPUT)
	./ops/compile-abi.sh $(OUTPUT)

commit-abi:
	./ops/commit-abi.sh $(OUTPUT)

rust-binding:
	OUTPUT=$(OUTPUT) BUILD_BINDINGS=1 cargo build --locked --release --manifest-path ./binding/Cargo.toml -p ipc_actors_abis

commit-rust-binding:
	./ops/commit-rust-binding.sh

check-rust-binding:
	cargo fmt --manifest-path ./binding/Cargo.toml && \
	cargo clippy --manifest-path ./binding/Cargo.toml && \
	./ops/check-rust-binding.sh

# ==============================================================================
# Running security checks within the local computer

slither:
	slither . --config-file ./slither.config.json

check-gateway:
	docker run --rm -v $(shell pwd):/app -w /app mythril/myth:latest -v4 analyze --solc-json remappings.json ./src/Gateway.sol --solv 0.8.19

check-subnet:
	docker run --rm -v $(shell pwd):/app -w /app mythril/myth:latest -v4 analyze --solc-json remappings.json ./src/SubnetActor.sol --solv 0.8.19

# ==============================================================================
# Development support

lint:
	solhint 'src/**/*.sol'

fmt:
	npm install --silent --no-save
	npx prettier --check -w 'src/**/**/*.sol' 'test/**/**/*.sol' 'test/**/**/*.t.sol' '**/*.{js,jsx,ts,tsx,json,css,md}'

build: | forge
	forge build

test:
	forge test -vvv --ffi

install-dev: install-npm-package install-eth-abi

install-npm-package:
	npm install --save-dev

install-eth-abi:
	curl -sSL https://bootstrap.pypa.io/get-pip.py -o get-pip.py && python3 get-pip.py && rm get-pip.py && python3 -m pip install eth_abi

storage:
	rm -rf ./cache
	rm -rf ./cache_hardhat
	npx hardhat storage-layout --update

clean:
	rm -rf ./artifacts
	rm -rf ./cache
	rm -rf ./cache_hardhat
	rm -rf ./typechain

coverage: | forge
	forge coverage --ffi --report lcov -C ./src
	genhtml -o coverage_report lcov.info --branch-coverage
	./tools/check_coverage.sh

make coverage-for-mac: | forge
	forge coverage --ffi --report lcov -C ./src
	genhtml -o coverage_report lcov.info --branch-coverage --ignore-errors category
	./tools/check_coverage.sh

prepare: build-selector-library fmt lint test slither


build-selector-library: | forge
	python scripts/python/build_selector_library.py
	npx prettier -w test/helpers/SelectorLibrary.sol

# Forge is used by the ipc-solidity-actors compilation steps.
.PHONY: forge
forge:
	@if [ -z "$(shell which forge)" ]; then \
		echo "Please install Foundry. See https://book.getfoundry.sh/getting-started/installation"; \
		exit 1; \
	fi

# ==============================================================================
.PHONY: deploy-ipc lint fmt check-subnet slither check-gateway test prepare storage build clean
