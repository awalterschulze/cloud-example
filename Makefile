.PHONY: build run test setup

build:
	stack build

test: build
	stack test

run: build
	stack exec cloud-example-exe -- --port 4445 &
	stack exec cloud-example-exe -- --port 4446 &
	stack exec cloud-example-exe -- --port 4447 &
	stack exec cloud-example-exe -- --master --send-for 1 --wait-for 1 --with-seed 123 --discover

stop:
	pkill cloud-example-exe || true

setup:
	stack setup

ide-setup:
	stack build intero

lint:
	hlint .

