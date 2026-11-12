"""COM1 transport only. Positions and game rules always come from MASM."""

import socket
import struct
import threading
import time
from contextlib import contextmanager
from functools import reduce

HEADER = struct.Struct("<BHHBBBBBHHHII")
PLAYER = struct.Struct("<BBHHIIIB8s")


def encode(payload: bytes) -> bytes:
    if not 1 <= len(payload) <= 256:
        raise ValueError("packet size")
    return (
        b":"
        + (payload + bytes([reduce(int.__xor__, payload, 0)]))
        .hex()
        .upper()
        .encode("ascii")
        + b"\n"
    )


def decode(frame: bytes) -> bytes:
    if not frame.startswith(b":") or not frame.endswith(b"\n") or len(frame) > 516:
        raise ValueError("frame")
    raw = frame[1:-1]
    if not raw or any(c not in b"0123456789ABCDEF" for c in raw):
        raise ValueError("hex")
    data = bytes.fromhex(raw.decode("ascii"))
    if len(data) < 2 or reduce(int.__xor__, data, 0):
        raise ValueError("checksum")
    return data[:-1]


def decode_state(payload: bytes) -> dict:
    if len(payload) != HEADER.size + 8 * PLAYER.size:
        raise ValueError("state size")
    (
        op,
        epoch,
        generation,
        phase,
        cap,
        mode,
        count,
        winners,
        exit_pos,
        distance,
        floor,
        elapsed,
        best,
    ) = HEADER.unpack_from(payload)
    if op != 0x82 or phase not in (1, 2, 3) or cap > 8 or count > 8:
        raise ValueError("state fields")
    players = []
    for i in range(8):
        state, warning, owner, pos, steps, penalty, finish, ready, name = (
            PLAYER.unpack_from(payload, HEADER.size + i * PLAYER.size)
        )
        if state > 3 or warning > 2 or pos >= 1037 or ready > 1:
            raise ValueError("player fields")
        players.append(
            {
                "id": i,
                "state": state,
                "warning": warning,
                "owner": owner,
                "pos": pos,
                "steps": steps,
                "penalty": penalty,
                "finish": finish,
                "ready": bool(ready),
                "name": name.decode("ascii").rstrip(),
            }
        )
    return {
        "epoch": epoch,
        "generation": generation,
        "phase": phase,
        "capacity": cap,
        "mode": mode,
        "count": count,
        "winners": winners,
        "exit": exit_pos,
        "distance": distance,
        "floor": floor,
        "elapsed": elapsed,
        "best": best,
        "players": players,
    }


class TransportError(RuntimeError):
    pass


@contextmanager
def bounded_lock(lock, timeout):
    if not lock.acquire(timeout=timeout):
        raise TransportError("Controller transport is busy; stale input discarded")
    try:
        yield
    finally:
        lock.release()


class SerialLink:
    """One loopback-only DOSBox connection; bounded parser and serialized ACKs."""

    def __init__(self, port=8766):
        self.listener = socket.socket()
        self.listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.listener.bind(("127.0.0.1", port))
        self.listener.listen(1)
        self.listener.settimeout(0.2)
        self.port = self.listener.getsockname()[1]
        self.condition = threading.Condition()
        self.request_lock = threading.Lock()
        self.connection = None
        self.state = None
        self.state_time = 0.0
        self.acks = {}
        self.counter = 0
        self.stopped = threading.Event()
        self.thread = threading.Thread(target=self._serve, daemon=True)
        self.thread.start()

    def _serve(self):
        while not self.stopped.is_set():
            try:
                connection, _ = self.listener.accept()
            except TimeoutError:
                continue
            except OSError:
                break
            connection.settimeout(0.2)
            with self.condition:
                self.connection = connection
                self.state = None
            buffer = bytearray()
            try:
                while not self.stopped.is_set():
                    try:
                        chunk = connection.recv(1024)
                    except TimeoutError:
                        continue
                    if not chunk:
                        break
                    for c in chunk:
                        if c == 58:
                            buffer[:] = b":"
                        elif buffer:
                            buffer.append(c)
                            if len(buffer) > 516:
                                buffer.clear()
                            elif c == 10:
                                try:
                                    self._receive(decode(bytes(buffer)))
                                except (ValueError, UnicodeError):
                                    pass
                                buffer.clear()
            except OSError:
                pass
            finally:
                connection.close()
                with self.condition:
                    self.connection = None
                    self.state = None
                    self.condition.notify_all()

    def _receive(self, data):
        with self.condition:
            if data[0] == 0x82:
                self.state = decode_state(data)
                self.state_time = time.monotonic()
            elif data[0] == 0x81 and len(data) == 7:
                request, epoch, code, slot = struct.unpack_from("<HHBB", data, 1)
                if len(self.acks) >= 64:
                    self.acks.clear()
                self.acks[request] = (epoch, code, slot)
            self.condition.notify_all()

    def latest(self):
        with self.condition:
            if self.state is None or time.monotonic() - self.state_time > 2:
                raise TransportError("DOSBox is disconnected or not responding")
            return self.state

    def request(
        self,
        op,
        epoch,
        payload=b"",
        request_id=None,
        *,
        queue_timeout: float = 3,
        retries=3,
        timeout=0.8,
    ):
        with bounded_lock(self.request_lock, queue_timeout):
            self.counter = self.counter % 65535 + 1
            request = self.counter if request_id is None else request_id
            packet = encode(struct.pack("<BHH", op, request, epoch) + payload)
            if len(packet) > 194:
                raise ValueError("request too large")
            with self.condition:
                self.acks.pop(request, None)
                for _ in range(retries):
                    if self.connection is None:
                        raise TransportError("DOSBox is disconnected")
                    try:
                        self.connection.sendall(packet)
                    except OSError as exc:
                        raise TransportError("COM1 write failed") from exc
                    deadline = time.monotonic() + timeout
                    while request not in self.acks and time.monotonic() < deadline:
                        self.condition.wait(max(0.001, deadline - time.monotonic()))
                    ack = self.acks.pop(request, None)
                    if ack:
                        if ack[0] != epoch:
                            raise TransportError("Room changed; join again")
                        return ack[1], ack[2], request
            raise TransportError("DOSBox command timed out")

    def wait_for(self, predicate, timeout=3):
        deadline = time.monotonic() + timeout
        with self.condition:
            while time.monotonic() < deadline:
                if self.state is not None and predicate(self.state):
                    return self.state
                self.condition.wait(0.05)
        raise TransportError("Game state did not update")

    def close(self):
        self.stopped.set()
        self.listener.close()
        if self.connection:
            try:
                self.connection.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
        self.thread.join(2)
