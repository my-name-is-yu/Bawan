#!/usr/bin/env python3
import http.client
import os
import pathlib
import re
import shutil
import socket
import ssl
import subprocess
import sys
import tempfile
import time
import unittest


REPO = pathlib.Path(__file__).resolve().parents[1]
HELPER = REPO / "scripts" / "serve-test-feed.py"
RC_DOC = REPO / "docs" / "v2-release-candidate.md"
FEED_DOC = REPO / "docs" / "test-feed.md"
FENCE = re.compile(
    r"(?ms)^" + re.escape(chr(96) * 3) + r"sh[ \t]*\n(.*?)^"
    + re.escape(chr(96) * 3) + r"[ \t]*$"
)


def shell_blocks(path):
    return [match.group(1) for match in FENCE.finditer(path.read_text())]


def available_port():
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


def run_openssl(args):
    result = subprocess.run(
        ["openssl"] + args,
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    if result.returncode:
        raise RuntimeError(result.stderr)


class ReleaseShellIsolationTests(unittest.TestCase):
    def test_tls_generation_guard_stops_before_openssl(self):
        generation_blocks = [
            source
            for source in shell_blocks(FEED_DOC)
            if "openssl genpkey -algorithm RSA" in source and "test ! -e" in source
        ]
        self.assertEqual(len(generation_blocks), 1)
        generation = generation_blocks[0]

        for existing_name, sentinel in (
            ("ca.key", "existing private-key sentinel"),
            ("ca.crt", "existing CA-certificate sentinel"),
        ):
            with self.subTest(existing_name=existing_name):
                with tempfile.TemporaryDirectory() as temporary:
                    root = pathlib.Path(temporary)
                    tls = root / "tls"
                    tls.mkdir()
                    public = root / "public"
                    bin_dir = root / "bin"
                    bin_dir.mkdir()
                    existing_file = tls / existing_name
                    existing_file.write_text(sentinel)
                    marker = root / "openssl-called"
                    fake_openssl = bin_dir / "openssl"
                    fake_openssl.write_text(
                        "#!/bin/sh\n"
                        "printf '%s\\n' called > \"$OPENSSL_MARKER\"\n"
                        "exit 99\n"
                    )
                    fake_openssl.chmod(0o700)
                    environment = {
                        "PATH": "{}:{}".format(
                            bin_dir, os.environ.get("PATH", "/usr/bin:/bin")
                        ),
                        "TEST_ROOT": str(root),
                        "TLS": str(tls),
                        "PUBLIC": str(public),
                        "OPENSSL_MARKER": str(marker),
                    }
                    result = subprocess.run(
                        ["/bin/sh", "-c", generation],
                        env=environment,
                        text=True,
                        stdout=subprocess.PIPE,
                        stderr=subprocess.PIPE,
                    )
                    self.assertNotEqual(result.returncode, 0)
                    self.assertEqual(existing_file.read_text(), sentinel)
                    self.assertFalse(marker.exists())

    def test_documented_shell_and_release_environment(self):
        for path in (RC_DOC, FEED_DOC):
            for number, source in enumerate(shell_blocks(path), 1):
                checked = subprocess.run(
                    ["/bin/sh", "-n"],
                    input=source,
                    text=True,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                )
                self.assertEqual(
                    checked.returncode,
                    0,
                    "{} shell block {}: {}".format(path.name, number, checked.stderr),
                )

        build_blocks = [
            source
            for source in shell_blocks(RC_DOC)
            if "./scripts/release.sh" in source
        ]
        self.assertEqual(len(build_blocks), 3)

        with tempfile.TemporaryDirectory() as temporary:
            sandbox = pathlib.Path(temporary)
            scripts = sandbox / "scripts"
            scripts.mkdir()
            capture = sandbox / "release-env.txt"
            stub = scripts / "release.sh"
            stub.write_text(
                "#!/bin/sh\n"
                "set -eu\n"
                "printf '%s|%s|%s\\n' "
                "\"$BAWAN_BUILD_NUMBER\" "
                "\"$BAWAN_UPDATE_FEED_URL\" "
                "\"$BAWAN_UPDATE_DOWNLOAD_URL_PREFIX\" "
                ">> \"$CAPTURE_FILE\"\n"
            )
            stub.chmod(0o700)

            private_feed = "https://127.0.0.1:8443/private-parent/appcast.xml"
            private_prefix = "https://127.0.0.1:8443/private-parent/"
            command = "\n".join(build_blocks) + (
                "\ntest \"$BAWAN_BUILD_NUMBER\" = '2.0.1'\n"
                "test \"$BAWAN_UPDATE_FEED_URL\" = '{}'\n"
                "test \"$BAWAN_UPDATE_DOWNLOAD_URL_PREFIX\" = '{}'\n"
            ).format(private_feed, private_prefix)
            environment = {
                "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
                "CAPTURE_FILE": str(capture),
                "BAWAN_BUILD_NUMBER": "2.0.1",
                "BAWAN_UPDATE_FEED_URL": private_feed,
                "BAWAN_UPDATE_DOWNLOAD_URL_PREFIX": private_prefix,
            }
            result = subprocess.run(
                ["/bin/sh", "-eu", "-c", command],
                cwd=str(sandbox),
                env=environment,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
            self.assertEqual(result.returncode, 0, result.stderr)

            lines = capture.read_text().splitlines()
            expected = [
                "2.0.0|https://127.0.0.1:8443/appcast.xml|https://127.0.0.1:8443/baseline/",
                "2.0.1|https://127.0.0.1:8443/appcast.xml|https://127.0.0.1:8443/v2.0.0-rc.1/",
                "2.0.2|https://github.com/my-name-is-yu/Bawan/releases/latest/download/appcast.xml|https://github.com/my-name-is-yu/Bawan/releases/download/v2.0.0/",
            ]
            self.assertEqual(lines, expected)
            self.assertGreater(
                tuple(map(int, "2.0.2".split("."))),
                tuple(map(int, "2.0.1".split("."))),
            )
            self.assertNotIn("127.0.0.1", lines[2])
            self.assertNotIn("private-parent", lines[2])


class ServeTestFeedTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory()
        base = pathlib.Path(cls.temporary.name).resolve()
        cls.root = base / "public"
        cls.tls = base / "tls"
        cls.outside = base / "outside"
        cls.root.mkdir()
        cls.tls.mkdir()
        cls.outside.mkdir()
        cls.ca_key = cls.tls / "ca.key"
        cls.ca_cert = cls.tls / "ca.crt"
        cls.server_key = cls.tls / "server.key"
        cls.server_csr = cls.tls / "server.csr"
        cls.server_cert = cls.tls / "server.crt"
        extensions = cls.tls / "server-ext.cnf"

        run_openssl(
            [
                "req",
                "-x509",
                "-newkey",
                "rsa:2048",
                "-nodes",
                "-keyout",
                str(cls.ca_key),
                "-out",
                str(cls.ca_cert),
                "-days",
                "2",
                "-subj",
                "/CN=Bawan helper test CA",
                "-addext",
                "basicConstraints=critical,CA:TRUE",
                "-addext",
                "keyUsage=critical,keyCertSign,cRLSign",
            ]
        )
        run_openssl(
            [
                "req",
                "-newkey",
                "rsa:2048",
                "-nodes",
                "-keyout",
                str(cls.server_key),
                "-out",
                str(cls.server_csr),
                "-subj",
                "/CN=127.0.0.1",
            ]
        )
        extensions.write_text(
            "[server_ext]\n"
            "basicConstraints=critical,CA:FALSE\n"
            "keyUsage=critical,digitalSignature,keyEncipherment\n"
            "extendedKeyUsage=serverAuth\n"
            "subjectAltName=IP:127.0.0.1\n"
        )
        run_openssl(
            [
                "x509",
                "-req",
                "-in",
                str(cls.server_csr),
                "-CA",
                str(cls.ca_cert),
                "-CAkey",
                str(cls.ca_key),
                "-CAcreateserial",
                "-out",
                str(cls.server_cert),
                "-days",
                "2",
                "-sha256",
                "-extfile",
                str(extensions),
                "-extensions",
                "server_ext",
            ]
        )
        cls.ca_key.chmod(0o600)
        cls.server_key.chmod(0o600)
        cls.sample = cls.root / "arbitrary-owner-file.txt"
        cls.sample.write_text("fixture test file\n")
        cls.outside_secret = cls.outside / "secret.txt"
        cls.outside_secret.write_text("must not be exposed\n")
        (cls.root / "outside-link.txt").symlink_to(cls.outside_secret)
        (cls.root / "outside-directory").symlink_to(
            cls.outside, target_is_directory=True
        )

        cls.port = available_port()
        environment = {
            "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
            "PYTHONNOUSERSITE": "1",
        }
        cls.server = subprocess.Popen(
            [
                sys.executable,
                str(HELPER),
                "--root",
                str(cls.root),
                "--cert",
                str(cls.server_cert),
                "--key",
                str(cls.server_key),
                "--port",
                str(cls.port),
            ],
            env=environment,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            text=True,
        )
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            if cls.server.poll() is not None:
                error = cls.server.stderr.read()
                cls.temporary.cleanup()
                raise RuntimeError(error)
            try:
                with socket.create_connection(("127.0.0.1", cls.port), timeout=0.1):
                    break
            except OSError:
                time.sleep(0.05)
        else:
            cls.server.terminate()
            cls.server.wait(timeout=3)
            cls.temporary.cleanup()
            raise RuntimeError("test feed helper did not start")

    @classmethod
    def tearDownClass(cls):
        if getattr(cls, "server", None) is not None and cls.server.poll() is None:
            cls.server.terminate()
            cls.server.wait(timeout=5)
        cls.temporary.cleanup()

    def get(self, path):
        context = ssl.create_default_context(cafile=str(self.ca_cert))
        connection = http.client.HTTPSConnection(
            "127.0.0.1", self.port, context=context, timeout=3
        )
        connection.request("GET", path)
        response = connection.getresponse()
        status = response.status
        body = response.read()
        connection.close()
        return status, body

    def test_port_default_and_fixed_loopback_option(self):
        result = subprocess.run(
            [sys.executable, str(HELPER), "--help"],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        self.assertEqual(result.returncode, 0)
        self.assertIn("--port PORT", result.stdout)
        self.assertIn("default: 8443", result.stdout)
        self.assertNotIn("--bind", result.stdout)

    def test_tls_requires_explicit_ca_and_checks_host(self):
        default_context = ssl.create_default_context()
        raw = socket.create_connection(("127.0.0.1", self.port), timeout=3)
        with self.assertRaises(ssl.SSLCertVerificationError):
            default_context.wrap_socket(raw, server_hostname="127.0.0.1")

        status, body = self.get("/arbitrary-owner-file.txt")
        self.assertEqual(status, 200)
        self.assertEqual(body, b"fixture test file\n")

        trusted_context = ssl.create_default_context(cafile=str(self.ca_cert))
        raw = socket.create_connection(("127.0.0.1", self.port), timeout=3)
        with self.assertRaises(ssl.SSLCertVerificationError):
            trusted_context.wrap_socket(raw, server_hostname="wrong-host.example")

    def test_only_regular_root_files_are_served(self):
        status, body = self.get("/arbitrary-owner-file.txt")
        self.assertEqual(status, 200)
        self.assertEqual(body, b"fixture test file\n")
        self.assertEqual(self.get("/")[0], 404)
        self.assertEqual(self.get("/outside-link.txt")[0], 404)
        self.assertEqual(self.get("/outside-directory/secret.txt")[0], 404)
        self.assertEqual(self.get("/%2e%2e/outside/secret.txt")[0], 404)
        self.assertNotIn(b"must not be exposed", self.get("/outside-link.txt")[1])
        self.assertEqual(self.get("/server.key")[0], 404)

    def test_rejects_unsafe_root_and_private_key_configuration(self):
        root_alias = self.root.parent / "public-alias"
        root_alias.symlink_to(self.root, target_is_directory=True)
        result = subprocess.run(
            [
                sys.executable,
                str(HELPER),
                "--root",
                str(root_alias),
                "--cert",
                str(self.server_cert),
                "--key",
                str(self.server_key),
                "--port",
                str(available_port()),
            ],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        self.assertNotEqual(result.returncode, 0)

        unsafe_root = self.root.parent / "unsafe-public"
        unsafe_root.mkdir()
        key_in_root = unsafe_root / "private.pem"
        shutil.copyfile(self.server_key, key_in_root)
        key_in_root.chmod(0o600)
        result = subprocess.run(
            [
                sys.executable,
                str(HELPER),
                "--root",
                str(unsafe_root),
                "--cert",
                str(self.server_cert),
                "--key",
                str(key_in_root),
                "--port",
                str(available_port()),
            ],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("private key must be outside", result.stderr)
        key_in_root.unlink()

        weak_key = self.tls / "weak.key"
        shutil.copyfile(self.server_key, weak_key)
        weak_key.chmod(0o644)
        result = subprocess.run(
            [
                sys.executable,
                str(HELPER),
                "--root",
                str(self.root),
                "--cert",
                str(self.server_cert),
                "--key",
                str(weak_key),
                "--port",
                str(available_port()),
            ],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("mode 0600", result.stderr)


if __name__ == "__main__":
    unittest.main()
