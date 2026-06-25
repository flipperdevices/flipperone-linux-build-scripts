package main

// rk_unpacker_test.go contains the table-driven unit tests for the
// pure helpers in rk_unpacker.go. Tests live in `package main` rather
// than `main_test` so the unexported helpers (humanBytes, cstring,
// isPrintableASCIIName) are reachable without promoting their visibility.

import (
	"bytes"
	"testing"
)

// TestHumanBytes is the contract test for the byte-count formatter used
// in the post-extraction throughput summary line.
func TestHumanBytes(t *testing.T) {
	cases := []struct {
		name string
		in   uint64
		want string
	}{
		{"zero-bytes", 0, "0 B"},
		{"one-byte", 1, "1 B"},
		{"sub-kib", 512, "512 B"},
		{"kib-boundary", 1 << 10, "1.0 KiB"},
		{"fractional-kib", 1536, "1.5 KiB"},
		{"mib-boundary", 1 << 20, "1.0 MiB"},
		{"typical-partition", 512 << 20, "512.0 MiB"},
		// One byte below the GiB threshold. humanBytes uses a single
		// if/else chain with no "nearly-GiB" sub-bucket, so values in
		// [1024.0 MiB, 1.00 GiB) round up into the upper end of the
		// MiB range. Documented boundary behaviour — touching this
		// row will fail the test and force the author to think about
		// whether to subdivide the MiB bucket.
		{"just-below-gib", 1<<30 - 1, "1024.0 MiB"},
		{"gib-boundary", 1 << 30, "1.00 GiB"},
		{"typical-rootfs", 5 * (1 << 30), "5.00 GiB"},
		{"fractional-gib", (1 << 30) + (512 << 20), "1.50 GiB"},
	}

	for _, c := range cases {
		c := c // capture for parallel safety on older Go versions
		t.Run(c.name, func(t *testing.T) {
			got := humanBytes(c.in)
			if got != c.want {
				t.Errorf("humanBytes(%d) = %q, want %q",
					c.in, got, c.want)
			}
		})
	}
}

// TestCstring covers the null-terminator scan used by the RKFW / RKAF
// and partition-entry parsers. Null-padded literals are built with
// bytes.Repeat instead of hand-counted \x00 sequences so the test is
// readable and resistent to typo-class off-by-one mistakes.
func TestCstring(t *testing.T) {
	// nul(n) is a tiny builder so the table cells below stay one-line.
	nul := func(n int) []byte { return bytes.Repeat([]byte{0}, n) }

	cases := []struct {
		name string
		in   []byte
		want string
	}{
		{"empty", []byte{}, ""},
		{"all-nul", nul(3), ""},
		{"no-nul-truncates", []byte{'a', 'b', 'c'}, "abc"},
		{"trailing-nul-pad", append([]byte("boot"), nul(3)...), "boot"},
		{"embedded-nul-truncates", []byte("loader\x00extra"), "loader"},
		{"single-trailing-byte", []byte{'z'}, "z"},
		{"single-byte-nul-terminated", nul(1), ""},
	}

	for _, c := range cases {
		c := c
		t.Run(c.name, func(t *testing.T) {
			got := cstring(c.in)
			if got != c.want {
				t.Errorf("cstring(%q) = %q, want %q",
					c.in, got, c.want)
			}
		})
	}
}

// TestIsPrintableASCIIName pins the partition-name predicate used
// during table walk. The "#"-prefix allowance matters in practice:
// Rockchip uses "#mmc" and similar tags for debug partitions, and
// tightening the rule silently drops them from the parsed table.
func TestIsPrintableASCIIName(t *testing.T) {
	cases := []struct {
		name string
		in   string
		want bool
	}{
		{"empty-string", "", false},
		{"lowercase-alnum", "boot", true},
		{"uppercase-alnum", "BOOT", true},
		{"hash-debug-prefix", "#mmc", true},
		{"mixed-case-internal-digit", "boot_a", true},
		{"digit-leading-char", "1boot", false},
		{"underscore-leading", "_boot", false},
		{"non-ascii-byte", "boot\xff", false},
		{"control-char-in-middle", "boot\x01a", false},
		{"hyphen-leading", "-boot", false},
	}

	for _, c := range cases {
		c := c
		t.Run(c.name, func(t *testing.T) {
			got := isPrintableASCIIName(c.in)
			if got != c.want {
				t.Errorf("isPrintableASCIIName(%q) = %v, want %v",
					c.in, got, c.want)
			}
		})
	}
}
