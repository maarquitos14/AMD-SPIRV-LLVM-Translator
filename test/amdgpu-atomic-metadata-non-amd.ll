; RUN: llvm-as < %s -o %t.bc
; RUN: llvm-spirv %t.bc -o %t.spv
; RUN: llvm-spirv -to-text %t.spv -o - | FileCheck %s

; Check that atomic instructions with amdgpu atomic metadata DO NOT produce
; UserSemantic decorations when NOT using AMD triple.

target datalayout = "e-i64:64-v16:16-v24:32-v32:32-v48:64-v96:128-v192:256-v256:256-v512:512-v1024:1024"
target triple = "spir64"

@ui = common dso_local addrspace(1) global i32 0, align 4

; CHECK: AtomicIAdd
; CHECK-NOT: UserSemantic "amdgpu.no.fine.grained.memory"
; CHECK-NOT: UserSemantic "amdgpu.no.remote.memory"
; CHECK-NOT: UserSemantic "amdgpu.ignore.denormal.mode"

define dso_local spir_func void @test_non_amd() {
entry:
  %0 = atomicrmw add ptr addrspace(1) @ui, i32 42 monotonic, !amdgpu.no.fine.grained.memory !0, !amdgpu.no.remote.memory !0, !amdgpu.ignore.denormal.mode !0
  ret void
}

!0 = !{}
