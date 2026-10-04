#!/usr/bin/env python3
"""A TCP proxy that can be cut and restored, for tests/reconnect_test.py.

    python3 tests/tcpproxy.py <listen port> <upstream host> <upstream port>

stands between a client and a PostgreSQL so that a test can do to the network what a failure does, without
touching the server (the server is shared; restarting it would not be). As a library:

    proxy = Proxy("127.0.0.1", 5432)        # listens on a free port: proxy.port
    proxy.cut()                             # every connection closed, new ones refused (a server that is down)
    proxy.restore()                         # forwarding again, on the same port
    proxy.blackhole()                       # connections closed; new ones are never answered, not even refused (packets
                                            # are dropped: the accept queue of a listener nobody reads is full)
    proxy.silent()                          # new connections are accepted and never answered (a server that hangs)
    proxy.freeze() / proxy.thaw()           # established connections carry nothing, and are not closed (a cut cable)

`cut`, `blackhole` and `silent` close every established connection first, with a reset when `reset` is true
(the default is a plain close, a FIN, as a server shutting down sends).
"""
import socket
import struct
import sys
import threading
import time


class Proxy:
    def __init__(self, host, port, listen_port=0):
        self.upstream = (host, port)
        self.lock = threading.Lock()
        self.pairs = []
        self.mode = "up"
        self.frozen = False
        self.listener = None
        self.fillers = []
        self.held = []
        self.accepted = 0
        self.port = self._listen(listen_port)

    # -- the listener ----------------------------------------------------------------------------------------
    def _listen(self, port, backlog=128):
        s = socket.socket()
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        s.bind(("127.0.0.1", port))
        s.listen(backlog)
        self.listener = s
        threading.Thread(target=self._accept, args=(s,), daemon=True).start()
        return s.getsockname()[1]

    def _stop_listening(self):
        if self.listener is not None:
            try:
                self.listener.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            self.listener.close()
            self.listener = None
        for s in self.fillers:
            s.close()
        self.fillers = []

    def _accept(self, listener):
        while True:
            try:
                client, _ = listener.accept()
            except OSError:
                return
            with self.lock:
                mode = self.mode
                self.accepted += 1
            if mode == "silent":
                with self.lock:
                    self.held.append(client)
                continue
            try:
                server = socket.create_connection(self.upstream)
            except OSError:
                client.close()
                continue
            for s in (client, server):
                s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            with self.lock:
                self.pairs.append((client, server))
            threading.Thread(target=self._copy, args=(client, server), daemon=True).start()
            threading.Thread(target=self._copy, args=(server, client), daemon=True).start()

    def _copy(self, src, dst):
        try:
            while True:
                data = src.recv(65536)
                if not data:
                    break
                while self.frozen:
                    time.sleep(0.01)
                    if src.fileno() < 0:
                        return
                dst.sendall(data)
        except OSError:
            pass
        finally:
            for s in (src, dst):
                try:
                    s.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass

    def _close_all(self, reset=False):
        with self.lock:
            pairs, self.pairs = self.pairs, []
            held, self.held = self.held, []
        for sock in [s for p in pairs for s in p] + held:
            try:
                if reset:
                    sock.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
                else:
                    sock.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            sock.close()

    # -- what a test does --------------------------------------------------------------------------------------
    def cut(self, reset=False):
        self.frozen = False
        self.mode = "down"
        self._stop_listening()
        self._close_all(reset)

    def restore(self):
        self.frozen = False
        self.mode = "up"
        self._stop_listening()
        self._close_all()
        self._listen(self.port)

    def blackhole(self, reset=False):
        """Close everything, then listen with a queue of one that nothing reads, and fill it: the kernel
        drops the SYNs that come after, so a connect neither completes nor is refused."""
        self.frozen = False
        self.mode = "blackhole"
        self._stop_listening()
        self._close_all(reset)
        s = socket.socket()
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        s.bind(("127.0.0.1", self.port))
        s.listen(0)
        self.listener = s
        for _ in range(4):
            f = socket.socket()
            f.setblocking(False)
            try:
                f.connect(("127.0.0.1", self.port))
            except (BlockingIOError, OSError):
                pass
            self.fillers.append(f)
        time.sleep(0.1)

    def silent(self, reset=False):
        self.frozen = False
        self.mode = "silent"
        self._stop_listening()
        self._close_all(reset)
        self._listen(self.port)

    def freeze(self):
        self.frozen = True

    def thaw(self):
        self.frozen = False

    def close(self):
        self.cut()


if __name__ == "__main__":
    proxy = Proxy(sys.argv[2], int(sys.argv[3]), int(sys.argv[1]))
    print("listening on", proxy.port, flush=True)
    for line in sys.stdin:
        word = line.strip()
        if word in ("cut", "restore", "blackhole", "silent", "freeze", "thaw"):
            getattr(proxy, word)()
            print(word, "ok", flush=True)
