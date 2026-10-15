package main

import (
	"fmt"
	"net"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
)

// SDK double: a real private listener/process; no Android protocol or GUI claim.
func main() {
	if filepath.Base(os.Args[0]) == "adb" {
		if len(os.Args) > 2 && os.Args[1] == "-L" {
			address := strings.TrimPrefix(os.Args[2], "tcp:")
			listener, err := net.Listen("tcp", address)
			if err != nil {
				fmt.Fprintln(os.Stderr, "cannot bind:", err)
				os.Exit(1)
			}
			defer listener.Close()
		} else {
			if strings.Contains(strings.Join(os.Args, " "), "getprop") {
				fmt.Println("1")
			}
			return
		}
	}
	fmt.Println(os.Getenv("ADB_SERVER_SOCKET"), strings.Join(os.Args[1:], " "))
	done := make(chan os.Signal, 1)
	signal.Notify(done, syscall.SIGINT, syscall.SIGTERM)
	<-done
}
