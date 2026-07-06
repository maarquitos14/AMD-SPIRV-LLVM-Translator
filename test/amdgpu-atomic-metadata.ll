; RUN: llvm-as < %s -o %t.bc
; RUN: llvm-spirv %t.bc -o %t.spv
; RUN: llvm-spirv -to-text %t.spv -o - | FileCheck %s

; Check that atomic instructions with amdgpu atomic metadata produce
; UserSemantic decorations.

target datalayout = "e-i64:64-v16:16-v24:32-v32:32-v48:64-v96:128-v192:256-v256:256-v512:512-v1024:1024"
target triple = "spirv64-amd-amdhsa"

@ui = common dso_local addrspace(1) global i32 0, align 4
@f = common dso_local addrspace(1) global float 0.000000e+00, align 4

; CHECK: Decorate [[#ADD_RES:]] UserSemantic "amdgpu.no.fine.grained.memory"
; CHECK: Decorate [[#ADD_RES]] UserSemantic "amdgpu.no.remote.memory"
; CHECK-NOT: Decorate [[#ADD_RES]] UserSemantic "amdgpu.ignore.denormal.mode"

; CHECK: Decorate [[#XCHG_RES:]] UserSemantic "amdgpu.no.fine.grained.memory"
; CHECK: Decorate [[#XCHG_RES]] UserSemantic "amdgpu.ignore.denormal.mode"
; CHECK-NOT: Decorate [[#XCHG_RES]] UserSemantic "amdgpu.no.remote.memory"

; CHECK: Decorate [[#CAS_RES:]] UserSemantic "amdgpu.no.fine.grained.memory"
; CHECK: Decorate [[#CAS_RES]] UserSemantic "amdgpu.no.remote.memory"
; CHECK: Decorate [[#CAS_RES]] UserSemantic "amdgpu.ignore.denormal.mode"

; CHECK: AtomicIAdd [[#]] [[#ADD_RES]]
; CHECK: AtomicExchange [[#]] [[#XCHG_RES]]
; CHECK: AtomicCompareExchange [[#]] [[#CAS_RES]]

define dso_local spir_func void @test_atomicrmw_metadata() {
entry:
  %0 = atomicrmw add ptr addrspace(1) @ui, i32 42 monotonic, !amdgpu.no.fine.grained.memory !0, !amdgpu.no.remote.memory !0
  %1 = atomicrmw xchg ptr addrspace(1) @f, float 42.0 seq_cst, !amdgpu.no.fine.grained.memory !0, !amdgpu.ignore.denormal.mode !0
  ret void
}

define dso_local spir_func void @test_cmpxchg_metadata(ptr %ptr, ptr %value_ptr, i32 %comparator) {
entry:
  %0 = load i32, ptr %value_ptr, align 4
  %1 = cmpxchg ptr %ptr, i32 %comparator, i32 %0 seq_cst acquire, !amdgpu.no.fine.grained.memory !0, !amdgpu.no.remote.memory !0, !amdgpu.ignore.denormal.mode !0
  %2 = extractvalue { i32, i1 } %1, 1
  br i1 %2, label %cmpxchg.continue, label %cmpxchg.store_expected

cmpxchg.store_expected:
  %3 = extractvalue { i32, i1 } %1, 0
  store i32 %3, ptr %value_ptr, align 4
  br label %cmpxchg.continue

cmpxchg.continue:
  ret void
}

!0 = !{}
