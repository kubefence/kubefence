BINARY := 10-nono-nri
CMD := ./cmd/nono-nri

.PHONY: build test clean

build:
	go build -o $(BINARY) $(CMD)

test:
	go test ./internal/... -v -count=1

test-all:
	go test ./... -v -count=1

clean:
	rm -f $(BINARY)

lint:
	go vet ./...
