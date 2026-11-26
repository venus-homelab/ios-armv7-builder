// Copyright 2018 The Go Authors. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

//go:build darwin && arm

package unix

import "unsafe"

// darwin/arm (revived port, Go 1.27.2): the 2021-era zsyscall_darwin_arm.go
// uses the funcPC() helper that was removed from the modern generator output
// (which now emits `var libc_*_trampoline_addr` filled by generated assembly).
// For an ABI0 trampoline implemented in assembly, reading funcval[0] is the
// same value abi.FuncPCABI0 would produce, so the old helper still works.

// Find the entry point for f. See comments in runtime/proc.go for the
// function of the same name.
//
//go:nosplit
func funcPC(f func()) uintptr {
	return **(**uintptr)(unsafe.Pointer(&f))
}
