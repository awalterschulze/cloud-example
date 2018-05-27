.PHONY: build run test setup

build:
	stack build

test: build
	stack test

run: build
	stack exec iohk-interview-exe -- --send-for 1 --wait-for 1 --port 4445 &
	stack exec iohk-interview-exe -- --send-for 1 --wait-for 1 --port 4446 &
	stack exec iohk-interview-exe -- --send-for 1 --wait-for 1 --port 4447 &
	stack exec iohk-interview-exe -- --master --send-for 1 --wait-for 1

stop:
	pkill iohk-interview-exe

setup:
	stack setup

ide-setup:
	stack build intero

lint:
	hlint .

