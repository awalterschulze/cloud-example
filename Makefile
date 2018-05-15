.PHONY: build run test setup

build:
	stack build

test: 
	stack test

test-trace:
	stack test --trace

run: build
	stack exec iohk-interview-exe slave 4445 &
	stack exec iohk-interview-exe slave 4446 &
	stack exec iohk-interview-exe

setup:
	stack setup

ide-setup:
	stack build intero

lint:
	hlint .

