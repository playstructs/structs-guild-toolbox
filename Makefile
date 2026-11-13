.PHONY: build install test reactor

build:
	go build -o bin/structs ./cmd/structs

install:
	go install ./cmd/structs

test:
	go test ./...

reactor: build
	./bin/structs reactor
