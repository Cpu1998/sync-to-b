# Verdaccio storage 增量同步到电脑B

本目录是**电脑A（ Verdaccio 服务器）→ 电脑B（备份/离线机）** 的链式同步方案。
所有内容都使用**同一种包格式**，B端用**同一个脚本**应用，没有特殊的基线文件：

```
F-xxx.zip（全量包，含全部文件） ─ I-yyy.zip ─ I-zzz.zip ─ ...（增量包，只含变化）

电脑A（有最新 data）                      电脑B
─────────────────────                    ─────────────────────
..\data\（实时存储）                      ..\data\            ← 由包应用而来（与A端同构）
  │ make-increment.ps1                     ↑ apply-increment.ps1
  └─> increments\F-*.zip / I-*.zip         increments\F-*.zip / I-*.zip
      ───── U盘/共享拷过去 ─────>          （按 base 链自动按序应用，
                                             SHA256 校验通过才落地）
```

## 目录说明（本目录）

| 路径 | 作用 |
|---|---|
| `make-increment.ps1` | **A端**脚本：`-Full` 生成全量包；日常生成增量包 |
| `apply-increment.ps1` | **B端**脚本：应用包（需拷贝到电脑B） |
| `increments\` | 包输出目录（`F-*.zip` 全量 / `I-*.zip` 增量） |
| `state\state.txt` | A端同步状态（上次快照的完整文件清单，脚本自动维护，**勿手改**） |

## 一次性准备（电脑B）

在电脑B上按**与A端相同的结构**放置（路径同样选短，避免总路径超过 260 字符）：
`sync-to-b` 与 verdaccio 的存储目录 `data` 是同级目录，应用后数据直接落到
`..\data`，容器挂载的就是它：

```
D:\verdaccio\deploy\verdaccio_storage\
├── data\                     ← 由包应用而来（默认 = 脚本上级目录的 data）
└── sync-to-b\
    ├── apply-increment.ps1   ← 从A端本目录拷来（A端用 -Target 拷包时会自动带上）
    └── increments\
        └── F-xxxx.zip        ← A端生成的全量包（首次同步的起点）
```

放入全量包后运行：

```powershell
cd D:\verdaccio\deploy\verdaccio_storage\sync-to-b
.\apply-increment.ps1
```

脚本自动解压校验全量包生成 `..\data\`，并记录进度。
（数据要放别处时加 `-DataDir D:\某\路径`。）

## 日常流程

**电脑A**（在 `deploy\verdaccio_storage\sync-to-b` 下运行，可加 `-PauseContainer` 暂停容器保证一致性）：

```powershell
# 方式一：生成到本目录 increments\，自己拷走
.\make-increment.ps1

# 方式二：生成后自动拷到U盘/网络共享（首次会顺带把B端脚本也带上）
.\make-increment.ps1 -Target E:\
```

**电脑B**：把包放入 `D:\verdaccio\deploy\verdaccio_storage\sync-to-b\increments\`，运行：

```powershell
cd D:\verdaccio\deploy\verdaccio_storage\sync-to-b
.\apply-increment.ps1        # 可先加 -Plan 预览将应用哪些包
```

## 可靠性机制

- **链校验**：每个包的 `inc.meta` 记录 `base=`（上一包ID，全量包为空）与 `type=full|incremental`。
  B端只应用能与当前状态接上的包；缺中间包、乱序、缺全量包都会被明确报出，**不会应用错**。
  若现链接不上而收件箱里有**更新的全量包**（如 `-Full` 重新对齐生成的新链头），则自动改用它
  重新对齐（只取最新一个、每次运行至多一次，旧全量包不会被应用）。
- **SHA256 校验**：A端打包时逐文件计算哈希写入 `inc.meta`；B端先整包解压到临时目录、
  全部校验通过才落地，防U盘拷贝损坏造成半新半旧。
- **失败可重入**：A端个别文件被占用复制失败时不计入清单，下次自动重试；B端应用中途
  失败时包留在原地，直接重跑（应用操作可安全重复）。
- **全量包镜像收敛**：应用全量包时，data 中不在其清单内的文件会被清理，因此无论B端
  data 之前是什么状态，应用后都与该全量包完全一致。
- **删除同步**：A端删掉的文件记录在增量包 `[deleted]` 清单，B端应用时一并删除
  （并清理变空目录）。
- **精确比对**：A端日常增量与状态文件「大小+精确修改时间」比对，全量扫描秒级完成。

## 电脑A定时自动备份（可选）

管理员 PowerShell（路径按实际调整）：

```powershell
$dir = 'D:\verdaccio\deploy\verdaccio_storage\sync-to-b'
$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
  -Argument ('-NoProfile -ExecutionPolicy Bypass -File "{0}\make-increment.ps1" -PauseContainer' -f $dir)
$trigger = New-ScheduledTaskTrigger -Daily -At '02:00'
Register-ScheduledTask -TaskName 'Verdaccio 增量同步到电脑B' -Action $action -Trigger $trigger
```

（若U盘常插，可把 `-Target E:\` 加进参数，包直接落U盘。）

## 常见问题

- **漏带了一次增量包会怎样？** B端链校验会拒绝后面的包并提示缺哪一包；把它补拷过来即可。
- **想重新做一次全量？** A端运行 `.\make-increment.ps1 -Full` 生成新的全量包，B端把该包
  放入 `increments\` 应用即可（镜像清理自动对齐，旧的 data 内容无需手动处理）；
  之后的增量自动接在新全量包之后。
- **B端也在跑 verdaccio？** 应用前 `docker stop verdaccio`，完成后 `docker start verdaccio`。
- **旧包清理？** A端 `-Keep N`（默认20）自动清理；B端应用完的包在
  `increments\applied\`，确认无回放需求后可手动删。
- **A端 state\state.txt 丢失？** 直接 `.\make-increment.ps1 -Full` 生成新全量包（B端
  应用它重新对齐），链从新全量包继续。
- **`.sync-state.json` 是什么？需要拷吗？** B端进度文件（记录已应用到哪个包），
  `apply-increment.ps1` 首次应用时**自动生成**、自动维护，**不要从A端或别的机器拷来**——
  带着旧进度的文件会让脚本以为已应用到某包，从而拒绝/跳过本该应用的包。A端本目录若出现
  该文件属测试残留，直接删除。
- **与仓库根目录的 backup-storage.ps1 什么关系？** 互不影响：那是A端本机 `backups\`
  备份链；本方案专管同步到电脑B。
