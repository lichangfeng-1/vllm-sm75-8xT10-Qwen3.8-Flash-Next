# NVAPI 库说明（`libnvidia-api.so.1` · 2026-10-07 · 0.1.7 包线）

## 先说清一件事：0.1.7 这条线不把它烘进镜像

0.1.6 包把它做成了一个镜像层（`Dockerfile.nvapi`）。**0.1.7 官方形态不是这样**：
这个库以**宿主文件只读 bind** 的方式进容器（`run/start-here-v2.sh` 里那条
`$NVAPI:/usr/local/nvidia/lib64/libnvidia-api.so.1:ro`），与官方 0.1.7 文档一致。
所以 `docker/build.sh` 里跟它有关的只有"前置门"——查文件在不在、sha 对不对，仅此一项而已。

它只服务控制台的 **P-State 电源管理**：面板启引擎前要读/写 GPU 电源档，缺这个库
`validateProfile` 那关过不去，面板直接拒绝启引擎。推理本体（模型加载、生成）与它无关。

## 获取：直接从本仓库下载

本仓**随附**该库副本：`docker/libnvidia-api.so.1`（720,104 字节，sha256 见下）。
clone 整仓，或网页进入 `docker/` 目录点该文件下载均可
（注意：raw.githubusercontent.com 在部分网络不可达，优先 clone）。
放到你指定的宿主路径后必过 sha 门禁：

```bash
sha256sum libnvidia-api.so.1
# 须等于 4a199f9b259a1098ab9c01d31c67f882a2531a0fbb9c3595ad3d016c7d131d8c
```

配什么驱动：随附副本与 **580.173.02** 配套实测（sha 即门禁值）。换驱动版本时该库可能不同：
先用本仓副本试，P-State 有异常再按下面"自己取件"或走降级路。

## 干脆不带这个文件（三处一起改，少一处就是"构建过了但面板拒启"）

```bash
SKIP_NVAPI=1 bash docker/build.sh                       # ① 放行构建前置门
NVAPI=none   bash run/start-here-v2.sh                  # ② 起容器时不加那条 bind
# ③ profile 的 power.mode 从 pstate 改成 sleep（等价"不管电源"）：
#    还没建档、用包内模板的话改你**要用那一份**（别拿 *.json 通配，两靶档会被一起改掉）：
sed -i 's/"mode": "pstate"/"mode": "sleep"/' run/profiles/flash-next-tp8-256k-nomtp.json
#    已经建好的档：用改档工具的 setfield 通道（power 不在 argv 里，v2 起才碰得到它）——
#      docker exec <容器> node /console-data/tmp/console-edit-profile-v2.cjs <profileId> setfield power.mode sleep
#    或者直接跑 bash run/configure-v1.sh，它的"电源托管方式"那一题就是干这个的。
```

代价：**没有这个库就没有 P-State 托管**，空闲时不会把卡拉到低功耗档。
包内两份 profile 模板默认都是 `power.mode=pstate`＋`gpus=0..7`（与官方模板一致），
`validateProfile` 里没有"关电源"这个选项，只有 `pstate` / `sleep` 两档。

## 文件缺失或换驱动时的自己取件

从任何已含该库的同族镜像提取（已实证）：

```bash
docker run --rm --entrypoint cat <含该库的镜像> /usr/local/nvidia/lib64/libnvidia-api.so.1 \
  > libnvidia-api.so.1
sha256sum libnvidia-api.so.1   # 过门禁才可用
```

## 红线

- 不要从不明来源下载同名文件、不过 sha 就 bind 进容器（供应链）。
- 该库只服务 P-State；引擎本体（加载/推理/控制台）不依赖它。
- 别把它当"性能项"：它不改吞吐。它决定的是面板肯不肯启引擎、以及空闲功率档。
