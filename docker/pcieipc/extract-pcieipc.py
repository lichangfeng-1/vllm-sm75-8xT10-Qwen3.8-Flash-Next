#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""extract-pcieipc.py —— 从 flashinfer 0.7.0.post1 wheel 里精确切出 T11a backport 物料。

v1 废弃原因（本地单测抓到，未上机即拦截）：
  trace_comm.txt 的辅助函数选取用 `t.split("(",1)[0].strip() in need_names`，
  而 def 块的前缀是 "def _pcie_ipc_all_reduce_init" —— 带 "def " 永远不等于裸名字，
  结果只切出 TraceTemplate 赋值本身，两个被引用的函数没落进去。
  那样打进镜像后 `import flashinfer` 直接 NameError（templates/comm.py 是被 eager import 的），
  等于把 QSA 主路径搞死，而所有断言都会"通过"（只查了符号名出现在文本里，没查是否被定义）。

v2 修法：
  * 用 AST 求**定义—引用闭包**：从目标顶层节点出发，凡被引用且在同文件有顶层定义的名字，
    其定义节点一并纳入，递归到不动点。
  * 断言从"文本含该名字"升级为"该名字在本块内有顶层 def/赋值"（正则 ^def NAME\\( / ^NAME =）。
  * 顺带对 jit 块做同样的"引用符号可解析"体检（gen_jit_spec / jit_env / JitSpec 必须在目标文件里存在，
    这条留给 install.sh 在镜像内核，因为要看的是已装的 jit/comm.py）。

用法（G292-Z20 宿主，python3 = 3.12.3）：
    python3 extract-pcieipc.py <wheel.whl> <输出上下文目录>
"""
from __future__ import annotations

import ast
import hashlib
import os
import re
import sys
import zipfile

VERBATIM = [
    "flashinfer/comm/pcie_ipc_ar.py",
    "flashinfer/comm/pcie_ipc_policy.py",
    "flashinfer/comm/pcie_ipc_topology.py",
    "flashinfer/comm/pcie_ipc_tuning.py",
    "flashinfer/data/csrc/pcie_ipc_all_reduce.cu",
    "flashinfer/data/include/flashinfer/comm/pcie_ipc_all_reduce.cuh",
]
# 必须是"定义级命中"（^def NAME( 或 ^NAME =），不是文本里出现过
REQUIRED_DEFINITIONS = {
    "jit_comm.txt": ["gen_pcie_ipc_comm_module"],
    "trace_comm.txt": ["_pcie_ipc_all_reduce_init", "_pcie_ipc_all_reduce_reference",
                       "pcie_ipc_all_reduce_trace"],
    "comm_init.txt": [],
}
# 必须最终能作为 flashinfer.comm 的属性出现的名字（vLLM 只查第一个，其余是上游公开面）
EXPECTED_EXPORTS = [
    "PcieIpcAllReduceWorkspace", "gen_pcie_ipc_comm_module", "get_pcie_ipc_comm_module",
    "PcieIpcLaunchConfig", "PcieIpcVariant", "PCIE_IPC_CUSTOM_OP",
    "pcie_ipc_default_cache_path", "get_pcie_ipc_launch_config",
    "probe_pcie_ipc_rank_topology", "resolve_pcie_ipc_profile",
]
BUILTIN_OK = set(dir(__builtins__)) | {"torch", "os", "re", "sys", "Optional", "Dict", "List",
                                        "Tuple", "Sequence", "Any", "bool", "int", "str", "float",
                                        "bytes", "set", "type", "Exception", "super", "print"}


def die(msg: str):
    print("ASSERT_FAIL " + msg)
    sys.exit(2)


def node_source(src: str, node):
    return ast.get_source_segment(src, node, padded=True) or ""


def bound_names(node):
    out = set()
    if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
        out.add(node.name)
    elif isinstance(node, ast.Assign):
        for t in node.targets:
            if isinstance(t, ast.Name):
                out.add(t.id)
    elif isinstance(node, ast.AnnAssign) and isinstance(node.target, ast.Name):
        out.add(node.target.id)
    elif isinstance(node, (ast.Import, ast.ImportFrom)):
        for a in node.names:
            out.add(a.asname or a.name.split(".")[0])
    return out


def referenced_names(node):
    out = set()
    for n in ast.walk(node):
        if isinstance(n, ast.Name):
            out.add(n.id)
        elif isinstance(n, ast.Attribute):
            pass
    return out


def closure_for(top_nodes, target_node):
    """从 target_node 出发，把同文件里有顶层定义的引用一并纳入（递归到不动点）。

    只认 def/class/赋值，**不认 import 节点**：否则会把 wheel 侧的 import 行一起抄进追加块，
    多一行就多一处"0.6.18 里没这个名字 => import 炸"的风险（jit/comm.py 与 trace/templates/comm.py
    的 import 头虽实测与 0.6.18 逐行相同，也没必要赌）。
    """
    by_name = {}
    for n in top_nodes:
        if isinstance(n, (ast.Import, ast.ImportFrom)):
            continue
        for b in bound_names(n):
            by_name.setdefault(b, n)
    chosen, stack = [], [target_node]
    seen_ids = set()
    while stack:
        node = stack.pop()
        if id(node) in seen_ids:
            continue
        seen_ids.add(id(node))
        chosen.append(node)
        for ref in referenced_names(node):
            provider = by_name.get(ref)
            if provider is not None and id(provider) not in seen_ids:
                stack.append(provider)
    order = {id(n): i for i, n in enumerate(top_nodes)}
    chosen.sort(key=lambda n: order[id(n)])
    return chosen


def main() -> int:
    if len(sys.argv) != 3:
        die("用法: python3 extract-pcieipc.py <wheel.whl> <输出上下文目录>")
    whl, ctx = sys.argv[1], sys.argv[2]
    if not os.path.isfile(whl):
        die("wheel 不存在: " + whl)
    if os.path.exists(os.path.join(ctx, "manifest.txt")):
        die("上下文目录已有 manifest.txt，拒绝覆盖（重做请先手工清空）")
    z = zipfile.ZipFile(whl)
    names = set(z.namelist())
    for d in ("newfiles/flashinfer/comm", "newfiles/flashinfer/data/csrc",
              "newfiles/flashinfer/data/include/flashinfer/comm", "append"):
        os.makedirs(os.path.join(ctx, d), exist_ok=True)

    rows = []

    def put(rel_in_ctx, data: bytes, tag: str):
        with open(os.path.join(ctx, rel_in_ctx), "wb") as f:
            f.write(data)
        rows.append((rel_in_ctx, data.count(b"\n") + 1, len(data),
                     hashlib.sha256(data).hexdigest(), tag))

    # 1) 六个逐字节文件
    for rel in VERBATIM:
        if rel not in names:
            die("wheel 里没有 " + rel)
        raw = z.read(rel)
        if b"\r" in raw:
            die(rel + " 含 CR")
        if not raw.endswith(b"\n"):
            raw += b"\n"
        put("newfiles/" + rel, raw, "verbatim")
        print("  VERBATIM_OK %s" % rel)

    # 2) 三个追加块，全部走 AST 闭包
    def build_block(wheel_rel: str, target_start: str, out_name: str, extra_check=None):
        src = z.read(wheel_rel).decode("utf-8")
        tree = ast.parse(src)
        top = [n for n in tree.body]
        cands = [n for n in top if node_source(src, n).lstrip().startswith(target_start)]
        if len(cands) != 1:
            die("%s 里以 %r 开头的顶层节点数=%d，期望 1" % (wheel_rel, target_start, len(cands)))
        nodes = closure_for(top, cands[0])
        parts = [node_source(src, n) for n in nodes]
        joined = "\n\n".join(p.rstrip("\n") for p in parts) + "\n"
        try:
            ast.parse(joined)
        except SyntaxError as e:
            die("%s 拼出来的块不能 parse: %s" % (out_name, e))
        for name in REQUIRED_DEFINITIONS[out_name]:
            if not re.search(r"^(?:def|class)\s+%s\s*[\(:=]?\(" % re.escape(name), joined, re.M) \
               and not re.search(r"^%s\s*=" % re.escape(name), joined, re.M) \
               and not re.search(r"^(?:def|class)\s+%s\b" % re.escape(name), joined, re.M):
                die("%s 缺定义级命中: %s（闭包没抓到，别再往下走）" % (out_name, name))
        if extra_check:
            extra_check(joined)
        put("append/" + out_name, ("\n\n" + joined).encode("utf-8"), "append")
        print("  APPEND_OK %-16s 顶层节点=%d 定义=%s" % (
            out_name, len(nodes), sorted(set().union(*[bound_names(n) for n in nodes]))[:6]))

    def jit_check(text):
        if "pcie_ipc_all_reduce.cu" not in text or "FLASHINFER_CSRC_DIR" not in text:
            die("jit 块内容不符合预期（没找到 csrc 引用）")

    build_block("flashinfer/jit/comm.py", "def gen_pcie_ipc_comm_module(", "jit_comm.txt", jit_check)
    build_block("flashinfer/trace/templates/comm.py", "pcie_ipc_all_reduce_trace = TraceTemplate(", "trace_comm.txt")

    # 3) comm/__init__.py：只取 module 含 pcie 的顶层 ImportFrom（这类块没有跨块依赖）
    ci = z.read("flashinfer/comm/__init__.py").decode("utf-8")
    tree = ast.parse(ci)
    nodes = [n for n in tree.body
             if isinstance(n, ast.ImportFrom) and (n.module or "").lower().count("pcie")]
    if not nodes:
        die("comm/__init__.py 没找到 pcie 相关顶层 import")
    lines = ci.splitlines(keepends=True)
    idxs = set()
    for n in nodes:
        idxs.update(range(n.lineno - 1, n.end_lineno))
    seg = "".join(lines[i] for i in sorted(idxs))
    compile(seg, "<seg>", "exec")
    if "PcieIpcAllReduceWorkspace" not in seg:
        die("comm_init.txt 里没有 PcieIpcAllReduceWorkspace")
    put("append/comm_init.txt", ("\n\n" + seg.rstrip("\n") + "\n").encode("utf-8"), "append")
    print("  APPEND_OK comm_init.txt    import 语句=%d" % len(nodes))

    # 4) 导出名核对
    segtxt = open(os.path.join(ctx, "append", "comm_init.txt"), encoding="utf-8").read()
    miss = [n for n in EXPECTED_EXPORTS
            if not (" as " + n + "\n" in segtxt or n + " as " in segtxt or ("import " + n + "\n") in segtxt)]
    if miss:
        die("comm_init.txt 未覆盖导出名: %s" % miss)
    print("  EXPORTS_COVERED=%d" % len(EXPECTED_EXPORTS))

    # 5) import 依赖分流：
    #    (a) 四个待落文件互查 —— 本地就能判，防"从两个不同版本各抄一半"的版本错位；
    #    (b) 对 0.6.18 既有模块的依赖写进 obligations.txt，由 install.sh 在镜像内核验。
    shipped = {"comm/" + os.path.basename(r) for r in VERBATIM[:4]}

    def top_bindings(src):
        names = set()
        for n in ast.parse(src).body:
            names |= bound_names(n)
            if isinstance(n, (ast.Try, ast.If)):
                for st_list in (getattr(n, "body", []), getattr(n, "orelse", []), getattr(n, "finalbody", [])):
                    for st in st_list:
                        names |= bound_names(st)
                        if isinstance(st, (ast.Try, ast.If)):
                            for st2 in (getattr(st, "body", []), getattr(st, "orelse", [])):
                                names |= bound_names(st2)
        return names

    bind_cache = {}
    for rel in VERBATIM[:4]:
        k = "comm/" + os.path.basename(rel)
        bind_cache[k] = top_bindings(z.read(rel).decode("utf-8"))

    skew, obligations = [], {}
    for rel in VERBATIM[:4]:
        key = "comm/" + os.path.basename(rel)
        for n in ast.walk(ast.parse(z.read(rel).decode("utf-8"))):
            if not isinstance(n, ast.ImportFrom) or not n.level:
                continue
            mod = n.module or ""
            tgt = ("comm/" + mod.replace(".", "/")) if n.level == 1 else (mod.replace(".", "/") or "__init__")
            syms = [a.name for a in n.names]
            if tgt + ".py" in shipped:
                # v2 的 bug：shipped 里存 "comm/pcie_ipc_policy.py"，tgt 却是无扩展名的
                # "comm/pcie_ipc_policy" ⇒ 同包互查从未真正执行，"版本错位"这一路静默失效。
                miss = [s for s in syms if s not in bind_cache.get(tgt + ".py", set())]
                if miss:
                    skew.append("%s  <-  %s :: %s" % (key, tgt, miss))
            else:
                obligations.setdefault((key, tgt), set()).update(syms)
    if skew:
        die("待落文件之间 import 对不上（版本错位）:\n      " + "\n      ".join(skew))
    with open(os.path.join(ctx, "obligations.txt"), "w", encoding="utf-8", newline="\n") as f:
        f.write("# install.sh 逐条核验：0.6.18 既有模块必须提供这些顶层名字（目标相对 flashinfer 包根）\n")
        f.write("# 列: 引用方 <TAB> 目标模块 <TAB> 逗号分隔的名字\n")
        for (key, tgt), s in sorted(obligations.items()):
            f.write("%s\t%s\t%s\n" % (key, tgt, ",".join(sorted(s))))
    print("  SELF_CHECK_PASSED 同包互查=%d 个文件；OBLIGATIONS_ROWS=%d" % (len(shipped), len(obligations)))

    with open(os.path.join(ctx, "manifest.txt"), "w", encoding="utf-8", newline="\n") as f:
        f.write("# T11a backport 物料清单（extract-pcieipc.py 生成）\n")
        f.write("# source_wheel=%s\n" % os.path.basename(whl))
        f.write("# source_wheel_sha256=%s\n" % hashlib.sha256(open(whl, "rb").read()).hexdigest())
        f.write("# 列: 相对路径 <TAB> 行数 <TAB> 字节 <TAB> sha256 <TAB> 类型\n")
        for r in rows:
            f.write("%s\t%d\t%d\t%s\t%s\n" % r)
    print("MANIFEST_ROWS=%d" % len(rows))
    print("EXTRACT_OK ctx=" + ctx)
    return 0


if __name__ == "__main__":
    sys.exit(main())
