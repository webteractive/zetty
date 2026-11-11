package main

import (
	"errors"
	"io"
	"net"
	"os"
	"sync"
	"syscall"
)

// splice joins a tsnet connection to one end of a Unix socketpair and
// returns the other end's descriptor for Swift, which keeps its fd-based
// socket code. Either side closing closes both.
func splice(conn net.Conn) (int, error) {
	fds, err := syscall.Socketpair(syscall.AF_UNIX, syscall.SOCK_STREAM, 0)
	if err != nil {
		conn.Close()
		return -1, err
	}
	syscall.CloseOnExec(fds[0])
	syscall.CloseOnExec(fds[1])
	local := os.NewFile(uintptr(fds[0]), "tailnet-splice")
	localConn, err := net.FileConn(local)
	local.Close() // FileConn dup'd it
	if err != nil {
		syscall.Close(fds[1])
		conn.Close()
		return -1, err
	}
	var once sync.Once
	closeBoth := func() {
		once.Do(func() {
			conn.Close()
			localConn.Close()
		})
	}
	// Errors other than the other direction having closed both are worth a
	// line in Zetty's log.
	report := func(direction string, err error) {
		if err != nil && !errors.Is(err, net.ErrClosed) {
			logLine("splice: %s %v: %v", direction, conn.RemoteAddr(), err)
		}
	}
	go func() {
		_, err := io.Copy(conn, localConn)
		report("to", err)
		closeBoth()
	}()
	go func() {
		_, err := io.Copy(localConn, conn)
		report("from", err)
		closeBoth()
	}()
	return fds[1], nil
}
