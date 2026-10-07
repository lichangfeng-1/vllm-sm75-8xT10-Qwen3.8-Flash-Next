#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""gate-check-v3.py —— 在镜像内核验 T11a backport 的终态（看产物，不看"我跑过命令"）。

v1 废弃原因（本地干跑抓到，未上机即拦截）：
  pre 阶段把"补丁自己追加的两个名字"（jit/comm::gen_pcie_ipc_comm_module、
  trace/templates/comm::pcie_ipc_all_reduce_trace）也算成"0.6.18 必须已经提供"，
  于是**任何干净构建都必然 GATE_FAIL** —— 门禁自身是假阻断，会让人误判"0.6.18 喂不饱"。

v2 修法：
  * 从 ctx 里的追加块**自动推导**"自供名字"（AST 收块内顶层绑定），
    只有当义务的目标模块 = 该块的目标文件时才豁免；pre 阶段打印 SELF_SUPPLIED 明示豁免了什么。
  * post 阶段不豁免：这两个名字必须真的存在（这样"追加块漏定义"仍会被拦住）。
  v3 再修一处（同样由本地干跑抓到）：post 的"追加块命中 1 次"marker 断言在 comm/__init__.py 上
  必然假失败（块里同一句 import 本来出现 3 次）。改为"目标文件必须以该块内容逐字结尾"。

  * 其它逻辑同 v1：包目录与单文件同等对待，AST 递归进 if/else/try 收绑定。

用法：python3 gate-check-v3.py <ctx目录> pre|post
"""
from __future__ import annotations

import ast
import hashlib
import os
import sys

SP = os.environ.get("SM75_SITE_PACKAGES", "/usr/local/lib/python3.12/dist-packages")
FI = os.path.join(SP, "flashinfer")

# 追加块 -> 它被 cat 到哪个模块（相对 flashinfer 包根，无扩展名）
APPEND_TARGETS = {
    "append/jit_comm.txt": "jit/comm",
    "append/trace_comm.txt": "trace/templates/comm",
    "append/comm_init.txt": "comm/__init__",
}


def die(msg):
    print("GATE_FAIL " + msg)
    sys.exit(2)


def resolve_module(rel):
    for cand in (os.path.join(FI, rel + ".py"), os.path.join(FI, rel, "__init__.py")):
        if os.path.isfile(cand):
            return cand
    return None


def bind(n, names):
    if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
        names.add(n.name)
    elif isinstance(n, ast.Assign):
        for t in n.targets:
            if isinstance(t, ast.Name):
                names.add(t.id)
    elif isinstance(n, ast.AnnAssign) and isinstance(n.target, ast.Name):
        names.add(n.target.id)
    elif isinstance(n, (ast.Import, ast.ImportFrom)):
        for a in n.names:
            names.add(a.asname or a.name.split(".")[0])


def top_bindings(src):
    names = set()
    for n in ast.parse(src).body:
        bind(n, names)
        if isinstance(n, (ast.Try, ast.If)):
            for lst in (getattr(n, "body", []), getattr(n, "orelse", []), getattr(n, "finalbody", [])):
                for st in lst:
                    bind(st, names)
                    if isinstance(st, (ast.Try, ast.If)):
                        for lst2 in (getattr(st, "body", []), getattr(st, "orelse", [])):
                            for st2 in lst2:
                                bind(st2, names)
    return names


def self_supplied(ctx):
    """{目标模块: 该模块的追加块自身绑定的名字集合}"""
    out = {}
    for blk, tgt in APPEND_TARGETS.items():
        p = os.path.join(ctx, blk)
        if not os.path.isfile(p):
            die("缺追加块 " + blk)
        try:
            out.setdefault(tgt, set()).update(top_bindings(open(p, encoding="utf-8", errors="replace").read()))
        except SyntaxError as e:
            die("%s 不能 parse: %s" % (blk, e))
    return out


def load_obligations(ctx):
    path = os.path.join(ctx, "obligations.txt")
    if not os.path.isfile(path):
        die("缺 obligations.txt")
    rows = []
    for line in open(path, encoding="utf-8"):
        line = line.rstrip("\n")
        if not line or line.startswith("#"):
            continue
        parts = line.split("\t")
        if len(parts) != 3:
            die("obligations.txt 列数=%d: %s" % (len(parts), line))
        src_mod, tgt, syms = parts
        rows.append((src_mod, tgt, [s for s in syms.split(",") if s]))
    if not rows:
        die("obligations.txt 是空的（提取器没写进去，别把空门禁当通过）")
    return rows


def check_obligations(ctx, phase):
    sup = self_supplied(ctx)
    bad, checked, exempt = [], 0, []
    for _src, tgt, syms in load_obligations(ctx):
        p = resolve_module(tgt)
        if phase == "pre" and p is not None:
            # 目标模块已存在时，仍要区分"补丁会追加的名字"
            pass
        if p is None and not (tgt in sup):
            bad.append("模块缺失 %s :: %s" % (tgt, ",".join(syms)))
            continue
        have = top_bindings(open(p, encoding="utf-8", errors="replace").read()) if p else set()
        for s in syms:
            if s in have:
                checked += 1
                continue
            if phase == "pre" and s in sup.get(tgt, set()):
                exempt.append("%s::%s" % (tgt, s))
                continue
            bad.append("%s 缺 %s（被 %s 引用）" % (tgt, s, _src))
    print("  OBLIGATIONS[%s] checked=%d exempt(补丁自供)=%d bad=%d" % (phase, checked, len(exempt), len(bad)))
    if exempt:
        print("    SELF_SUPPLIED=" + ", ".join(sorted(set(exempt))))
    for b in bad:
        print("    !! " + b)
    return not bad


def check_manifest(ctx):
    n = bad = 0
    for line in open(os.path.join(ctx, "manifest.txt"), encoding="utf-8"):
        if not line.strip() or line.startswith("#"):
            continue
        rel, _l, _b, sha, kind = line.rstrip("\n").split("\t")
        if kind != "verbatim":
            continue
        n += 1
        inst = os.path.join(FI, rel[len("newfiles/flashinfer/"):])
        if not os.path.isfile(inst):
            print("    !! 未落盘 " + inst); bad += 1; continue
        got = hashlib.sha256(open(inst, "rb").read()).hexdigest()
        if got != sha:
            print("    !! sha 不符 %s 期望 %s 实为 %s" % (inst, sha[:12], got[:12])); bad += 1
    print("  MANIFEST_CHECK verbatim=%d bad=%d" % (n, bad))
    return n > 0 and bad == 0


def check_appends(ctx):
    """v2 的 marker 计数在 comm/__init__.py 上必然"假失败"：
    追加块里 'from .pcie_ipc_ar import' 本来就有 3 次，count==1 是错的断言。
    v3 改成**尾部逐字比对**：目标文件必须 exactly 以该追加块的内容结尾（cat >> 的终态就是如此），
    既不会因重复文本误报，也不会因写歪漏报。"""
    ok = True
    for blk, tgt in sorted(APPEND_TARGETS.items()):
        block = open(os.path.join(ctx, blk), encoding="utf-8", errors="replace").read()
        p = resolve_module(tgt)
        if p is None:
            print("  APPEND %-24s 目标模块找不到 %s" % (tgt, "BAD")); ok = False; continue
        txt = open(p, encoding="utf-8", errors="replace").read()
        tail_ok = txt.endswith(block)
        print("  APPEND %-24s -> %-34s 块行数=%-4d 尾部逐字=%s" % (
            blk, os.path.relpath(p, FI), block.count(chr(10)), "OK" if tail_ok else "BAD"))
        if not tail_ok:
            print("     !! 期望结尾片段 %r 实为 %r" % (block[-60:], txt[-60:]))
        ok = ok and tail_ok
    return ok


def main():
    if len(sys.argv) != 3 or sys.argv[2] not in ("pre", "post"):
        die("用法: gate-check-v3.py <ctx> pre|post")
    ctx, phase = sys.argv[1], sys.argv[2]
    if not os.path.isdir(FI):
        die("没有 flashinfer 树: " + FI)
    results = []
    if phase == "post":
        results.append(check_manifest(ctx))
        results.append(check_appends(ctx))
    else:
        leftovers = [p for p in ("comm/pcie_ipc_ar.py", "comm/pcie_ipc_policy.py",
                                 "comm/pcie_ipc_topology.py", "comm/pcie_ipc_tuning.py",
                                 "data/csrc/pcie_ipc_all_reduce.cu",
                                 "data/include/flashinfer/comm/pcie_ipc_all_reduce.cuh")
                     if os.path.exists(os.path.join(FI, p))]
        print("  PRE_LEFTOVERS=%s" % (leftovers if leftovers else "无"))
        results.append(not leftovers)
    results.append(check_obligations(ctx, phase))
    if not all(results):
        die("phase=%s 有 %d 项未过" % (phase, results.count(False)))
    print("GATE_PASS phase=%s" % phase)
    return 0


if __name__ == "__main__":
    sys.exit(main())
