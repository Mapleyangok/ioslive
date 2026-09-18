#!/usr/bin/env bash
# =====================================================================
# ELivePusher iOS 插件构建验证脚本（macOS 端）
#
# 功能：
#   1. 静态校验：ios-plugin-src 源码齐全性、package.json iOS 配置
#   2. 产物校验：nativeplugins/ELivePusher/ios/ 下三个 framework 是否就位
#   3. 产物深度校验（macOS）：arm64 架构 / 静态库类型 / Headers / 关键符号
#      —— 含 GPUImage 符号检查（LFLiveKit 2.6 依赖 GPUImage，必须已合并）
#   4. macOS 环境：校验 Xcode/CocoaPods/xcodeproj 构建链；
#      加 --build 参数可直接执行完整编译（调用 ios-plugin-src/build_ios_framework.sh）
#
# 用法（macOS 终端，在项目根目录）：
#   ./scripts/verify-ios.sh              # 仅验证（含产物深度校验）
#   UNI_IOS_SDK_DIR=/path/to/sdk ./scripts/verify-ios.sh --build
#                                        # 验证 + 触发完整编译 + 复验产物
# （非 macOS 环境仅支持静态校验部分）
# =====================================================================
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SRC_DIR="${ROOT}/ios-plugin-src"
OUT_DIR="${ROOT}/nativeplugins/ELivePusher/ios"
FAIL=0

check() { # check <描述> <0/1> <提示>
  if [ "$2" -eq 0 ]; then
    echo "  [OK]   $1"
  else
    echo "  [FAIL] $1"
    [ -n "${3:-}" ] && echo "         -> $3"
    FAIL=$((FAIL+1))
  fi
}

echo "==== ELivePusher iOS 插件验证 ===="

# ------------------------------------------------------- 1. 源码齐全性
echo ""
echo "[1] ios-plugin-src 源码齐全性"
required=(
  "ELivePusherModule.h"   "ELivePusherModule.m"
  "ELivePusherComponent.h" "ELivePusherComponent.m"
  "ELivePusherManager.h"  "ELivePusherManager.m"
  "ELiveCorePusher.h"
  "ELiveUrlParser.h"      "ELiveUrlParser.m"
  "ELiveSrsSignaling.h"   "ELiveSrsSignaling.m"
  "ELiveWebRTCPusher.h"   "ELiveWebRTCPusher.m"
  "ELiveRTMPPusher.h"     "ELiveRTMPPusher.m"
  "build_ios_framework.sh"
)
for f in "${required[@]}"; do
  check "源码 $f" $([ -f "${SRC_DIR}/${f}" ] && echo 0 || echo 1) "缺失文件"
done

# ------------------------------------------------------- 2. package.json iOS 配置
echo ""
echo "[2] package.json iOS 配置"
PKG="${ROOT}/nativeplugins/ELivePusher/package.json"
check "package.json 存在" $([ -f "$PKG" ] && echo 0 || echo 1) ""
if [ -f "$PKG" ] && command -v python3 >/dev/null 2>&1; then
  python3 - "$PKG" <<'PYEOF'
import json, sys
pkg = json.load(open(sys.argv[1], encoding='utf-8'))
ios = pkg.get('_dp_nativeplugin', {}).get('ios', {})
names = {p.get('name'): p.get('class') for p in ios.get('plugins', [])}
fw = ios.get('frameworks', [])
embed = ios.get('embedFrameworks', [])
ok = True
def require(cond, msg):
    global ok
    if not cond:
        ok = False
        print("  [FAIL] " + msg)
    else:
        print("  [OK]   " + msg)
require(ios.get('integrateType') == 'framework', "ios.integrateType=framework")
require(names.get('ELivePusher-Module') == 'ELivePusherModule', "module 注册名/类名 ELivePusher-Module -> ELivePusherModule")
require(names.get('elive-pusher-view') == 'ELivePusherComponent', "component 注册名/类名 elive-pusher-view -> ELivePusherComponent")
require('WebRTC.framework' in fw, "frameworks 含 WebRTC.framework")
require('LFLiveKit.framework' in fw, "frameworks 含 LFLiveKit.framework")
require('WebRTC.framework' in embed, "embedFrameworks 含 WebRTC.framework")
require('NSCameraUsageDescription' in ios.get('privacies', []), "privacies 含相机描述")
require('NSMicrophoneUsageDescription' in ios.get('privacies', []), "privacies 含麦克风描述")
sys.exit(0 if ok else 1)
PYEOF
  [ $? -eq 0 ] || FAIL=$((FAIL+1))
else
  echo "  [SKIP] 未检测到 python3，跳过 iOS 配置细项解析（Windows 环境可在 PowerShell 中验证）"
fi

# ------------------------------------------------------- 3. 编译产物存在性
echo ""
echo "[3] 编译产物（nativeplugins/ELivePusher/ios/）"
for fw in ELivePusher.framework WebRTC.framework LFLiveKit.framework; do
  if [ -d "${OUT_DIR}/${fw}" ]; then
    # framework 内必须有实际二进制/文件，防止空目录
    has_file=$(find "${OUT_DIR}/${fw}" -type f | head -n 1)
    check "产物 ${fw}" $([ -n "$has_file" ] && echo 0 || echo 1) "framework 为空目录"
  else
    check "产物 ${fw}" 1 "未找到，需在 macOS 上运行 ios-plugin-src/build_ios_framework.sh 编译"
  fi
done

OS="$(uname -s)"

# ------------------------------------- 4. 产物深度校验（macOS 工具链）
if [ "$OS" = "Darwin" ] && [ -d "${OUT_DIR}" ]; then
  echo ""
  echo "[4] 产物深度校验（架构 / 类型 / Headers / 关键符号）"

  # --- 4.1 ELivePusher.framework（插件本体，静态库） ---
  EPB="${OUT_DIR}/ELivePusher/ELivePusher"
  if [ -f "${EPB}" ]; then
    lipo -info "${EPB}" 2>/dev/null | grep -q 'arm64' \
      && echo "  [OK]   ELivePusher 二进制含 arm64（真机）架构" \
      || { echo "  [FAIL] ELivePusher 二进制缺少 arm64 架构（检查 build 脚本 ARCHS 设置）"; FAIL=$((FAIL+1)); }
    file "${EPB}" | grep -qi 'current ar archive' \
      && echo "  [OK]   ELivePusher 为静态库（ar archive）" \
      || { echo "  [FAIL] ELivePusher 不是静态库（云打包要求 Mach-O 静态库）"; FAIL=$((FAIL+1)); }
    nm "${EPB}" 2>/dev/null | grep -qF '_OBJC_CLASS_$_ELivePusherModule' \
      && echo "  [OK]   含 ELivePusherModule 类符号" \
      || { echo "  [FAIL] 未找到 ELivePusherModule 类符号（Module 源码未编入？）"; FAIL=$((FAIL+1)); }
    nm "${EPB}" 2>/dev/null | grep -qF '_OBJC_CLASS_$_ELivePusherComponent' \
      && echo "  [OK]   含 ELivePusherComponent 类符号" \
      || { echo "  [FAIL] 未找到 ELivePusherComponent 类符号"; FAIL=$((FAIL+1)); }
    for h in ELivePusherModule.h ELivePusherComponent.h ELiveCorePusher.h; do
      check "ELivePusher Headers/${h}" $([ -f "${OUT_DIR}/ELivePusher/Headers/${h}" ] && echo 0 || echo 1) "公开头文件缺失"
    done
  else
    echo "  [SKIP] ELivePusher.framework 二进制缺失（未构建），跳过"
  fi

  # --- 4.2 WebRTC.framework（GoogleWebRTC 1.1.32000，静态库） ---
  WB="${OUT_DIR}/WebRTC/WebRTC"
  if [ -f "${WB}" ]; then
    lipo -info "${WB}" 2>/dev/null | grep -q 'arm64' \
      && echo "  [OK]   WebRTC 二进制含 arm64 架构" \
      || { echo "  [FAIL] WebRTC 二进制缺少 arm64 架构"; FAIL=$((FAIL+1)); }
    file "${WB}" | grep -qi 'current ar archive' \
      && echo "  [OK]   WebRTC 为静态库（ar archive）" \
      || { echo "  [FAIL] WebRTC 不是静态库（云打包需静态链接 WebRTC.framework）"; FAIL=$((FAIL+1)); }
    nm "${WB}" 2>/dev/null | grep -qF '_OBJC_CLASS_$_RTCPeerConnectionFactory' \
      && echo "  [OK]   含 RTCPeerConnectionFactory 类符号" \
      || { echo "  [FAIL] 未找到 RTCPeerConnectionFactory 类符号"; FAIL=$((FAIL+1)); }
    check "WebRTC Headers/WebRTC.h" $([ -f "${OUT_DIR}/WebRTC/Headers/WebRTC.h" ] && echo 0 || echo 1) "伞头缺失"
  else
    echo "  [SKIP] WebRTC.framework 二进制缺失（未构建），跳过"
  fi

  # --- 4.3 LFLiveKit.framework（2.6 + GPUImage 合并，静态库） ---
  LB="${OUT_DIR}/LFLiveKit/LFLiveKit"
  if [ -f "${LB}" ]; then
    lipo -info "${LB}" 2>/dev/null | grep -q 'arm64' \
      && echo "  [OK]   LFLiveKit 二进制含 arm64 架构" \
      || { echo "  [FAIL] LFLiveKit 二进制缺少 arm64 架构"; FAIL=$((FAIL+1)); }
    file "${LB}" | grep -qi 'current ar archive' \
      && echo "  [OK]   LFLiveKit 为静态库（ar archive）" \
      || { echo "  [FAIL] LFLiveKit 不是静态库"; FAIL=$((FAIL+1)); }
    nm "${LB}" 2>/dev/null | grep -qF '_OBJC_CLASS_$_LFLiveSession' \
      && echo "  [OK]   含 LFLiveSession 类符号" \
      || { echo "  [FAIL] 未找到 LFLiveSession 类符号"; FAIL=$((FAIL+1)); }
    # GPUImage 是 LFLiveKit 2.6 的独立 pod 依赖，必须已被 libtool 合并进本 framework，
    # 否则云打包链接 ELiveRTMPPusher 时会报 undefined symbols
    nm "${LB}" 2>/dev/null | grep -qF '_OBJC_CLASS_$_GPUImageVideoCamera' \
      && echo "  [OK]   含 GPUImageVideoCamera 类符号（GPUImage 已合并）" \
      || { echo "  [FAIL] 未找到 GPUImage 符号（libGPUImage.a 未合并，云打包会链接失败）"; FAIL=$((FAIL+1)); }
    check "LFLiveKit Headers/LFLiveKit.h（转发伞头）" \
      $([ -f "${OUT_DIR}/LFLiveKit/Headers/LFLiveKit.h" ] && echo 0 || echo 1) "伞头缺失"
    check "LFLiveKit Headers/LFLiveKit/LFLiveSession.h" \
      $([ -f "${OUT_DIR}/LFLiveKit/Headers/LFLiveKit/LFLiveSession.h" ] && echo 0 || echo 1) "头文件树缺失"
  else
    echo "  [SKIP] LFLiveKit.framework 二进制缺失（未构建），跳过"
  fi
else
  if [ "$OS" != "Darwin" ]; then
    echo ""
    echo "[4] 产物深度校验"
    echo "  [SKIP] 非 macOS 环境，缺少 lipo/file/nm 工具链，跳过产物深度校验"
  fi
fi

# ------------------------------------------------------- 5. macOS 构建链
echo ""
echo "[5] 构建环境（当前系统: ${OS}）"
if [ "$OS" = "Darwin" ]; then
  command -v xcodebuild >/dev/null 2>&1 && echo "  [OK]   Xcode (xcodebuild)" || { echo "  [FAIL] 未安装 Xcode"; FAIL=$((FAIL+1)); }
  command -v pod        >/dev/null 2>&1 && echo "  [OK]   CocoaPods" || { echo "  [FAIL] 未安装 CocoaPods (sudo gem install cocoapods)"; FAIL=$((FAIL+1)); }
  ruby -e 'require "xcodeproj"' >/dev/null 2>&1 && echo "  [OK]   xcodeproj gem" || { echo "  [FAIL] 缺少 xcodeproj gem (gem install xcodeproj)"; FAIL=$((FAIL+1)); }
  if [ -z "${UNI_IOS_SDK_DIR:-}" ]; then
    echo "  [WARN] 未设置 UNI_IOS_SDK_DIR（DCloud iOS 离线 SDK 目录，编译时必需）"
  else
    echo "  [OK]   UNI_IOS_SDK_DIR=${UNI_IOS_SDK_DIR}"
  fi
  if [ "${1:-}" = "--build" ]; then
    echo ""
    echo "[6] 执行完整编译（build_ios_framework.sh）..."
    chmod +x "${SRC_DIR}/build_ios_framework.sh"
    if bash "${SRC_DIR}/build_ios_framework.sh"; then
      echo "  [OK]   编译完成，产物已输出到 ${OUT_DIR}"
      echo ""
      echo "[7] 编译后复验产物..."
      for fw in ELivePusher.framework WebRTC.framework LFLiveKit.framework; do
        check "产物 ${fw}" $([ -d "${OUT_DIR}/${fw}" ] && echo 0 || echo 1) "编译后仍缺失"
      done
    else
      echo "  [FAIL] 编译失败，请查看上方日志"
      FAIL=$((FAIL+1))
    fi
  fi
else
  echo "  [SKIP] 非 macOS 环境，无法校验/执行 iOS 编译；framework 产物需在 Mac 上生成"
fi

# ------------------------------------------------------- 汇总
echo ""
if [ "$FAIL" -eq 0 ]; then
  echo "==== 验证通过：iOS 插件包就绪，可提交 HBuilderX 云打包（自定义基座） ===="
  exit 0
else
  echo "==== 验证失败：${FAIL} 项不通过，请按提示修复 ===="
  exit 1
fi
