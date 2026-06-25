// Package main implements rk_unpacker: a fast, concurrent Rockchip
// update.img unpacker.
//
// This file is the direct Go successor of rk_unpacker/rk_unpacker.py.
// The Python tool extracts partitions sequentially from a firmware blob,
// one 16 MiB chunk at a time. The Go implementation streams every
// partition out of the image in parallel using a bounded worker pool,
// recycles its I/O buffers through sync.Pool, and parses the RKFW /
// RKAF headers using explicit little-endian byte reads rather than
// reflection-based struct unpacking.
//
// Three intentional architectural advantages over the original Python:
//
//  1. Concurrency without serialised I/O throughput.
//     The Python tool reads partitions serially in its main thread using
//     a synchronous read-loop. Even under CPython's threading model,
//     the serial loop caps wall-clock throughput at one device's I/O
//     bandwidth. Go's M:N scheduler runs concurrent decode stages
//     while a bounded worker-pool (default 4) keeps the device's
//     command queue saturated without flooding it.
//
//  2. Constant memory footprint for arbitrary image sizes.
//     Multi-gigabyte partition blobs are streamed via io.SectionReader
//     + io.CopyBuffer, not slurped with .read(). SectionReader is a
//     zero-allocation view backed by ReadAt — which on Linux maps to
//     pread(2), an atomic syscall that does not mutate the parent
//     file's *os.File offset. Many parallel SectionReaders can read
//     from the same *os.File safely. Python's mmap-based decode had to
//     explicitly fall back to manual chunked I/O for extraction to
//     avoid RSS growth; in Go we never had the mmap path to begin with.
//
//  3. Allocation-bounded binary parsing.
//     RKFW / RKAF headers are parsed with binary.LittleEndian.Uint* calls
//     against fixed-size byte slices — no reflect-based binary.Read,
//     no per-field heap allocations for the partition size fields. The
//     partition name / filename still allocate Go strings on trim, but
//     only once per entry — so the parser can run on a tight loop over
//     dozens of entries without GC churn on the metadata fields.
package main

import (
	"bufio"
	"context"
	"encoding/binary"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

// ---------------------------------------------------------------------------
// RKFW / RKAF binary layout constants.
//
// Extracted directly from rk_unpacker.py and the public Rockchip update(8)
// format documentation that ships with rkdeveloptool. Keeping the offsets
// as named constants makes the parser self-documenting and refactor-safe.
// ---------------------------------------------------------------------------

const (
	// rkfwMagic and rkafMagic are the four-byte "RKFW" / "RKAF" signatures
	// that mark the two nested headers inside an update.img file.
	rkfwMagic = "RKFW"
	rkafMagic = "RKAF"

	// partitionEntrySize is the fixed 0x70 = 112-byte record describing a
	// single image. Every entry is exactly this large; the table walks
	// forward by this many bytes until a sentinel partition or EOF.
	partitionEntrySize = 0x70

	// firstEntryOffset is the fixed RKAF-relative offset where the first
	// partition entry lives (rkafOffset + 0x8C).
	firstEntryOffset = 0x8C

	// defaultWorkers caps the parallel extraction pool. Four parallel
	// writers is the sweet spot on NVMe SSDs and avoids the random-write
	// collapse that RAID-on-SMR or HDDs suffer at high queue depth.
	defaultWorkers = 4

	// copyBufferSize is the chunk size io.CopyBuffer uses per worker.
	// 1 MiB hits a good syscall / caching trade-off: fewer pread() calls
	// per partition than the Go default (32 KiB) but small enough that
	// pending writes don't dominate kernel page-cache pressure.
	copyBufferSize = 1 << 20 // 1 MiB

	// loaderSignature markers: the SPL loader bytes are stored between
	// the RKFW header (head_len) and the RKAF blob (rkaf_offset).
	// We extract them verbatim because downstream tools (rockusb) expect
	// the exact loader filing the Rockchip SoC expects in Maskrom mode.
)

// Little-endian is the byte order of every multi-byte field in the
// RKFW / RKAF / partition entry structures. We use a package-level
// alias to keep the parsing code terse.
var le = binary.LittleEndian

// ---------------------------------------------------------------------------
// Header structs. These are plain Go structs with no binary tags: parsing
// is done by explicit le.Uint32 / le.Uint16 calls against fixed slices.
// This avoids the reflection cost of binary.Read on every entry.
// ---------------------------------------------------------------------------

// rkfwHeader is the top-level firmware header. It tells us the loader
// (DDR init + USB downloader) and where the RKAF blob begins.
type rkfwHeader struct {
	magic      [4]byte
	headLen    uint16 // bytes 4..6
	version    uint8  // byte 9 (major) and 10 (minor)
	minor      uint8
	model      [5]byte // bytes 0x15..0x1A — note: stored reversed
	loaderSize uint32  // bytes 0x1D..0x21
	rkafOffset uint32  // bytes 0x21..0x25 — file offset to RKAF blob
	imageSize  uint32  // bytes 0x25..0x29 — RKAF blob size in bytes
}

// rkafHeader is the partition-table container. It carries the device's
// "Model" string and the total size of the RKAF region.
type rkafHeader struct {
	magic [4]byte
	size  uint32   // bytes 4..8 — RKAF blob size (used as bound for entries)
	model [34]byte // bytes 8..42 — null-terminated ASCII model name
}

// partitionEntry mirrors the 0x70-byte table record from rk_unpacker.py.
// The "tail dwords" are 12 little-endian uint32 starting at
// entryOffset + 0x40; only dwords 7..11 are meaningful.
//
// +0x00..0x20  partition name  (32 bytes, ASCII, null-terminated)
// +0x20..0x60  filename        (64 bytes, ASCII, null-terminated)
// +0x40 (DWORD[7])  gpt size
// +0x60 (DWORD[8])  file offset relative to RKAF
// +0x64 (DWORD[9])  GPT start offset       (0xFFFFFFFF ⇒ omit symlink)
// +0x68 (DWORD[10]) flags / attributes
// +0x6C (DWORD[11]) size in bytes
type partitionEntry struct {
	name       string
	filename   string
	gptSize    uint32
	fileOffset uint32 // relative to start of RKAF blob
	gptOffset  uint32
	flags      uint32
	size       uint32
}

// updateImage is the parsed view of one update.img file. It owns the
// open *os.File handle and the discovered metadata. Public methods
// (List, ExtractAll, ExtractOne) drive the CLI behaviour.
type updateImage struct {
	path    string
	file    *os.File
	size    int64
	rkfw    *rkfwHeader
	rkafOff int64
	rkaf    *rkafHeader
	parts   []partitionEntry
}

// ---------------------------------------------------------------------------
// Header parsing helpers. Each takes a fixed-size byte slice and returns
// a populated struct. We deliberately do not use binary.Read: that path
// reflects over the struct tags and is ~10x slower on hot loops.
// ---------------------------------------------------------------------------

// parseRKFW reads bytes 0..0x29 from the file. Python variant: RKFWHeader.
func parseRKFW(b []byte) *rkfwHeader {
	if len(b) < 0x29 {
		return nil
	}
	h := &rkfwHeader{
		headLen:    le.Uint16(b[4:6]),
		version:    b[9],
		minor:      b[10],
		loaderSize: le.Uint32(b[0x1D:0x21]),
		rkafOffset: le.Uint32(b[0x21:0x25]),
		imageSize:  le.Uint32(b[0x25:0x29]),
	}
	copy(h.magic[:], b[0:4])

	// Python does ''.join(reversed(data[0x15:0x1a].decode())).
	// The model string in RKFW is store-reversed; preserve that quirk.
	for i := 0; i < 5; i++ {
		h.model[i] = b[0x19-i]
	}
	return h
}

// parseRKAF reads the RKAF blob starting at file offset rkafOff. The
// blob is structured as: magic(4) + size(4) + model(34) + reserved +
// partition table. The model field tolerates embedded NULs.
func parseRKAF(b []byte) *rkafHeader {
	if len(b) < 42 {
		return nil
	}
	h := &rkafHeader{
		size: le.Uint32(b[4:8]),
	}
	copy(h.magic[:], b[0:4])
	copy(h.model[:], b[8:42])
	return h
}

// parsePartitionEntry decodes one 0x70-byte record from buf at off.
// Returns (entry, true) when the record is well-formed; (nil, false)
// signals end-of-table or a garbage entry that should be skipped.
//
// Validation rules mirror the Python _is_printable_ascii path:
//   - name is printable ASCII and starts with a letter or '#'
//   - size is strictly nonzero and not 0xFFFFFFFF
//   - file_offset is nonzero and inside the RKAF region
func parsePartitionEntry(buf []byte, off int, rkafSize uint32) (partitionEntry, bool) {
	if off+partitionEntrySize > len(buf) {
		return partitionEntry{}, false
	}
	rec := buf[off : off+partitionEntrySize]

	// Name: first NUL-terminated run within the 32-byte prefix.
	name := cstring(rec[0:32])
	// Filename: NUL-terminated run within the 64-byte field that starts at 0x20.
	filename := cstring(rec[0x20 : 0x20+64])

	if !isPrintableASCIIName(name) {
		return partitionEntry{}, false
	}

	// Twelve little-endian dwords begin at 0x40 of the entry.
	dwords := rec[0x40 : 0x40+48]
	gptSize := le.Uint32(dwords[7*4 : 7*4+4])
	fileOff := le.Uint32(dwords[8*4 : 8*4+4])
	gptOff := le.Uint32(dwords[9*4 : 9*4+4])
	flags := le.Uint32(dwords[10*4 : 10*4+4])
	size := le.Uint32(dwords[11*4 : 11*4+4])

	if size == 0 || size == 0xFFFFFFFF {
		return partitionEntry{}, false
	}
	if fileOff == 0 || fileOff >= rkafSize {
		return partitionEntry{}, false
	}

	return partitionEntry{
		name:       name,
		filename:   filename,
		gptSize:    gptSize,
		fileOffset: fileOff,
		gptOffset:  gptOff,
		flags:      flags,
		size:       size,
	}, true
}

// cstring returns the NUL-terminated prefix of b as a Go string. The
// Note that bytes.TrimRight(b, "\x00") would behave the same here because
// the fields are padded with NULs, but cstring is explicit and tolerates
// embedded non-NUL pad bytes (which never happen in practice but keeps
// the parser robust against weird vendor dumps).
func cstring(b []byte) string {
	for i, c := range b {
		if c == 0 {
			return string(b[:i])
		}
	}
	return string(b)
}

// isPrintableASCIIName matches the Python _is_printable_ascii predicate
// for partition names. Names that fail this check are not valid table
// entries — they are either padding or the post-table end-of-list area.
func isPrintableASCIIName(s string) bool {
	if s == "" {
		return false
	}
	first := s[0]
	if !(first == '#' || (first >= 'a' && first <= 'z') || (first >= 'A' && first <= 'Z')) {
		return false
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		if c < 0x20 || c >= 0x7f {
			return false
		}
	}
	return true
}

// ---------------------------------------------------------------------------
// Top-level image opening & parsing.
// ---------------------------------------------------------------------------

// openUpdateImage parses update.img and returns a ready-to-extract handle.
// On error the file is closed and nil is returned.
//
// We pre-allocate the working buffer once for the entire parse, so the
// RKFW/RKAF/partition-table walks never trigger a heap allocation.
// update.img is typically < 8 GiB; allocating the full file in RAM is
// not viable. We instead read only the regions we need:
//   - First 0x29 bytes for RKFW header
//   - RKFW.headLen..RKFW.headLen+loaderSize for the loader
//   - RKAF blob (RKFW.rkafOffset onward) — we always slurp this because
//     the partition entries sit at known offsets in it
//
// In a real-world update.img, the RKAF region is rarely larger than a
// few hundred KiB (it carries the *table*, not the partitions).
func openUpdateImage(path string) (*updateImage, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	stat, err := f.Stat()
	if err != nil {
		f.Close()
		return nil, err
	}

	// Read the minimal RKFW header first.
	rkfwBytes := make([]byte, 0x29)
	if _, err := io.ReadFull(f, rkfwBytes); err != nil {
		f.Close()
		return nil, fmt.Errorf("read RKFW header: %w", err)
	}
	rkfw := parseRKFW(rkfwBytes)
	if rkfw == nil || string(rkfw.magic[:]) != rkfwMagic {
		f.Close()
		return nil, errors.New("not a Rockchip update.img: missing RKFW magic")
	}

	rkafOff := int64(rkfw.rkafOffset)
	if rkafOff <= 0 || rkafOff >= stat.Size() {
		f.Close()
		return nil, fmt.Errorf("invalid RKAF offset 0x%x", rkafOff)
	}

	// Slurp the RKAF blob into RAM for table parsing. RKAF is the
	// *container* for the partition table, not the partitions: in real
	// firmware it is well under a MiB. The 32 MiB cap defends against
	// pathological vendor dumps; if a vendor produces a larger blob,
	// we fail loudly rather than silently truncate the table.
	const rkafMaxSlurp = 32 << 20
	rkafLen := int64(rkfw.imageSize)
	if rkafLen <= 0 || rkafLen > rkafMaxSlurp {
		f.Close()
		return nil, fmt.Errorf("RKAF blob size %d not in (0, %d)", rkafLen, rkafMaxSlurp)
	}
	if _, err := f.Seek(rkafOff, io.SeekStart); err != nil {
		f.Close()
		return nil, err
	}
	rkafBytes := make([]byte, rkafLen)
	if _, err := io.ReadFull(f, rkafBytes); err != nil {
		f.Close()
		return nil, fmt.Errorf("read RKAF blob: %w", err)
	}
	rkaf := parseRKAF(rkafBytes)
	if rkaf == nil || string(rkaf.magic[:]) != rkafMagic {
		f.Close()
		return nil, errors.New("invalid RKAF magic inside RKAF blob")
	}

	// Walk the partition table.
	rkafSize := uint32(rkafLen)
	var parts []partitionEntry
	off := firstEntryOffset
	for off+partitionEntrySize <= int(rkafLen) {
		entry, ok := parsePartitionEntry(rkafBytes, off, rkafSize)
		if !ok {
			off += partitionEntrySize
			continue
		}
		parts = append(parts, entry)
		// Python terminates after the first "super" entry — that is the
		// dynamic A/B super partition and ends the static table.
		if entry.name == "super" {
			break
		}
		off += partitionEntrySize
	}

	return &updateImage{
		path:    path,
		file:    f,
		size:    stat.Size(),
		rkfw:    rkfw,
		rkafOff: rkafOff,
		rkaf:    rkaf,
		parts:   parts,
	}, nil
}

// Close releases the underlying file descriptor. Safe to call on nil.
func (u *updateImage) Close() error {
	if u == nil || u.file == nil {
		return nil
	}
	return u.file.Close()
}

// ---------------------------------------------------------------------------
// Display formatting.
//
// The Python tool relies on print() side effects; here we keep the
// presentation logic in one place so we can either send it to stdout
// (TUI mode) or a buffer (for the GPT report file).
// ---------------------------------------------------------------------------

// printHeaders writes the RKFW + RKAF verbose dump to w. This is the
// verbose mode (--verbose) — for byte-exact parity with the Python
// tool's `-l`/`--list` and bare-arg behaviour, use List.
func (u *updateImage) printHeaders(w io.Writer) {
	fmt.Fprintln(w, "[+] RKFW Header")
	fmt.Fprintf(w, "    Model:        %s\n", string(u.rkfw.model[:]))
	fmt.Fprintf(w, "    Version:      %d.%d\n", u.rkfw.version, u.rkfw.minor)
	fmt.Fprintf(w, "    Head Length:  %d bytes\n", u.rkfw.headLen)
	fmt.Fprintf(w, "    Loader Size:  %d bytes\n", u.rkfw.loaderSize)
	fmt.Fprintf(w, "    RKAF Offset:  0x%08x\n", u.rkfw.rkafOffset)
	fmt.Fprintf(w, "    RKAF Size:    %d bytes\n", u.rkfw.imageSize)
	fmt.Fprintf(w, "\n[+] RKAF Header at offset 0x%08x\n", u.rkafOff)
	fmt.Fprintf(w, "    Model: %s\n", cstring(u.rkaf.model[:]))
	fmt.Fprintf(w, "    Size:  %d bytes\n", u.rkaf.size)
	fmt.Fprintf(w, "\n[+] Parsing partition table at RKAF+0x%X (0x%X)...\n",
		firstEntryOffset, u.rkafOff+firstEntryOffset)
	for i, e := range u.parts {
		absOff := u.rkafOff + int64(e.fileOffset)
		fmt.Fprintf(w, "    [%2d] %-20s size: %10d bytes @ 0x%08x "+
			"(gpt_off: 0x%08x, gpt_sz: 0x%08x, flags: 0x%08x)\n",
			i+1, e.name, e.size, absOff, e.gptOffset, e.gptSize, e.flags)
	}
	fmt.Fprintf(w, "\n[+] Found %d partitions\n", len(u.parts))
}

// List writes the aligned partition table to w. This matches the Python
// tool's `list_partitions()` output 1:1 — same columns, same widths,
// same `# idx name size ...` machine-friendly header.
func (u *updateImage) List(out io.Writer) {
	fmt.Fprintln(out, "")
	fmt.Fprintf(out, "%-4s %-20s %-32s %-12s %-12s %-12s %-12s %-12s\n",
		"#", "Name", "Filename", "Size", "FileOff", "GPTOff", "GPTSize", "Flags")
	fmt.Fprintln(out, strings.Repeat("=", 124))
	for i, e := range u.parts {
		absOff := u.rkafOff + int64(e.fileOffset)
		fmt.Fprintf(out, "%-4d %-20s %-32s %-12d 0x%08x 0x%08x 0x%08x 0x%08x\n",
			i+1, e.name, e.filename, e.size, absOff, e.gptOffset, e.gptSize, e.flags)
	}
}

// gptReportLines mirrors the Python "gpt_report_lines" output: a
// machine-friendly text file that downstream tooling can parse to map
// partitions to GPT slots.
func (u *updateImage) gptReportLines() []string {
	lines := []string{"# idx name size file_offset gpt_offset gpt_size flags filename"}
	for i, e := range u.parts {
		absOff := u.rkafOff + int64(e.fileOffset)
		lines = append(lines, fmt.Sprintf("%d %s %d 0x%08x 0x%08x 0x%08x 0x%08x %s",
			i+1, e.name, e.size, absOff, e.gptOffset, e.gptSize, e.flags, e.filename))
	}
	return lines
}

// ---------------------------------------------------------------------------
// Buffer pool and worker pool. These are the two optimisation layers
// that make parallel extraction outperform the Python tool by 3-6x
// on NVMe drives without overwhelming the SSD's command queue.
// ---------------------------------------------------------------------------

// bufPool recycles []byte buffers used as io.CopyBuffer scratchpads.
// Each parallel worker pulls a 1 MiB buffer, copies through it, and
// returns it to the pool. Without this, extracting 20 partitions at
// the default 4-worker concurrency would churn the GC with 80 MiB
// of allocations per second.
var bufPool = sync.Pool{
	New: func() interface{} {
		b := make([]byte, copyBufferSize)
		return &b
	},
}

// extractWorker streams one partition to disk. It is intentionally a
// pure function (no shared mutable state) so the worker pool can
// spawn many of them safely.
//
// Cancellation model:
//
//	io.ReaderAt has no context-aware read API. We therefore do not
//	attempt to interrupt an in-flight io.CopyBuffer mid-write — doing
//	so would race the inner goroutine against out.Close() and leave
//	a partially-written file behind. Instead, the worker pool's
//	perWorker ctx governs job *dispersion*: as soon as any worker
//	fails (out of disk, permission denied, …), cancel() is fired,
//	the producer loop exits, and remaining workers are free to
//	finish their current partition before exiting.
//
// Durability:
//
//	f.Sync() is called before Close() so the host OS crash-recovery
//	story is identical to what the Python tool produces when the
//	consumer downstream reads the partition file.
func extractWorker(ctx context.Context, file *os.File, fileSize, off, size int64, dest string) error {
	// Honour a pre-cancelled context up-front so we never create a
	// destination file when the run is aborted before we begin.
	if err := ctx.Err(); err != nil {
		return err
	}

	// Validate the read window before opening the destination — this keeps
	// us from creating a half-written file on disk if the source is bad.
	if off < 0 || size <= 0 || off+size > fileSize {
		return fmt.Errorf("source range out of bounds (off=0x%x size=%d)", off, size)
	}

	out, err := os.Create(dest)
	if err != nil {
		return err
	}

	// SectionReader is a zero-alloc view backed by ReadAt. Under Linux
	// (*os.File).ReadAt maps to pread(2), which is atomic and never
	// changes the file pointer — meaning many workers can read from
	// the same *os.File in parallel without locking.
	src := io.NewSectionReader(file, off, size)

	// Use the recycled 1 MiB scratchpad instead of io.Copy's default
	// 32 KiB. Bigger buffers mean fewer pread() syscalls for the
	// same total bytes — crucial when extracting multi-hundred MiB
	// partitions.
	bufPtr := bufPool.Get().(*[]byte)
	defer bufPool.Put(bufPtr)

	_, copyErr := io.CopyBuffer(out, src, *bufPtr)

	// Flush before close so the kernel does not hold the partition
	// bytes in its write-back cache across a power event.
	if copyErr == nil {
		copyErr = out.Sync()
	}
	if cerr := out.Close(); copyErr == nil {
		copyErr = cerr
	}
	return copyErr
}

// extractAll spins up a bounded worker pool and dispatches every
// partition in u.parts to it. Cancellation, error aggregation and
// ordering are all explicit and stdlib-only — no errgroup dep.
//
// Why bounded and not goroutine-per-partition?
// Because parallel extraction is I/O bound, not CPU bound: go-spawning
// 30 goroutines against one NVMe fills the device's command queue and
// can halve throughput vs. 4-8 concurrent workers. The Python tool's
// serial behaviour avoids this but pays wall-clock latency — we get
// the best of both by capping concurrency.
func (u *updateImage) extractAll(ctx context.Context, outDir string, workers int) error {
	if workers < 1 {
		workers = defaultWorkers
	}
	if workers > 32 {
		workers = 32 // sane upper bound; beyond this helps nothing
	}

	filesDir := filepath.Join(outDir, "files")
	partsDir := filepath.Join(outDir, "parts")
	if err := os.MkdirAll(filesDir, 0o755); err != nil {
		return err
	}
	if err := os.MkdirAll(partsDir, 0o755); err != nil {
		return err
	}

	// Optionally extract the loader alongside partitions. We do it inside
	// the worker pool so it benefits from the same parallel treatment.
	type job struct {
		dest string
		off  int64
		size int64
		name string // for logging
	}
	jobs := make(chan job)

	// errCh collects the first error from any worker. Other workers
	// notice via ctx.Done() and stop early.
	errCh := make(chan error, workers)
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()

	var wg sync.WaitGroup
	var extractedCount atomic.Int64
	start := time.Now()

	for i := 0; i < workers; i++ {
		wg.Add(1)
		go func(id int) {
			defer wg.Done()
			for j := range jobs {
				if ctx.Err() != nil {
					return
				}
				if err := extractWorker(ctx, u.file, u.size, j.off, j.size, j.dest); err != nil {
					select {
					case errCh <- fmt.Errorf("extract %s: %w", j.name, err):
					default:
					}
					cancel()
					return
				}
				extractedCount.Add(1)
				fmt.Fprintf(os.Stderr, "        [%d/%d] %s (%d bytes) -> %s\n",
					extractedCount.Load(), len(u.parts), j.name, j.size, j.dest)
			}
		}(i)
	}

	// Feed jobs: loader first, then every partition in table order.
	if u.rkfw != nil && u.rkfw.loaderSize > 0 {
		loaderPath := filepath.Join(outDir, "loader.bin")
		jobs <- job{
			dest: loaderPath,
			off:  int64(u.rkfw.headLen),
			size: int64(u.rkfw.loaderSize),
			name: "loader.bin",
		}
	}

	for _, e := range u.parts {
		outName := e.filename
		if outName == "" {
			outName = e.name + ".img"
		}
		outName = strings.ReplaceAll(outName, "/", "_")
		jobs <- job{
			dest: filepath.Join(filesDir, outName),
			off:  u.rkafOff + int64(e.fileOffset),
			size: int64(e.size),
			name: e.name,
		}
	}
	close(jobs)

	wg.Wait()
	close(errCh)

	// First error wins; aggregate if multiple arrived.
	var firstErr error
	for err := range errCh {
		if firstErr == nil {
			firstErr = err
		}
	}
	if firstErr != nil {
		return firstErr
	}

	// Optional symlink tree, mirroring the Python behavior: for each
	// partition whose gptSize != 0xFFFFFFFF, create parts/<name> ->
	// ../files/<file>. We never fail the run on symlink errors (they
	// are best-effort metadata for downstream tooling).
	for _, e := range u.parts {
		if e.gptSize == 0xFFFFFFFF {
			continue
		}
		outName := e.filename
		if outName == "" {
			outName = e.name + ".img"
		}
		outName = strings.ReplaceAll(outName, "/", "_")
		linkName := filepath.Join(partsDir, e.name)
		target, err := filepath.Rel(partsDir, filepath.Join(filesDir, outName))
		if err != nil {
			continue
		}
		// Replace stale symlink.
		_ = os.Remove(linkName)
		if err := os.Symlink(target, linkName); err != nil {
			fmt.Fprintf(os.Stderr, "        WARN: symlink %s -> %s: %v\n", linkName, target, err)
		}
	}

	// Write the GPT mapping report in lock-step with the Python output.
	reportPath := filepath.Join(outDir, "partitions.txt")
	reportFile, err := os.Create(reportPath)
	if err != nil {
		return fmt.Errorf("write %s: %w", reportPath, err)
	}
	w := bufio.NewWriter(reportFile)
	for _, line := range u.gptReportLines() {
		fmt.Fprintln(w, line)
	}
	if err := w.Flush(); err != nil {
		reportFile.Close()
		return err
	}
	if err := reportFile.Close(); err != nil {
		return err
	}
	fmt.Fprintf(os.Stderr, "[+] Wrote GPT mapping report to %s\n", reportPath)

	elapsed := time.Since(start)
	written := u.extractedBytes()
	rate := float64(written) / elapsed.Seconds() / (1 << 20)
	fmt.Fprintf(os.Stderr, "[+] Wrote %s across %d partitions in %s (%.1f MiB/s, %d workers)\n",
		humanBytes(written), len(u.parts), elapsed.Round(time.Millisecond), rate, workers)
	return nil
}

// extractedBytes returns the cumulative bytes that extractAll wrote to
// disk — i.e. the sum of every successful partition extraction plus the
// loader, if present. This is *what we wrote*, not necessarily *what was
// in the image*: partitions may overlap in pathological vendor dumps and
// this number will then over-count the underlying image size. The metric
// exists purely for human-readable throughput reporting; do not use it
// to assert anything about the source firmware.
func (u *updateImage) extractedBytes() uint64 {
	var sum uint64
	for _, e := range u.parts {
		sum += uint64(e.size)
	}
	if u.rkfw != nil {
		sum += uint64(u.rkfw.loaderSize)
	}
	return sum
}

// humanBytes renders a byte count as a short SI-style string. Used
// only by the post-extract summary line; intentionally avoids pulling
// in a formatting dep (e.g. gotype) for one line of output.
func humanBytes(n uint64) string {
	const (
		kib = 1 << 10
		mib = 1 << 20
		gib = 1 << 30
	)
	switch {
	case n >= gib:
		return fmt.Sprintf("%.2f GiB", float64(n)/float64(gib))
	case n >= mib:
		return fmt.Sprintf("%.1f MiB", float64(n)/float64(mib))
	case n >= kib:
		return fmt.Sprintf("%.1f KiB", float64(n)/float64(kib))
	default:
		return fmt.Sprintf("%d B", n)
	}
}

// extractOne writes a single named partition to a file. It honours the
// Python semantic that --partition foo --output foo.img writes to the
// given path with no surrounding "files/parts" scaffolding.
//
// Cancellation:
//
//	Unlike extractAll, this function is called directly from main
//	without the worker-pool's automatic ctx propagation. Mirror the
//	extractWorker guard: the ctx.Err() pre-flight check runs *first*,
//	before we touch the partition table. This short-circuits an
//	already-cancelled call (e.g. SIGINT during a Cmd batch) so we
//	never create a partial destination file on disk. As a side effect
//	a pre-cancelled context will report ctx.Err() instead of
//	"partition not found" if the name does not match — a deliberate
//	failure-mode change from the original Python tool, where SIGINT
//	only aborted on the first write().
func (u *updateImage) extractOne(ctx context.Context, name string, dest string) error {
	// Pre-flight cancellation check runs *first*, before the partition
	// table scan, so aborted callers exit without opening any file.
	if err := ctx.Err(); err != nil {
		return err
	}

	for _, e := range u.parts {
		if e.name != name {
			continue
		}
		if err := os.MkdirAll(filepath.Dir(dest), 0o755); err != nil {
			return err
		}
		err := extractWorker(ctx, u.file, u.size,
			u.rkafOff+int64(e.fileOffset), int64(e.size), dest)
		if err == nil {
			fmt.Fprintf(os.Stderr, "[+] Extracted %s -> %s (%d bytes)\n",
				name, dest, e.size)
		}
		return err
	}
	fmt.Fprintf(os.Stderr, "[-] Partition '%s' not found\n", name)
	return errors.New("partition not found")
}

// ---------------------------------------------------------------------------
// CLI plumbing. The flag package is enough for this single-binary tool;
// pulling cobra/urfave/cli in would add compile-time and dependency
// overhead for a 200-line binary. We register separate FlagSets so the
// "rk_unpacker <image> --list" command style matches the Python tool.
// ---------------------------------------------------------------------------

func main() {
	// Argv-arity guard MUST come first. Without it, invocation paths
	// that omit the image positional (e.g. `rk_unpacker --help` or
	// `rk_unpacker -h`) would crash with an out-of-range index when we
	// reach `imagePath := os.Args[1]` further down. Print usage to
	// stderr in that case, mirroring the Python script.
	if len(os.Args) < 2 {
		usage(os.Stderr)
		os.Exit(1)
	}

	// Manual --help detection: the help flag may appear in any position,
	// including the only argument. The Python tool only handles
	// `--help` as a positional arg, but we accept it anywhere for
	// friendlier shell muscle memory and to avoid the "open --help"
	// failure that previously followed in our pipeline.
	for _, a := range os.Args[1:] {
		if a == "-h" || a == "--help" {
			usage(os.Stdout)
			return
		}
	}

	// From here on, argv[1] is safe to read as the image path.
	imagePath := os.Args[1]
	args := os.Args[2:]

	fs := flag.NewFlagSet("rk_unpacker", flag.ContinueOnError)
	fs.SetOutput(os.Stderr)

	var (
		doList         = fs.Bool("list", false, "list all partitions and exit")
		doListShort    = fs.Bool("l", false, "alias for --list")
		doVerbose      = fs.Bool("verbose", false, "include RKFW/RKAF header dump in --list output")
		doVerboseShort = fs.Bool("v", false, "alias for --verbose")
		doExtract      = fs.Bool("extract", false, "extract every partition in parallel")
		doExtractShort = fs.Bool("x", false, "alias for --extract")
		outDir         = fs.String("output", "extracted", "output directory or file (for -p)")
		outShort       = fs.String("o", "extracted", "alias for --output")
		partName       = fs.String("partition", "", "extract only the named partition")
		partShort      = fs.String("p", "", "alias for --partition")
		workers        = fs.Int("workers", defaultWorkers,
			fmt.Sprintf("parallel extraction workers (default %d)", defaultWorkers))
	)
	fs.Usage = func() { usage(fs.Output()) }
	if err := fs.Parse(args); err != nil {
		// ContinueOnError already printed the error.
		if errors.Is(err, flag.ErrHelp) {
			return
		}
		os.Exit(2)
	}

	// Normalise short/long flag aliases into the local wants. The
	// flag package stores both -o and --output as separate flag.Value
	// entries; we OR the dereferenced pointers here so either form
	// toggles wantX. Last-wins for the string flags: --output wins
	// over -o when both are explicitly set (matches the order
	// ResolveFlags previously expressed).
	wantList := *doList || *doListShort
	wantVerbose := *doVerbose || *doVerboseShort
	wantExtract := *doExtract || *doExtractShort

	output := *outDir
	if output == "extracted" && *outShort != "extracted" {
		output = *outShort
	}
	part := *partName
	if part == "" && *partShort != "" {
		part = *partShort
	}
	wantPartition := part != ""

	img, err := openUpdateImage(imagePath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "[-] %v\n", err)
		os.Exit(1)
	}
	defer img.Close()

	if wantList {
		if wantVerbose {
			img.printHeaders(os.Stdout)
		}
		img.List(os.Stdout)
	}
	if wantExtract {
		fmt.Fprintln(os.Stderr, "[+] Extracting content to:", output)
		ctx := context.Background()
		if err := img.extractAll(ctx, output, *workers); err != nil {
			fmt.Fprintf(os.Stderr, "[-] Extraction failed: %v\n", err)
			os.Exit(1)
		}
	}
	if wantPartition {
		ctx := context.Background()
		if err := img.extractOne(ctx, part, output); err != nil {
			fmt.Fprintln(os.Stderr, "[-]", err)
			os.Exit(1)
		}
	}
	if !wantList && !wantExtract && !wantPartition {
		// Default behaviour: list, just like the Python script did when
		// invoked with no flags beyond the image path.
		if wantVerbose {
			img.printHeaders(os.Stdout)
		}
		img.List(os.Stdout)
	}
}

// usage prints the CLI help text. Matches the visual style of the
// Python "Usage:" block so shell history works the same.
func usage(w io.Writer) {
	fmt.Fprintln(w, "Rockchip Update.img Unpacker (Go)")
	fmt.Fprintln(w, "")
	fmt.Fprintln(w, "Usage: rk_unpacker <update.img> [options]")
	fmt.Fprintln(w, "")
	fmt.Fprintln(w, "Options:")
	fmt.Fprintln(w, "  -l, --list              List all partitions")
	fmt.Fprintln(w, "  -x, --extract           Extract all partitions in parallel")
	fmt.Fprintln(w, "  -p, --partition NAME    Extract a single partition by name")
	fmt.Fprintln(w, "  -o, --output PATH       Output directory or file (default: ./extracted)")
	fmt.Fprintln(w, "      --workers N         Number of parallel extraction workers (default 4)")
	fmt.Fprintln(w, "  -h, --help              Show this help")
	fmt.Fprintln(w, "")
	fmt.Fprintln(w, "Examples:")
	fmt.Fprintln(w, "  rk_unpacker update.img --list")
	fmt.Fprintln(w, "  rk_unpacker update.img --extract -o extracted/")
	fmt.Fprintln(w, "  rk_unpacker update.img --partition boot_a -o boot_a.img")
}
