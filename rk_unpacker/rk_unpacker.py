#!/usr/bin/env python3
"""
Rockchip Android Update.img Unpacker
Extracts partition images from Rockchip firmware update files

Partition Entry Structure (0x70 bytes):
  +0x00: Partition name (32 bytes, null-terminated string)
  +0x20: Filename (64 bytes, null-terminated string)
  +0x60: Metadata (16 bytes):
    - DWORD[8]:  GPT size (in bytes)
    - DWORD[8]:  File offset (relative to RKAF header, in bytes)
    - DWORD[9]:  GPT start offset (in bytes)
    - DWORD[10]: Flags/attributes (???)
    - DWORD[11]: Size (in bytes)
"""

import struct
import sys
import os
import mmap
from pathlib import Path

class RKFWHeader:
    """RKFW Main Header Parser"""
    def __init__(self, data):
        self.magic = data[0:4].decode('ascii', errors='ignore')
        self.head_len = struct.unpack('<H', data[4:6])[0]
        self.version = f"{data[9]}.{data[10]}"
        self.model = ''.join(reversed(data[0x15:0x1a].decode('utf-8', errors='ignore')))

        self.loader_size = struct.unpack('<I', data[0x1D:0x21])[0]
        self.rkaf_offset = struct.unpack('<I', data[0x21:0x25])[0]
        self.image_size = struct.unpack('<I', data[0x25:0x29])[0]

    def is_valid(self):
        return self.magic == 'RKFW'

class RKAFHeader:
    """RKAF Header Parser"""
    def __init__(self, data, offset):
        self.offset = offset
        self.magic = data[offset:offset+4].decode('ascii', errors='ignore')
        self.size = struct.unpack('<I', data[offset+4:offset+8])[0]
        self.model = data[offset+8:offset+42].decode('utf-8', errors='ignore').strip('\x00')

    def is_valid(self):
        return self.magic == 'RKAF'

class PartitionEntry:
    """Partition Entry Parser"""
    ENTRY_SIZE = 0x70

    def __init__(self, data, offset):
        self.raw_offset = offset

        # Name: 32-byte field, ASCII-ish, trimmed
        raw_name = data[offset:offset+32]
        self.name = raw_name.split(b'\x00', 1)[0].decode('utf-8', errors='ignore').strip()

        # Filename: next 32 (64?) bytes, trimmed
        raw_fname = data[offset+0x20:offset+0x20+64]
        self.filename = raw_fname.split(b'\x00', 1)[0].decode('utf-8', errors='ignore').strip()

        # Tail 48 bytes -> 12 DWORDs
        tail_offset_48 = offset + self.ENTRY_SIZE - 48
        self.tail_dwords = []
        for i in range(12):
            dword_offset = tail_offset_48 + (i * 4)
            self.tail_dwords.append(struct.unpack('<I', data[dword_offset:dword_offset+4])[0])

        self.gpt_size        = self.tail_dwords[7]
        self.file_offset     = self.tail_dwords[8]
        self.gpt_offset      = self.tail_dwords[9]
        self.flags           = self.tail_dwords[10]
        self.size            = self.tail_dwords[11]

    @staticmethod
    def _is_printable_ascii(s: str) -> bool:
        if not s:
            return False
        return all(32 <= ord(c) < 127 for c in s) and (s[0].isalpha() or s[0] == '#')

    def is_valid(self, rkaf_size):
        if not self._is_printable_ascii(self.name):
            return False
        if self.size in (0, 0xFFFFFFFF):
            return False
        if self.file_offset == 0 or self.file_offset >= rkaf_size:
            return False
        return True

    def __repr__(self):
        return (f"Partition(name='{self.name}', file='{self.filename}', "
                f"offset=0x{self.file_offset:08x}, size={self.size})")

class RKUpdateImage:
    """Rockchip Update Image Parser"""

    def __init__(self, filepath):
        self.filepath = filepath
        self.rkfw_header = None
        self.rkaf_header = None
        self.rkaf_offset = 0
        self.partitions = []
        self.mm = None
        self.file_size = 0

        f = open(filepath, 'rb')
        self.file = f
        self.file_size = os.fstat(f.fileno()).st_size
        self.mm = mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ)

        self.gpt_report_lines: list[str] = []

        self.parse()

    def parse(self):
        """Parse the update image"""
        self.rkfw_header = RKFWHeader(self.mm)
        if self.rkfw_header.is_valid():
            print(f"[+] RKFW Header")
            print(f"    Model:       {self.rkfw_header.model}")
            print(f"    Version:     {self.rkfw_header.version}")
            print(f"    Header Size: {self.rkfw_header.head_len} bytes")
            print(f"    Loader Size: {self.rkfw_header.loader_size} bytes")
            print(f"    RKAF Offset: 0x{self.rkfw_header.rkaf_offset:08x}")
            print(f"    RKAF Size:  {self.rkfw_header.image_size} bytes")

            self.rkaf_offset = self.rkfw_header.rkaf_offset
        else:
            self.rkaf_offset = -1

        if self.rkaf_offset == -1:
            raise ValueError("RKAF header not found")

        self.rkaf_header = RKAFHeader(self.mm, self.rkaf_offset)
        if not self.rkaf_header.is_valid():
            raise ValueError("Invalid RKAF header")

        print(f"\n[+] RKAF Header at offset 0x{self.rkaf_offset:08x}")
        print(f"    Model: {self.rkaf_header.model}")
        print(f"    Size:  {self.rkaf_header.size} bytes")

        self._parse_partition_table()

    def _parse_partition_table(self):
        """Parse partition table entries"""
        # First real entry is at RKAF + 0x8C
        table_offset = self.rkaf_offset + 0x8C

        print(f"\n[+] Parsing partition table at RKAF+0x8C (0x{table_offset:08x})...")

        while table_offset + PartitionEntry.ENTRY_SIZE <= self.file_size:
            entry = PartitionEntry(self.mm, table_offset)

            if not entry.is_valid(self.rkaf_header.size):
                table_offset += PartitionEntry.ENTRY_SIZE
                continue

            self.partitions.append(entry)

            abs_offset = self.rkaf_offset + entry.file_offset

            print(f"    [{len(self.partitions):2d}] {entry.name:<20s} "
                  f"size: {entry.size:10d} bytes "
                  f"@ 0x{abs_offset:08x} "
                  f"(gpt_off: 0x{entry.gpt_offset:08x}, gpt_sz: 0x{entry.gpt_size:08x}, flags: 0x{entry.flags:08x})")

            table_offset += PartitionEntry.ENTRY_SIZE

            if entry.name == 'super':
                break

        print(f"\n[+] Found {len(self.partitions)} partitions")

    def list_partitions(self):
        """List all partitions in a table, including GPT mapping info"""
        print(f"\n{'#':<4} {'Name':<20} {'Filename':<32} {'Size':<12} {'FileOff':<10} {'GPTOff':<10} {'GPTSize':<10} {'Flags':<10}")
        print("=" * 120)

        self.gpt_report_lines = []
        header_line = "# idx name size file_offset gpt_offset gpt_size flags filename"
        self.gpt_report_lines.append(header_line)

        for i, entry in enumerate(self.partitions, 1):
            abs_offset = self.rkaf_offset + entry.file_offset
            print(f"{i:<4} {entry.name:<20} {entry.filename:<32} "
                  f"{entry.size:<12} 0x{abs_offset:08x} 0x{entry.gpt_offset:08x} 0x{entry.gpt_size:08x} 0x{entry.flags:08x}")
            self.gpt_report_lines.append(
                f"{i} {entry.name} {entry.size} 0x{abs_offset:08x} 0x{entry.gpt_offset:08x} 0x{entry.gpt_size:08x} 0x{entry.flags:08x} {entry.filename}"
            )

    def extract_all(self, output_dir='extracted'):
        """Extract all partitions"""
        base_output = Path(output_dir)
        files_dir = base_output / "files"
        parts_dir = base_output / "parts"
        files_dir.mkdir(parents=True, exist_ok=True)
        parts_dir.mkdir(parents=True, exist_ok=True)

        print(f"\n[+] Extracting content to: {files_dir}")

        # Extract loader if present
        if self.rkfw_header and self.rkfw_header.loader_size > 0:
            loader_file = base_output / "loader.bin"
            print(f"    Extracting loader -> {loader_file}")
            try:
                with open(loader_file, 'wb') as f:
                    self.file.seek(self.rkfw_header.head_len)
                    chunk_size = 1024 * 1024
                    remaining = self.rkfw_header.loader_size
                    while remaining > 0:
                        to_read = min(remaining, chunk_size)
                        chunk = self.file.read(to_read)
                        if not chunk: break
                        f.write(chunk)
                        remaining -= len(chunk)
                        del chunk
                print(f"        OK ({self.rkfw_header.loader_size} bytes)")
            except Exception as e:
                print(f"        ERROR: {e}")

        # Ensure GPT report is ready; if list_partitions wasn't called, build it now
        if not self.gpt_report_lines:
            self.list_partitions()

        for entry in self.partitions:
            self._extract_partition(entry, files_dir, parts_dir)

        # Write GPT mapping report
        report_path = base_output / "partitions.txt"
        try:
            with open(report_path, "w", encoding="utf-8") as f:
                for line in self.gpt_report_lines:
                    f.write(line + "\n")
            print(f"\n[+] Wrote GPT mapping report to {report_path}")
        except OSError as e:
            print(f"\n[!] Failed to write GPT mapping report: {e}")

        print(f"\n[+] Extraction complete!")

    def extract_partition_by_name(self, name, output_file=None):
        """Extract a specific partition by name"""
        for entry in self.partitions:
            if entry.name == name:
                if output_file:
                    # when explicit file is requested, just write the file, no symlink tree
                    output_path = Path(output_file).parent
                    output_path.mkdir(parents=True, exist_ok=True)
                    dest_dir = output_path
                    dest_name = Path(output_file).name
                    self._extract_partition(entry, dest_dir, None, dest_name)
                else:
                    base_output = Path(".")
                    files_dir = base_output / "files"
                    parts_dir = base_output / "parts"
                    files_dir.mkdir(parents=True, exist_ok=True)
                    parts_dir.mkdir(parents=True, exist_ok=True)
                    self._extract_partition(entry, files_dir, parts_dir)
                return True

        print(f"[-] Partition '{name}' not found")
        return False

    def _extract_partition(self, entry, files_dir: Path, parts_dir: Path | None, filename: str | None = None):
        """Extract a single partition; optionally create a symlink in parts_dir"""
        if filename is None:
            filename = entry.filename.replace('/', '_') or f"{entry.name}.img"

        output_file = files_dir / filename
        abs_offset = self.rkaf_offset + entry.file_offset

        print(f"    Extracting {entry.name:<20s} -> {output_file}")

        try:
            if abs_offset + entry.size > self.file_size:
                print(f"        ERROR: Offset 0x{abs_offset:08x} + size {entry.size} "
                      f"exceeds file size {self.file_size}")
                return

            with open(output_file, 'wb') as f:
                # Use standard file I/O instead of mmap for extraction to avoid
                # increasing process RSS (Resident Set Size) as pages are faulted in.
                chunk_size = 16 * 1024 * 1024  # 16 MB
                remaining = entry.size

                # Seek on the underlying file object
                self.file.seek(abs_offset)

                while remaining > 0:
                    to_read = min(remaining, chunk_size)
                    chunk = self.file.read(to_read)
                    if not chunk:
                        break
                    f.write(chunk)
                    remaining -= len(chunk)
                    del chunk

            print(f"        OK ({entry.size} bytes)")

            # Create symlink under parts_dir if requested, but skip when GPTSize (DWORD[9]) is 0xFFFFFFFF
            if parts_dir is not None and entry.gpt_size != 0xFFFFFFFF:
                link_name = parts_dir / entry.name
                try:
                    if link_name.exists() or link_name.is_symlink():
                        link_name.unlink()
                    # Use relative path from parts_dir to files_dir/file
                    target_rel = os.path.relpath(output_file, parts_dir)
                    os.symlink(target_rel, link_name)
                except OSError as e:
                    print(f"        WARN: cannot create symlink {link_name} -> {output_file}: {e}")
        except Exception as e:
            print(f"        ERROR: {e}")

def main():
    if len(sys.argv) < 2:
        print("Rockchip Update.img Unpacker")
        print("\nUsage: python rk_unpacker.py <update.img> [options]")
        print("\nOptions:")
        print("  -l, --list              List all partitions")
        print("  -x, --extract           Extract all partitions")
        print("  -p, --partition NAME    Extract specific partition")
        print("  -o, --output PATH       Output directory or file")
        print("\nExamples:")
        print("  python rk_unpacker.py update.img --list")
        print("  python rk_unpacker.py update.img --extract -o extracted/")
        print("  python rk_unpacker.py update.img --partition boot_a -o boot_a.img")
        sys.exit(1)
    image_file = sys.argv[1]
    if not os.path.exists(image_file):
        print(f"[-] Error: File '{image_file}' not found")
        sys.exit(1)
    try:
        img = RKUpdateImage(image_file)
    except Exception as e:
        print(f"[-] Error parsing image: {e}")
        sys.exit(1)
    if len(sys.argv) == 2 or '--list' in sys.argv or '-l' in sys.argv:
        img.list_partitions()
    if '--extract' in sys.argv or '-x' in sys.argv:
        output_dir = 'extracted'
        if '--output' in sys.argv:
            idx = sys.argv.index('--output')
            if idx + 1 < len(sys.argv):
                output_dir = sys.argv[idx + 1]
        elif '-o' in sys.argv:
            idx = sys.argv.index('-o')
            if idx + 1 < len(sys.argv):
                output_dir = sys.argv[idx + 1]
        img.extract_all(output_dir)
    if '--partition' in sys.argv or '-p' in sys.argv:
        if '--partition' in sys.argv:
            idx = sys.argv.index('--partition')
        else:
            idx = sys.argv.index('-p')
        if idx + 1 < len(sys.argv):
            partition_name = sys.argv[idx + 1]
            output_file = None
            if '--output' in sys.argv:
                idx = sys.argv.index('--output')
                if idx + 1 < len(sys.argv):
                    output_file = sys.argv[idx + 1]
            elif '-o' in sys.argv:
                idx = sys.argv.index('-o')
                if idx + 1 < len(sys.argv):
                    output_file = sys.argv[idx + 1]
            img.extract_partition_by_name(partition_name, output_file)

if __name__ == '__main__':
    main()
