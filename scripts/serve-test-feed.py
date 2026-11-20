#!/usr/bin/env python3
import argparse
import http.server
import mimetypes
import os
import socket
import ssl
import stat
from urllib.parse import unquote_to_bytes, urlsplit


def absolute_parts(path):
    if not os.path.isabs(path) or "\x00" in path or "\\" in path:
        raise ValueError("paths must be absolute filesystem paths")
    parts = path.split(os.sep)
    if any(part in (".", "..") for part in parts):
        raise ValueError("paths must not contain dot segments")
    return [part for part in parts if part]


def open_directory(path):
    parts = absolute_parts(path)
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
    descriptor = os.open(os.sep, flags)
    try:
        for part in parts:
            child = os.open(part, flags, dir_fd=descriptor)
            os.close(descriptor)
            descriptor = child
        canonical = os.path.join(os.sep, *parts) if parts else os.sep
        return descriptor, canonical
    except Exception:
        os.close(descriptor)
        raise


def open_regular_file(path):
    parts = absolute_parts(path)
    if not parts:
        raise ValueError("a file path is required")
    parent_path = os.path.join(os.sep, *parts[:-1]) if len(parts) > 1 else os.sep
    parent_fd, canonical_parent = open_directory(parent_path)
    try:
        flags = os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK
        descriptor = os.open(parts[-1], flags, dir_fd=parent_fd)
        try:
            info = os.fstat(descriptor)
            if not stat.S_ISREG(info.st_mode):
                raise ValueError("path is not a regular file")
            canonical = os.path.join(canonical_parent, parts[-1])
            return descriptor, canonical, info
        except Exception:
            os.close(descriptor)
            raise
    finally:
        os.close(parent_fd)


def directory_is_beneath(root_fd, directory_fd):
    root_info = os.fstat(root_fd)
    root_identity = (root_info.st_dev, root_info.st_ino)
    current = os.dup(directory_fd)
    visited = set()
    try:
        while True:
            info = os.fstat(current)
            identity = (info.st_dev, info.st_ino)
            if identity == root_identity:
                return True
            if identity in visited:
                return False
            visited.add(identity)
            parent = os.open(
                "..",
                os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                dir_fd=current,
            )
            parent_info = os.fstat(parent)
            if (parent_info.st_dev, parent_info.st_ino) == identity:
                os.close(parent)
                return False
            os.close(current)
            current = parent
    finally:
        os.close(current)


def open_beneath(root_fd, request_target):
    parsed = urlsplit(request_target)
    if parsed.scheme or parsed.netloc:
        raise ValueError("absolute request targets are not accepted")
    decoded = unquote_to_bytes(parsed.path).decode("utf-8")
    if not decoded.startswith("/") or "\x00" in decoded or "\\" in decoded:
        raise ValueError("invalid request path")
    parts = decoded[1:].split("/")
    if not parts or any(part in ("", ".", "..") for part in parts):
        raise ValueError("invalid request path")

    parent_fd = os.dup(root_fd)
    try:
        directory_flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
        for part in parts[:-1]:
            child = os.open(part, directory_flags, dir_fd=parent_fd)
            os.close(parent_fd)
            parent_fd = child
        descriptor = os.open(
            parts[-1],
            os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK,
            dir_fd=parent_fd,
        )
        try:
            info = os.fstat(descriptor)
            if not stat.S_ISREG(info.st_mode):
                raise ValueError("path is not a regular file")
            return descriptor, info.st_size, parts[-1]
        except Exception:
            os.close(descriptor)
            raise
    finally:
        os.close(parent_fd)


class FeedHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.serve_file(True)

    def do_HEAD(self):
        self.serve_file(False)

    def serve_file(self, include_body):
        try:
            descriptor, size, filename = open_beneath(self.server.root_fd, self.path)
        except (OSError, UnicodeError, ValueError):
            self.send_error(404)
            return

        with os.fdopen(descriptor, "rb") as source:
            self.send_response(200)
            self.send_header(
                "Content-Type",
                mimetypes.guess_type(filename)[0] or "application/octet-stream",
            )
            self.send_header("Content-Length", str(size))
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.end_headers()
            if include_body:
                try:
                    while True:
                        chunk = source.read(1024 * 1024)
                        if not chunk:
                            break
                        self.wfile.write(chunk)
                except (BrokenPipeError, ConnectionResetError):
                    pass


class LoopbackHTTPServer(http.server.ThreadingHTTPServer):
    address_family = socket.AF_INET
    daemon_threads = True
    allow_reuse_address = True


def port_number(value):
    try:
        port = int(value)
    except ValueError as error:
        raise argparse.ArgumentTypeError("port must be an integer") from error
    if not 1 <= port <= 65535:
        raise argparse.ArgumentTypeError("port must be between 1 and 65535")
    return port


def main():
    parser = argparse.ArgumentParser(
        formatter_class=argparse.ArgumentDefaultsHelpFormatter
    )
    parser.add_argument("--root", required=True)
    parser.add_argument("--cert", required=True)
    parser.add_argument("--key", required=True)
    parser.add_argument(
        "--port", type=port_number, default=8443, help="listener port"
    )
    args = parser.parse_args()

    if not hasattr(os, "O_NOFOLLOW") or not hasattr(os, "O_DIRECTORY") or os.open not in os.supports_dir_fd:
        parser.error("this platform lacks the required no-follow directory operations")

    root_fd = None
    server = None
    try:
        root_fd, root_path = open_directory(args.root)
        if root_path == os.sep:
            raise ValueError("the filesystem root cannot be served")

        cert_fd, cert_path, _ = open_regular_file(args.cert)
        os.close(cert_fd)
        key_fd, key_path, key_info = open_regular_file(args.key)
        try:
            if stat.S_IMODE(key_info.st_mode) != 0o600 or key_info.st_nlink != 1:
                raise ValueError("the TLS private key must have mode 0600 and one link")
            key_parent_fd, _ = open_directory(os.path.dirname(key_path))
            try:
                if directory_is_beneath(root_fd, key_parent_fd):
                    raise ValueError("the TLS private key must be outside the served root")
            finally:
                os.close(key_parent_fd)
        finally:
            os.close(key_fd)

        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.minimum_version = ssl.TLSVersion.TLSv1_2
        context.load_cert_chain(certfile=cert_path, keyfile=key_path)

        server = LoopbackHTTPServer(("127.0.0.1", args.port), FeedHandler)
        server.root_fd = root_fd
        server.socket = context.wrap_socket(server.socket, server_side=True)
        print(
            "Serving https://127.0.0.1:{}/ from {} (loopback only)".format(
                server.server_address[1], root_path
            ),
            flush=True,
        )
        try:
            server.serve_forever()
        except KeyboardInterrupt:
            pass
    except (OSError, ValueError, ssl.SSLError) as error:
        parser.error(str(error))
    finally:
        if server is not None:
            server.server_close()
        if root_fd is not None:
            os.close(root_fd)


if __name__ == "__main__":
    main()
