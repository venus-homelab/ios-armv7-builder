// pt-driver -- minimal pt manager for the obfs4proxy on-device E2E.
//
// Spawns obfs4proxy as a managed CLIENT (the pt env/stdio protocol
// exactly as tor's ClientTransportPlugin would), reads the CMETHOD line
// for the local SOCKS port, then drives one SOCKS5 CONNECT through it
// with the obfs4 bridge args in the RFC1929 username/password fields
// (cert=<cert>;iat-mode=<n> -- the wire format obfs4proxy's own
// common/socks5/rfc1929.go defines), sends one HTTP GET to the canary
// target and asserts the canned body survives the tunnel.
//
// Full loop under test (probe/e2e-run.sh orchestrates the host half):
//
//	pt-driver -> obfs4proxy (client, device) --obfs4--> obfs4proxy
//	(server, host) -> canary HTTP server (host)
//
// Every step logs one "PT-DRIVER <step>: <detail>" line so a stall
// names the exact ring that broke.  Cross-builds for GOOS=darwin
// GOARCH=arm (device) and linux/amd64 (host self-test), see
// probe/build.sh.
package main

import (
	"bufio"
	"encoding/binary"
	"flag"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"time"
)

var (
	flagObfs4   = flag.String("obfs4proxy", "", "path to the obfs4proxy binary")
	flagCert    = flag.String("cert", "", "obfs4 cert= parameter (unpadded base64)")
	flagIAT     = flag.Int("iat", 0, "obfs4 iat-mode (0/1/2)")
	flagTarget  = flag.String("target", "", "canary target host:port (SOCKS CONNECT destination)")
	flagState   = flag.String("statedir", "", "TOR_PT_STATE_LOCATION (created if missing)")
	flagObfsLog = flag.Bool("obfs4log", false, "spawn obfs4proxy with -enableLogging -unsafeLogging -logLevel DEBUG and dump its log")
	flagTimeout = flag.Duration("timeout", 120*time.Second, "overall deadline")
)

var pass = true

func step(format string, args ...interface{}) {
	fmt.Printf("PT-DRIVER step: %s\n", fmt.Sprintf(format, args...))
}

func fail(format string, args ...interface{}) {
	pass = false
	fmt.Printf("PT-DRIVER FAIL: %s\n", fmt.Sprintf(format, args...))
}

func main() {
	flag.Parse()
	if *flagObfs4 == "" || *flagCert == "" || *flagTarget == "" || *flagState == "" {
		flag.Usage()
		os.Exit(2)
	}
	done := time.After(*flagTimeout)
	result := make(chan error, 1)
	go func() { result <- run() }()
	select {
	case err := <-result:
		if err != nil {
			fail("run: %v", err)
		}
	case <-done:
		fail("overall deadline (%s) exceeded", *flagTimeout)
	}
	if *flagObfsLog {
		dump, err := os.ReadFile(*flagState + "/obfs4proxy.log")
		if err == nil {
			fmt.Printf("PT-DRIVER obfs4proxy.log (%d bytes):\n%s", len(dump), dump)
		}
	}
	if pass {
		fmt.Println("PT-DRIVER PASS: full loop ok (spawn -> CMETHOD -> SOCKS5/cert -> obfs4 -> canary)")
		os.Exit(0)
	}
	os.Exit(1)
}

func run() error {
	if err := os.MkdirAll(*flagState, 0o700); err != nil {
		return fmt.Errorf("statedir: %w", err)
	}

	// ---- ring 1: spawn obfs4proxy as a managed client (pt protocol) ----
	step("spawn %s (TOR_PT_MANAGED_TRANSPORT_VER=1, TOR_PT_CLIENT_TRANSPORTS=obfs4, TOR_PT_STATE_LOCATION=%s)",
		*flagObfs4, *flagState)
	args := []string{}
	if *flagObfsLog {
		// default logging is ioutil.Discard (common/log/log.go Init):
		// turn it on into stateDir/obfs4proxy.log for diagnosis
		args = append(args, "-enableLogging", "-unsafeLogging", "-logLevel", "DEBUG")
	}
	cmd := exec.Command(*flagObfs4, args...)
	cmd.Env = append(os.Environ(),
		"TOR_PT_MANAGED_TRANSPORT_VER=1",
		"TOR_PT_CLIENT_TRANSPORTS=obfs4",
		"TOR_PT_STATE_LOCATION="+*flagState,
		"TOR_PT_EXIT_ON_STDIN_CLOSE=1",
	)
	// keep stdin open so obfs4proxy does not treat it as "parent died"
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return err
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return err
	}
	cmd.Stderr = os.Stderr // fatal messages (golog) stay visible, out of the line scan
	if err := cmd.Start(); err != nil {
		return fmt.Errorf("spawn: %w", err)
	}
	defer func() {
		stdin.Close() // TOR_PT_EXIT_ON_STDIN_CLOSE=1 -> graceful pt shutdown
		done := make(chan struct{})
		go func() { cmd.Wait(); close(done) }()
		select {
		case <-done:
		case <-time.After(5 * time.Second):
			_ = cmd.Process.Kill()
			<-done
		}
	}()

	// ---- ring 2: read the pt config protocol from stdout ---------------
	socksAddr := ""
	scanner := bufio.NewScanner(stdout)
	scanDone := make(chan error, 1)
	go func() {
		for scanner.Scan() {
			line := scanner.Text()
			fmt.Printf("PT-DRIVER ptline: %s\n", line)
			switch {
			case line == "VERSION 1":
				step("pt version negotiated")
			case strings.HasPrefix(line, "CMETHOD-ERROR"), strings.HasPrefix(line, "ENV-ERROR"),
				strings.HasPrefix(line, "VERSION-ERROR"):
				scanDone <- fmt.Errorf("pt error line: %s", line)
				return
			case strings.HasPrefix(line, "CMETHOD "):
				f := strings.Fields(line)
				// CMETHOD obfs4 socks5 127.0.0.1:PORT (goptlib line())
				if len(f) != 4 || f[1] != "obfs4" || f[2] != "socks5" {
					scanDone <- fmt.Errorf("unexpected CMETHOD line: %q", line)
					return
				}
				socksAddr = f[3]
			case line == "CMETHODS DONE":
				scanDone <- nil
				return
			}
		}
		scanDone <- scanner.Err()
	}()
	select {
	case err := <-scanDone:
		if err != nil {
			return err
		}
	case <-time.After(30 * time.Second):
		return fmt.Errorf("timeout waiting for CMETHODS DONE")
	}
	if socksAddr == "" {
		return fmt.Errorf("no CMETHOD line received")
	}
	step("CMETHOD parsed: obfs4 SOCKS at %s", socksAddr)

	// ---- ring 3: SOCKS5 handshake with the obfs4 bridge args -----------
	conn, err := net.DialTimeout("tcp", socksAddr, 15*time.Second)
	if err != nil {
		return fmt.Errorf("dial socks %s: %w", socksAddr, err)
	}
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(60 * time.Second))

	if _, err := conn.Write([]byte{0x05, 0x01, 0x02}); err != nil {
		return err
	}
	hello := make([]byte, 2)
	if _, err := io.ReadFull(conn, hello); err != nil {
		return fmt.Errorf("socks greeting read: %w", err)
	}
	if hello[0] != 0x05 || hello[1] != 0x02 {
		return fmt.Errorf("socks greeting reply: %#x", hello)
	}
	// RFC1929 fields are CONCATENATED into one args string and parsed by
	// common/socks5/args.go parseClientParameters: key=value pairs split
	// on ';'.  The ';' between the two halves lives at the START of the
	// password field (tor does the same when it packs bridge args).
	uname := []byte("cert=" + *flagCert)
	upass := []byte(";iat-mode=" + strconv.Itoa(*flagIAT))
	auth := append([]byte{0x01, byte(len(uname))}, uname...)
	auth = append(auth, byte(len(upass)))
	auth = append(auth, upass...)
	if len(uname) > 255 || len(upass) > 255 {
		return fmt.Errorf("rfc1929 field overflow: ulen=%d plen=%d", len(uname), len(upass))
	}
	if _, err := conn.Write(auth); err != nil {
		return err
	}
	arep := make([]byte, 2)
	if _, err := io.ReadFull(conn, arep); err != nil {
		return fmt.Errorf("socks auth read: %w", err)
	}
	if arep[0] != 0x01 || arep[1] != 0x00 {
		return fmt.Errorf("socks auth reply: %#x (obfs4 args rejected)", arep)
	}
	step("SOCKS5 RFC1929 accepted: cert=%s iat-mode=%d (%d+%d bytes in uname/passwd)",
		(*flagCert)[:12]+"...", *flagIAT, len(uname), len(upass))

	// CONNECT to the canary target (ATYP=1 if IP, else ATYP=3 domain)
	host, portStr, err := net.SplitHostPort(*flagTarget)
	if err != nil {
		return err
	}
	port, err := strconv.Atoi(portStr)
	if err != nil || port <= 0 || port > 65535 {
		return fmt.Errorf("bad port in target %q", *flagTarget)
	}
	var req []byte
	if ip := net.ParseIP(host); ip != nil && ip.To4() != nil {
		req = append([]byte{0x05, 0x01, 0x00, 0x01}, ip.To4()...)
		req = binary.BigEndian.AppendUint16(req, uint16(port))
	} else {
		req = append([]byte{0x05, 0x01, 0x00, 0x03, byte(len(host))}, host...)
		req = binary.BigEndian.AppendUint16(req, uint16(port))
	}
	if _, err := conn.Write(req); err != nil {
		return err
	}
	head := make([]byte, 4)
	if _, err := io.ReadFull(conn, head); err != nil {
		return fmt.Errorf("socks reply read: %w", err)
	}
	if head[0] != 0x05 || head[1] != 0x00 {
		return fmt.Errorf("socks CONNECT reply: ver=%d rep=%d", head[0], head[1])
	}
	switch head[3] {
	case 0x01:
		bnd := make([]byte, 6)
		if _, err := io.ReadFull(conn, bnd); err != nil {
			return err
		}
	case 0x03:
		n := make([]byte, 1)
		if _, err := io.ReadFull(conn, n); err != nil {
			return err
		}
		bnd := make([]byte, int(n[0])+2)
		if _, err := io.ReadFull(conn, bnd); err != nil {
			return err
		}
	case 0x04:
		bnd := make([]byte, 18)
		if _, err := io.ReadFull(conn, bnd); err != nil {
			return err
		}
	}
	step("SOCKS5 CONNECT rep=0 (target %s through obfs4 tunnel)", *flagTarget)

	// ---- ring 4: HTTP GET to the canary through the full loop ----------
	httpReq := fmt.Sprintf("GET / HTTP/1.0\r\nHost: %s\r\nUser-Agent: pt-driver/1\r\n\r\n", *flagTarget)
	if _, err := conn.Write([]byte(httpReq)); err != nil {
		return fmt.Errorf("http write: %w", err)
	}
	resp, err := io.ReadAll(conn)
	if err != nil && len(resp) == 0 {
		return fmt.Errorf("http read: %w", err)
	}
	preview := string(resp)
	if len(preview) > 120 {
		preview = preview[:120]
	}
	fmt.Printf("PT-DRIVER http-reply: %d bytes, head %q\n", len(resp), preview)
	if !strings.Contains(string(resp), "obfs4proxy-E2E-OK") {
		return fmt.Errorf("canned body not found in reply")
	}
	step("canary body verified through the obfs4 tunnel")
	return nil
}
