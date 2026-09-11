# 生成的 native 测试驱动不做参数校验

SHELL  := /bin/bash
MOON   ?= $(HOME)/.moon/bin/moon
FIX_CC ?= gcc

export MOON FIX_CC

.PHONY: help all verify bug workaround fixed cases diagnose clean

help:
	@printf '%s\n' \
	  '测试驱动 parse_args 裸索引 argv' \
	  '' \
	  '  make verify      命中问题 lane + 绕过 lane，本地应全绿' \
	  '  make bug         命中问题 lane：畸形参数 → exit 134' \
	  '  make workaround  绕过 lane：file:start-end 形状 → exit 0' \
	  '  make fixed       修复验收 lane：畸形参数不再 abort（上游修好后转 PASS）' \
	  '  make cases       列出用例' \
	  '  make diagnose    打印驱动源码里出问题的两处' \
	  '  make clean       清掉 _build' \
	  '' \
	  "变量： MOON=$(MOON)   FIX_CC=$(FIX_CC)"

all: verify

verify: bug workaround

bug:
	@./cases.sh lane bug

workaround:
	@./cases.sh lane workaround

fixed:
	@./cases.sh lane fixed

cases:
	@./cases.sh list

diagnose:
	@./cases.sh diagnose

clean:
	@rm -rf _build
	@echo 'cleaned: _build'
