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
$ ./_build/native/debug/test/<pkg>.blackbox_test.exe
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

```bash
make diagnose    # 构建驱动并打印出问题的两处生成源码
make verify      # 命中问题 lane + 绕过 lane
make bug         # 只跑命中问题 lane
```

## 注意

- 本仓库**需要 `MOON_CC` 才能编译**（`cases.sh` 内部默认用 `FIX_CC=gcc`），
  因为姊妹仓库的归档器问题会挡住 native 编译：
  `moonbug-replay-native-build-fails-caused-by-lib-exe-archiver`。
  上游如果修了那个，用 `FIX_CC` 覆盖或直接去掉也可以。
- abort 会触发 core dump，且 `ulimit -c 0` 压不住（systemd-coredump 的 pipe 模式
  忽略 RLIMIT_CORE）。清理：`sudo coredumpctl vacuum --size=50M`。

## 环境

```
moon 0.1.20260907 (7aabba5 2026-09-07)
moonc v0.10.12+8a549c039-nightly (2026-09-06)
Linux x86-64
```
