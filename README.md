# 生成的 native 测试驱动不做参数校验

`moon test --target native` 会生成 `__generated_driver_for_*_test.mbt`。它在
`parse_args` 里直接裸索引 argv，没有任何长度检查，于是**任何不是
`file:start-end` 形状的参数都会 panic → abort**，退出码 134 并留下 core。

## 出问题的两处

`_build/native/debug/test/__generated_driver_for_blackbox_test.mbt`：

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
  ...
}
```

两条崩溃栈分别指回这两行：

- 不带参数 → `PanicError at ...parse_args (generated:331)`
- `--help`   → `PanicError at @moonbitlang/core/array.Array::at[String] (array.mbt:187)`，栈里是 337 行

## 现象

```bash
$ moon test --target native                     # 构建正常，测试通过
$ ./_build/native/debug/test/drv.blackbox_test.exe
PanicError
    at @repro/drv_blackbox_test.moonbit_test_driver_internal_native_parse_args (...:331)
    at moonbit_main (...:490)
$ echo $?
134
```

## 触发矩阵

| argv | exit |
|---|---|
| 不带参数 | **134** |
| `--help` | **134** |
| `foo` | **134** |
| `a_test.mbt`（只有文件名） | **134** |
| `a_test.mbt:1-3` | 0 |
| `a_test.mbt:1-3/a_test.mbt:1-3` | 0 |

即：给格式正确的区间就正常，其余一律 abort。3/3 确定性复现。

## 复现

harness 是一个单文件 `.mbtx`：`moon run cases.mbtx -- <子命令>`，没有 `cases.sh`。
它自己起进程、拿退出码、比对预期，外壳里几乎没有逻辑。

```bash
make verify      # 命中问题 lane + 绕过 lane，本地应全绿
make bug         # 只跑命中问题 lane
make workaround  # 只跑绕过 lane
make fixed       # 修复验收 lane（上游修好后转 PASS）
make cases       # 列出用例及其自带预期
make diagnose    # 打印生成源码里出问题的两行
```

等价直跑：

```bash
moon run cases.mbtx -- verify
moon run cases.mbtx -- bug
```

harness 用 `moonbitlang/async@0.21.3` 的 process API
（`collect_output` 直接返回退出码与 stdout/stderr），首次运行会从 mooncakes.io 取该依赖。

因为 `.mbtx` 的依赖要靠 registry 索引解析，**全新环境需要先同步一次索引**。`make` 的
各 lane 都依赖 `make deps`（内部 `moon update --quiet`），所以一般不用手动做；
离线时 `deps` 会失败但不中断，改用本地缓存继续。

## 用例

| case | argv | 期望 |
|---|---|---|
| `no-args` | 不带参数 | 134 |
| `help` | `--help` | 134 |
| `plain-word` | `foo` | 134 |
| `file-only` | `a_test.mbt` | 134 |
| `well-formed` | `a_test.mbt:1-3` | 0 |
| `two-ranges` | `a_test.mbt:1-3/a_test.mbt:1-3` | 0 |

命中问题 lane 还额外要求 stderr 里出现 `PanicError`，避免把「恰好也是 134」当成通过。

## 注意

- **需要 `MOON_CC`**：本仓库要编译 native。`Makefile` 默认按 `FIX_CC=gcc` 传入，
  可用 `make FIX_CC=clang ...` 覆盖。原因见姊妹仓库
  `moonbug-replay-native-build-fails-caused-by-lib-exe-archiver`
  —— PATH 里存在名为 `cl` 的可执行文件时，native 编译会被误判成 MSVC 环境。
- abort 会触发 core dump，且 `ulimit -c 0` 压不住（systemd-coredump 的 pipe 模式
  忽略 RLIMIT_CORE）。清理：`sudo coredumpctl vacuum --size=50M`。

## 环境

```
moon 0.1.20260907 (7aabba5 2026-09-07)
moonc v0.10.12+8a549c039-nightly (2026-09-06)
Linux x86-64
```
