# 生成的 native 测试驱动不做参数校验 —— 用 .mbtx 驱动，几乎不靠 shell

SHELL  := /bin/bash
MOON   ?= $(HOME)/.moon/bin/moon
FIX_CC ?= gcc

export MOON FIX_CC

# MOON_CC 是给「编译这个 .mbtx 自己」用的；脚本内部还会把它传给子进程 moon。
RUN = MOON_CC="$(FIX_CC)" "$(MOON)" run --target native cases.mbtx --

.PHONY: help all verify bug workaround fixed cases diagnose clean

help:
	@printf '%s\n' \
	  '测试驱动 parse_args 裸索引 argv（.mbtx 驱动）' \
	  '' \
	  '  make verify      命中问题 lane + 绕过 lane，本地应全绿' \
	  '  make bug         命中问题 lane：畸形参数 → exit 134' \
	  '  make workaround  绕过 lane：file:start-end 形状 → exit 0' \
	  '  make fixed       修复验收 lane：畸形参数不再 abort（上游修好后转 PASS）' \
	  '  make cases       列出用例' \
	  '  make diagnose    打印生成源码里出问题的两行' \
	  '  make clean       清掉 _build' \
	  '' \
	  '直接跑： $(RUN) <子命令>' \
	  "变量： MOON=$(MOON)   FIX_CC=$(FIX_CC)"

all: verify

verify:
	@$(RUN) verify

bug:
	@$(RUN) bug

workaround:
	@$(RUN) workaround

fixed:
	@$(RUN) fixed

cases:
	@$(RUN) list

diagnose:
	@$(RUN) diagnose

clean:
	@rm -rf _build
	@echo 'cleaned: _build'
