"""Run on Linux: python3 -m unittest discover -s tests -v.

All writes stay in temporary directories. No installer entry point is run.
"""
import io
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tarfile
import tempfile
import unittest
import sys


SOURCE = (Path(__file__).resolve().parents[1] / 'archi.sh').read_text()
FUNCTIONS = SOURCE[:SOURCE.rindex('\nif is_install_environment; then')]


class Regressions(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.env = dict(os.environ, TEST_ROOT=str(self.root), TMPDIR=str(self.root))

    def shell(self, code):
        return subprocess.run(['sh', '-c', FUNCTIONS + '\n' + code],
                              env=self.env, text=True, capture_output=True, timeout=20)

    def test_download_failure_keeps_previous_file_and_removes_partial(self):
        for status, content in [(28, 'partial'), (0, 'x')]:
            with self.subTest(status=status):
                target = self.root / 'kernel'
                target.write_text('previous')
                result = self.shell('''
curl() {
    while [ "$1" != --output ]; do shift; done
    printf '%s' CONTENT > "$2"
    return STATUS
}
download_file https://example.invalid/kernel "$TEST_ROOT/kernel" 5
'''.replace('CONTENT', shlex.quote(content)).replace('STATUS', str(status)))
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(target.read_text(), 'previous')
                self.assertFalse((self.root / 'kernel.part').exists())

    def test_download_success_replaces_file(self):
        result = self.shell('''
curl() {
    while [ "$1" != --output ]; do shift; done
    printf 'complete' > "$2"
}
download_file https://example.invalid/kernel "$TEST_ROOT/kernel" 5
''')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.root / 'kernel').read_text(), 'complete')
        self.assertFalse((self.root / 'kernel.part').exists())

    def test_interrupted_download_stops_child_and_removes_partial(self):
        executable = self.root / 'curl'
        executable.write_text(f'#!{sys.executable}\n' + '''import os, pathlib, sys, time
root = pathlib.Path(os.environ['TEST_ROOT'])
pathlib.Path(sys.argv[sys.argv.index('--output') + 1]).write_text('partial')
(root / 'curl.pid').write_text(str(os.getpid()))
time.sleep(30)
''')
        executable.chmod(0o755)
        self.env['PATH'] = str(self.root) + os.pathsep + os.environ['PATH']
        result = self.shell('''
download_file_worker https://example.invalid/kernel "$TEST_ROOT/kernel" 5 &
worker=$!
for attempt in 1 2 3 4 5; do
    [ ! -f "$TEST_ROOT/curl.pid" ] || break
    sleep 0.1
done
kill -TERM "$worker"
wait "$worker"
''')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / 'kernel.part').exists())
        with self.assertRaises(ProcessLookupError):
            os.kill(int((self.root / 'curl.pid').read_text()), 0)

    def test_build_failure_preserves_previous_stage(self):
        result = self.shell('''
install_dir=$TEST_ROOT/install
stage_work=$TEST_ROOT/work
mkdir "$install_dir" "$stage_work"
printf old > "$install_dir/kernel"
printf old > "$TEST_ROOT/custom.cfg"
trap stage_exit 0
exit 9
''')
        self.assertEqual(result.returncode, 9, result.stderr)
        self.assertEqual((self.root / 'install/kernel').read_text(), 'old')
        self.assertEqual((self.root / 'custom.cfg').read_text(), 'old')
        self.assertFalse((self.root / 'work').exists())

    def test_stage_rollback_and_commit(self):
        for previous, committed in [(True, False), (False, False), (True, True)]:
            with self.subTest(previous=previous, committed=committed):
                case = self.root / f'{previous}-{committed}'
                case.mkdir()
                self.env['TEST_ROOT'] = str(case)
                result = self.shell('''
install_dir=$TEST_ROOT/install
stage_work=$TEST_ROOT/work
stage_backup=$TEST_ROOT/backup
custom_cfg=$TEST_ROOT/custom.cfg
mkdir -p "$install_dir" "$stage_work" "$stage_backup"
printf new > "$install_dir/kernel"
printf new > "$custom_cfg"
PREVIOUS
stage_published=true custom_changed=true stage_committed=COMMITTED
trap stage_exit 0
exit 7
'''.replace('PREVIOUS', '''mkdir "$stage_backup/payload"
printf old > "$stage_backup/payload/kernel"
printf old > "$stage_backup/custom.cfg"''' if previous else ':')
                    .replace('COMMITTED', str(committed).lower()))
                self.assertEqual(result.returncode, 7, result.stderr)
                if committed or previous:
                    expected = 'new' if committed else 'old'
                    self.assertEqual((case / 'install/kernel').read_text(), expected)
                    self.assertEqual((case / 'custom.cfg').read_text(), expected)
                else:
                    self.assertFalse((case / 'install').exists())
                    self.assertFalse((case / 'custom.cfg').exists())
                self.assertFalse((case / 'work').exists())
                self.assertFalse((case / 'backup').exists())

    def test_initramfs_checks_selected_kernel_and_rebuild_result(self):
        boot = self.root / 'boot'
        boot.mkdir()
        (boot / 'initramfs-linux.img').write_text('unrelated')
        mock = self.root / 'arch-chroot'
        self.env['PATH'] = str(self.root) + os.pathsep + os.environ['PATH']
        for rebuild in ['return 1', ':', 'printf image > "$1/boot/initramfs-linux-lts.img"']:
            mock.write_text('#!/bin/sh\n' + rebuild + '\n')
            mock.chmod(0o755)
            result = self.shell('ensure_target_initramfs "$TEST_ROOT" linux-lts')
            self.assertEqual(result.returncode == 0, rebuild.startswith('printf'), result.stderr)
        (boot / 'initramfs-linux-lts.img').unlink()
        mock.write_text('#!/bin/sh\nexit 99\n')
        result = self.shell('ensure_target_initramfs "$TEST_ROOT" linux-lts')
        self.assertNotEqual(result.returncode, 0, result.stderr)

    def test_install_retry_reuses_target_cache(self):
        # Exercise the installer's actual retry block with a fake pacstrap.
        # Model its documented -c behavior and fail after the first download.
        start = SOURCE.index('    log "Installing base packages: $*"')
        end = SOURCE.index('    chmod 0755 /mnt/etc', start)
        retry = SOURCE[start:end].replace('/mnt', '${TEST_ROOT}/target')
        result = self.shell('''
pacstrap() {
    cache=$TEST_ROOT/host-cache
    if [ "$1" = -K ]; then shift; fi
    if [ "$1" = -c ]; then
        shift
    else
        cache=$1/var/cache/pacman/pkg
    fi
    shift
    [ "$*" = 'base linux-lts' ] || return 99
    mkdir -p "$cache"
    if [ ! -f "$cache/package" ]; then
        printf downloaded > "$cache/package"
        return 1
    fi
    printf reused > "$TEST_ROOT/retry-result"
}
killall() { :; }
sleep() { :; }
set -- base linux-lts
''' + retry)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.root / 'host-cache').exists())
        self.assertEqual((self.root / 'target/var/cache/pacman/pkg/package').read_text(),
                         'downloaded')
        self.assertEqual((self.root / 'retry-result').read_text(), 'reused')

    @unittest.skipUnless(shutil.which('pacman'), 'requires pacman')
    def test_real_pacman_resolves_dependencies_and_rejects_missing_packages(self):
        # A tiny local repository exercises the real resolver without downloads
        # or installing anything. Signature checks are disabled only in this fixture.
        repo = self.root / 'repo'
        repo.mkdir()
        with tarfile.open(repo / 'fixture.db', 'w:gz') as archive:
            for name, dependencies in [('app', 'libfixture'), ('libfixture', ''),
                                       ('broken', 'absent-dependency')]:
                desc = (f'%NAME%\n{name}\n\n%VERSION%\n1-1\n\n%ARCH%\nx86_64\n\n'
                        f'%FILENAME%\n{name}-1-1-x86_64.pkg.tar.zst\n\n'
                        '%CSIZE%\n1\n\n%ISIZE%\n1\n\n')
                if dependencies:
                    desc += f'%DEPENDS%\n{dependencies}\n\n'
                data = desc.encode()
                entry = tarfile.TarInfo(f'{name}-1-1/desc')
                entry.size = len(data)
                archive.addfile(entry, io.BytesIO(data))
        config = self.root / 'pacman.conf'
        config.write_text('[options]\nArchitecture = x86_64\nSigLevel = Never\n'
                          f'[fixture]\nServer = file://{repo}\n')
        for package, succeeds in [('app', True), ('typo', False), ('broken', False)]:
            with self.subTest(package=package):
                result = self.shell('''
pacman() { command pacman --config "$TEST_ROOT/pacman.conf" "$@"; }
preflight_packages PACKAGE
printf reached > "$TEST_ROOT/after-preflight"
'''.replace('PACKAGE', package))
                self.assertEqual(result.returncode == 0, succeeds, result.stderr)
                marker = self.root / 'after-preflight'
                self.assertEqual(marker.exists(), succeeds)
                marker.unlink(missing_ok=True)
                if succeeds:
                    self.assertIn('libfixture 1-1', result.stdout)


if __name__ == '__main__':
    unittest.main()
