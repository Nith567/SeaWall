.PHONY: build test fork-test anvil deploy frontend frontend-install smoke clean

build:
	forge build

test:
	forge test

fork-test:
	MAINNET_RPC_URL=$(MAINNET_RPC_URL) forge test --match-contract MainnetForkTest -vv

anvil:
	anvil --port 8546

demo-fork:
	MAINNET_RPC_URL=$(MAINNET_RPC_URL) ./script/demo-fork.sh

smoke-fork:
	cd frontend && node --experimental-strip-types scripts/smoke.ts

deploy:
	forge script script/DeployLocal.s.sol --rpc-url http://127.0.0.1:8546 --broadcast

frontend-install:
	cd frontend && pnpm install

frontend:
	cd frontend && pnpm dev

smoke:
	cd frontend && node --experimental-strip-types scripts/smoke.ts

clean:
	forge clean && rm -rf frontend/dist
