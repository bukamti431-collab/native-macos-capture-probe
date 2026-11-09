"""Emit only validated, unauthenticated native-probe files into normal job logs."""
import base64
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import re
import stat
import struct
import sys

ALLOWED_FILES = ('macos-version.txt', 'window-probe.json', 'capture-metadata.json',
                 'native-desktop.png', 'native-telegram-window.png')
MAX_PNG_BYTES = 6 * 1024 * 1024
MAX_TOTAL_BYTES = 14 * 1024 * 1024
MAX_JSON_BYTES = 64 * 1024
BUNDLE = 'ru.keepcoder.Telegram'
SCOPE = ('Unauthenticated genuine app/desktop probe; welcome/login screen only. '
         'Not evidence of an authenticated bot chat.')


def require(condition):
    if not condition:
        raise ValueError('Diagnostic validation rejected')


def parse_json(data):
    def unique(pairs):
        result = {}
        for key, value in pairs:
            require(key not in result)
            result[key] = value
        return result
    def invalid_constant(_value):
        raise ValueError('Non-finite JSON value rejected')
    result = json.loads(data.decode('utf-8'), object_pairs_hook=unique,
                        parse_constant=invalid_constant)
    require(type(result) is dict)
    return result


def finite_number(value):
    return type(value) in (int, float) and math.isfinite(value)


def prepare_diagnostics(directory):
    directory = Path(directory)
    require(directory.is_dir() and not directory.is_symlink())
    files = {}
    for name in ALLOWED_FILES:
        path = directory / name
        info = path.lstat()
        limit = MAX_PNG_BYTES if name.endswith('.png') else MAX_JSON_BYTES if name.endswith('.json') else 4096
        require(stat.S_ISREG(info.st_mode) and 0 < info.st_size <= limit)
        files[name] = path.read_bytes()
        require(len(files[name]) == info.st_size)
    require(sum(map(len, files.values())) <= MAX_TOTAL_BYTES)

    version = files['macos-version.txt'].decode('utf-8').replace('\r\n', '\n')
    require(re.fullmatch(r'ProductName:\s+macOS\nProductVersion:\s+26(?:\.\d+){1,2}\nBuildVersion:\s+[A-Za-z0-9]+\n?', version) is not None)
    metadata = parse_json(files['capture-metadata.json'])
    require(set(metadata) == {'capture_completed', 'native_macos_application', 'native_bundle_identifier',
        'scope', 'telegram_login_attempted', 'telegram_messages_sent', 'ui_reconstruction',
        'image_compositing', 'visual_review_required', 'screenshots'})
    for key in ('capture_completed', 'native_macos_application', 'visual_review_required'):
        require(metadata[key] is True)
    for key in ('telegram_login_attempted', 'ui_reconstruction', 'image_compositing'):
        require(metadata[key] is False)
    require(type(metadata['telegram_messages_sent']) is int and metadata['telegram_messages_sent'] == 0)
    require(metadata['native_bundle_identifier'] == BUNDLE and metadata['scope'] == SCOPE)
    shots = metadata['screenshots']
    require(type(shots) is list and len(shots) == 2)
    require([item.get('file') for item in shots if type(item) is dict] == list(ALLOWED_FILES[-2:]))
    for item in shots:
        require(set(item) == {'file', 'sha256', 'dimensions', 'pixel_edits'} and item['pixel_edits'] is False)
        data = files[item['file']]
        require(len(data) >= 33 and data[:8] == b'\x89PNG\r\n\x1a\n' and data[8:16] == b'\0\0\0\rIHDR')
        dimensions = list(struct.unpack('>II', data[16:24]))
        require(200 <= dimensions[0] <= 16384 and 160 <= dimensions[1] <= 16384)
        require(item['dimensions'] == dimensions and item['sha256'] == hashlib.sha256(data).hexdigest())

    probe = parse_json(files['window-probe.json'])
    require(set(probe) == {'bundle_identifier', 'expected_application_running', 'frontmost_bundle_identifier',
        'screen_capture_preflight', 'screens', 'target_window_count', 'target_pid', 'window_id', 'window_bounds'})
    require(probe['bundle_identifier'] == BUNDLE and probe['frontmost_bundle_identifier'] == BUNDLE)
    require(probe['expected_application_running'] is True and type(probe['screen_capture_preflight']) is bool)
    for key in ('target_window_count', 'target_pid', 'window_id'):
        require(type(probe[key]) is int and probe[key] > 0)
    bounds = probe['window_bounds']
    require(type(bounds) is dict and set(bounds) == {'X', 'Y', 'Width', 'Height'})
    require(all(finite_number(value) for value in bounds.values()) and bounds['Width'] >= 200 and bounds['Height'] >= 160)
    require(type(probe['screens']) is list and 1 <= len(probe['screens']) <= 8)
    for screen in probe['screens']:
        require(type(screen) is dict and set(screen) == {'frame_points', 'backing_scale_factor'})
        frame = screen['frame_points']
        require(type(frame) is list and len(frame) == 4 and all(finite_number(v) for v in frame))
        require(finite_number(screen['backing_scale_factor']) and screen['backing_scale_factor'] > 0)
    return [{'file': name, 'bytes': len(data), 'sha256': hashlib.sha256(data).hexdigest(), 'data': data}
            for name, data in files.items()]


def emit_diagnostics(directory, stream=sys.stdout):
    records = prepare_diagnostics(directory)  # Validate every byte before any output.
    print('NATIVE_DIAGNOSTICS_V1_BEGIN', file=stream)
    for record in records:
        header = {key: record[key] for key in ('file', 'bytes', 'sha256')}
        header['encoding'] = 'base64'
        print('NATIVE_DIAGNOSTICS_FILE_BEGIN ' + json.dumps(header, separators=(',', ':')), file=stream)
        data = record['data']
        for offset in range(0, len(data), 90):
            print(base64.b64encode(data[offset:offset + 90]).decode('ascii'), file=stream)
        print('NATIVE_DIAGNOSTICS_FILE_END ' + json.dumps({'file': record['file']}, separators=(',', ':')), file=stream)
    print('NATIVE_DIAGNOSTICS_V1_END ' + json.dumps({'files': len(records),
        'total_bytes': sum(record['bytes'] for record in records)}, separators=(',', ':')), file=stream)


def main():
    if platform.system() != 'Darwin' or os.environ.get('GITHUB_ACTIONS') != 'true' or os.environ.get('RUNNER_ENVIRONMENT') != 'github-hosted':
        print('NATIVE_DIAGNOSTICS_V1_REJECTED unsupported_host', file=sys.stderr)
        return 2
    temporary = os.environ.get('RUNNER_TEMP', '')
    if not temporary:
        print('NATIVE_DIAGNOSTICS_V1_REJECTED missing_runner_temp', file=sys.stderr)
        return 2
    directory = Path(temporary) / 'native-macos-capture' / 'artifacts'
    try:
        require(not directory.parent.is_symlink())
        require(directory.resolve().is_relative_to(Path(temporary).resolve()))
        emit_diagnostics(directory)
    except Exception:
        print('NATIVE_DIAGNOSTICS_V1_REJECTED invalid_diagnostics', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
