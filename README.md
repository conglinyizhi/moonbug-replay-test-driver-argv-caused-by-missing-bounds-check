# 生成的 native 测试驱动裸索引 argv，畸形参数即 abort

## 1. 这个 bug 是什么

### 原因

`moon test --target native` 会生成 `__generated_driver_for_*_test.mbt`。它的
`parse_args` 直接裸索引 argv，没有任何长度检查：

```moonbit
let cli_args = moonbit_test_driver_internal_get_cli_args_ffi()
let test_args = moonbit_test_driver_internal_split_mbt_string(
    cli_args[1].to_string(),     // 331 行：没查 cli_args.length()
    '/',
)
...
for arg in test_args {
  let file_and_range = moonbit_test_driver_internal_split_mbt_string(arg, ':')
  let file  = file_and_range[0]
  let range = file_and_range[1]    // 337 行：没查 file_and_range.length()
```

于是**任何不是 `file:start-end` 形状的参数都会 panic → abort**，两条崩溃栈分别指回这两行：

- 不带参数 → `PanicError at ...parse_args (generated:331)`
- `--help`   → `PanicError at @moonbitlang/core/array.Array::at[String] (array.mbt:187)`，栈里是 337 行

结果是 exit 134（`Signal: 6 (ABRT)`）并留下 core。跑 `moon test --target native` 本身
是正常的 —— 崩的是它**生成出来的那个驱动**，崩在参数解析，不在测试内容。

### 复现平台

| 平台 | moon 版本 | 结果 |
|---|---|---|
| 本机 Linux x86-64 | 0.1.20260907（7aabba5，2026-09-07） | 复现 |
| GitHub Actions `ubuntu-24.04` | 0.1.20260904（94521db，2026-09-04） | 复现（`hit-the-bug` job 绿） |

驱动是 moon 按自己的模板生成的，所以与项目内容无关 —— 一个只有 1 个测试的工程就够。

## 2. 快速复现

### 最少需要什么

| 文件 | 内容 |
|---|---|
| `moon.mod` | `name = "repro/drv"` / `version = "0.1.0"` / `preferred_target = "native"` |
| `moon.pkg` | 空（仅用于标记这是一个 package） |
| `a.mbt` | 1 个库函数 |
| `a_test.mbt` | 1 个测试（3 行） |

```bash
moon test --target native                        # 构建，顺带生成测试驱动
./_build/native/debug/test/drv.blackbox_test.exe # 不带参数 → exit 134
```

第一行在部分机器上需要 `MOON_CC`（原因见姊妹仓库
`moonbug-replay-native-build-fails-caused-by-lib-exe-archiver`）：

```bash
MOON_CC=gcc moon test --target native
```

### 文件清单：哪些和这个 bug 有关

| 文件 | 行数 | 和 bug 的关系 |
|---|---|---|
| `moon.mod` | 5 | **必需** —— 标记模块；`preferred_target = "native"` 让测试驱动走 native |
| `moon.pkg` | 0 | **必需** —— 标记 package |
| `a.mbt` | 1 | **必需** —— 一个库函数 |
| `a_test.mbt` | 3 | **必需** —— 有测试才会生成那个驱动；内容本身无所谓 |
| `cases.mbtx` | 249 | **与 bug 无关** —— 可执行规格，负责断言 |
| `Makefile` | 57 | **与 bug 无关** —— 调用规格的入口 |
| `.github/workflows/repro.yml` | 46 | **与 bug 无关** —— CI |
| `README.md` | 124 | **与 bug 无关** —— 本文档 |

最小复现就是前 4 行（9 行代码）+ 上面那两条命令；后 4 行删掉照样复现。

## 3. 其他

### 触发矩阵

| argv | exit |
|---|---|
| 不带参数 | **134** |
| `--help` | **134** |
| `foo` | **134** |
| `a_test.mbt`（只有文件名） | **134** |
| `a_test.mbt:1-3` | 0 |
| `a_test.mbt:1-3/a_test.mbt:1-3` | 0 |

即：给格式正确的区间就正常，其余一律 abort。

### 可执行规格

单文件 `.mbtx`：`moon run cases.mbtx -- <子命令>`。它先构建驱动，再用 `@process`
直接起进程、拿退出码比对预期。

```bash
make verify      # bug lane + workaround lane，本地应全绿
make bug         # 只跑命中问题 lane
make workaround  # 只跑绕过 lane
make fixed       # 修复验收 lane（上游修好后转 PASS）
make cases       # 列出用例
make diagnose    # 打印生成源码里出问题的两行
make deps        # 同步 registry 索引（首次运行需要，各 lane 会自动先跑）
```

**注意：复现本体零依赖，依赖（`moonbitlang/async@0.21.3`）只出现在跑断言的时候。**

### 用例

| case | argv | 期望 |
|---|---|---|
| `no-args` | 不带参数 | 134 |
| `help` | `--help` | 134 |
| `plain-word` | `foo` | 134 |
| `file-only` | `a_test.mbt` | 134 |
| `well-formed` | `a_test.mbt:1-3` | 0 |
| `two-ranges` | `a_test.mbt:1-3/a_test.mbt:1-3` | 0 |

命中问题 lane 还额外要求 stderr 里出现 `PanicError`，避免把「恰好也是 134」当成通过。

### CI

三个 job：`hit-the-bug` / `workaround` / `upstream-fix-status`（允许失败）。

### 注意

- 需要 `MOON_CC` 时用 `make FIX_CC=clang ...` 覆盖；`Makefile` 默认传 `gcc`。
- abort 会触发 core dump，且 `ulimit -c 0` 压不住（systemd-coredump 的 pipe 模式
  忽略 `RLIMIT_CORE`）。清理：`sudo coredumpctl vacuum --size=50M`。

### 环境

```
moon 0.1.20260907 (7aabba5 2026-09-07)
moonc v0.10.12+8a549c039-nightly (2026-09-06)
Linux x86-64
```
