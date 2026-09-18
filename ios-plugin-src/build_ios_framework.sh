#!/usr/bin/env bash
# =====================================================================
# ELivePusher iOS 原生插件编译脚本（只能在 macOS + Xcode + CocoaPods 环境运行）
#
# 功能：
#   1. 以本目录（ios-plugin-src）下的 .h/.m 源码生成静态库 Xcode 工程；
#   2. 通过 CocoaPods 引入 GoogleWebRTC 1.1.32000 与 LFLiveKit 2.6；
#   3. xcodebuild -sdk iphoneos -arch arm64 编译（真机 arm64）；
#   4. 组装产物并输出到 ../nativeplugins/ELivePusher/ios/：
#        - ELivePusher.framework   （插件本体，静态 framework）
#        - WebRTC.framework        （GoogleWebRTC pod 提供的 vendored 静态 framework，直接拷贝）
#        - LFLiveKit.framework     （由 LFLiveKit 源码 pod 编译出的静态 lib 组装）
#
# 用法（在 macOS 终端执行）：
#   export UNI_IOS_SDK_DIR=/path/to/uni-app-ios-sdk   # DCloud iOS 离线打包 SDK 目录
#                                                     # （需内含 inc/ 或 Headers/ 头文件目录，
#                                                     #  其中应有 DCUniModule.h / DCUniComponent.h）
#   ./build_ios_framework.sh
#
# 环境要求：
#   - Xcode 12+（含模拟器以外的 iphoneos SDK）
#   - CocoaPods 1.9+（use_frameworks! :linkage => :static 需要）
#   - Ruby（系统自带即可，脚本使用随 CocoaPods 附带的 xcodeproj gem 生成工程）
#
# 脚本可重复执行（每次执行前清空 build/ 工作目录与旧产物）。
# =====================================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${SCRIPT_DIR}/build"
OUT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)/nativeplugins/ELivePusher/ios"

# --------------------------------------------------------------- 0. 环境检查
if [ -z "${UNI_IOS_SDK_DIR}" ]; then
  echo "[错误] 请先设置环境变量 UNI_IOS_SDK_DIR，指向 DCloud uni-app iOS 离线打包 SDK 解压目录"
  echo "       （目录内需包含 inc/ 或 Headers/ 头文件目录，如 DCUniModule.h 等）"
  exit 1
fi

SDK_INC="${UNI_IOS_SDK_DIR}/inc"
if [ ! -d "${SDK_INC}" ]; then
  SDK_INC="${UNI_IOS_SDK_DIR}/Headers"
fi
if [ ! -d "${SDK_INC}" ]; then
  echo "[错误] 未在 ${UNI_IOS_SDK_DIR} 下找到 inc/ 或 Headers/ 头文件目录"
  exit 1
fi

command -v pod  >/dev/null 2>&1 || { echo "[错误] 未安装 CocoaPods（sudo gem install cocoapods）"; exit 1; }
command -v ruby >/dev/null 2>&1 || { echo "[错误] 未安装 Ruby"; exit 1; }
ruby -e 'require "xcodeproj"' 2>/dev/null || {
  echo "[错误] 缺少 xcodeproj gem（随 CocoaPods 附带，请确认 gem 环境：gem install xcodeproj）"
  exit 1
}

echo "==> DCloud SDK 头文件目录: ${SDK_INC}"
echo "==> 产物输出目录: ${OUT_DIR}"

# ------------------------------------------------------- 1. 清理并准备工作目录
rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}/ELivePusher" "${OUT_DIR}"

# --------------------------------------------------------------- 2. 拷贝源码
cp "${SCRIPT_DIR}"/*.h "${SCRIPT_DIR}"/*.m "${BUILD_DIR}/ELivePusher/"

# --------------------------------------------------------------- 3. Podfile
cat > "${BUILD_DIR}/Podfile" <<'PODFILE'
# ELivePusher 依赖：WebRTC(SRS 信令推流) 与 LFLiveKit(RTMP 推流)
platform :ios, '12.0'
source 'https://cdn.cocoapods.org/'

target 'ELivePusher' do
  # 静态链接：插件以静态 framework 形式提供给 HBuilderX 云打包
  use_frameworks! :linkage => :static

  pod 'GoogleWebRTC', '1.1.32000'
  pod 'LFLiveKit', '2.6'
end
PODFILE

# ------------------------------------------- 4. 生成静态库 Xcode 工程（xcodeproj gem）
cat > "${BUILD_DIR}/create_project.rb" <<RUBY
require 'xcodeproj'

project = Xcodeproj::Project.new('ELivePusher.xcodeproj')
target  = project.new_target(:static_library, 'ELivePusher', :ios, '12.0')

group        = project.main_group.new_group('ELivePusher', '.')
sources      = group.new_group('Sources', 'ELivePusher')
headers      = group.new_group('Headers', 'ELivePusher')
Dir['ELivePusher/*.m'].sort.each { |f| sources.new_reference(File.basename(f)) }
Dir['ELivePusher/*.h'].sort.each { |f| headers.new_reference(File.basename(f)) }
target.add_file_references(sources.files)

sdk_inc = ENV['UNI_IOS_SDK_DIR']
sdk_inc_h = File.directory?(File.join(sdk_inc.to_s, 'inc')) ? File.join(sdk_inc, 'inc') : File.join(sdk_inc.to_s, 'Headers')

# 头文件搜索路径：inc/Headers 根目录 + 其全部一级子目录
# （DCloud SDK 头按库分层存放：DCUniModule.h 在 inc/DCUni/，Weex 头在 inc/weexHeader/ 等）
search_paths = [sdk_inc_h]
if File.directory?(sdk_inc_h)
  Dir[File.join(sdk_inc_h, '*')].select { |p| File.directory?(p) }.each { |d| search_paths << d }
end
quoted_paths = search_paths.map { |p| %("#{p}") }.join(' ')

target.build_configurations.each do |cfg|
  cfg.build_settings['HEADER_SEARCH_PATHS']        = "$(inherited) #{quoted_paths}"
  cfg.build_settings['CLANG_ENABLE_MODULES']       = 'YES'
  cfg.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '12.0'
  cfg.build_settings['ARCHS']                      = 'arm64'
  cfg.build_settings['ONLY_ACTIVE_ARCH']           = 'NO'
  cfg.build_settings['GCC_C_LANGUAGE_STANDARD']    = 'gnu11'
  cfg.build_settings['CLANG_ENABLE_OBJC_ARC']      = 'YES'
end

# 为各目标生成 scheme，便于 xcodebuild 按 scheme 编译
project.recreate_user_schemes
project.save
RUBY

echo "==> 生成 Xcode 工程..."
(cd "${BUILD_DIR}" && UNI_IOS_SDK_DIR="${UNI_IOS_SDK_DIR}" ruby create_project.rb)

# --------------------------------------------------------------- 5. pod install + 编译
echo "==> pod install（首次运行需联网拉取依赖，可能较慢）..."
(cd "${BUILD_DIR}" && pod install)

echo "==> 编译插件静态库（iphoneos / arm64 / Release）..."
(cd "${BUILD_DIR}" && xcodebuild \
  -workspace ELivePusher.xcworkspace \
  -scheme ELivePusher \
  -configuration Release \
  -sdk iphoneos -arch arm64 \
  CONFIGURATION_BUILD_DIR="${BUILD_DIR}/products" \
  build)

# --------------------------------------------------- 6. 组装 ELivePusher.framework
echo "==> 组装 ELivePusher.framework..."
FW="${OUT_DIR}/ELivePusher.framework"
rm -rf "${FW}"
mkdir -p "${FW}/Headers"
LIB_A="${BUILD_DIR}/products/libELivePusher.a"
if [ ! -f "${LIB_A}" ]; then
  LIB_A=$(find "${BUILD_DIR}/products" -name "libELivePusher.a" | head -1)
fi
if [ -z "${LIB_A}" ]; then
  echo "[错误] 未找到编译产物 libELivePusher.a"
  exit 1
fi
cp "${LIB_A}" "${FW}/ELivePusher"
# 对外公开头文件（模块与组件）
cp "${SCRIPT_DIR}/ELivePusherModule.h"    "${FW}/Headers/"
cp "${SCRIPT_DIR}/ELivePusherComponent.h" "${FW}/Headers/"
cp "${SCRIPT_DIR}/ELiveCorePusher.h"      "${FW}/Headers/"

# ------------------------------------------------------ 7. 依赖：WebRTC.framework
echo "==> 拷贝 GoogleWebRTC 的 WebRTC.framework..."
WEBRTC_FW=$(find "${BUILD_DIR}/Pods" -type d -name "WebRTC.framework" -maxdepth 6 | head -1 || true)
if [ -n "${WEBRTC_FW}" ]; then
  rm -rf "${OUT_DIR}/WebRTC.framework"
  cp -R "${WEBRTC_FW}" "${OUT_DIR}/WebRTC.framework"
  echo "    已输出: ${OUT_DIR}/WebRTC.framework"
else
  echo "[警告] 未在 Pods 中找到 WebRTC.framework，请手动检查 Pods/GoogleWebRTC 目录"
fi

# ---------------------------------------------------- 8. 依赖：LFLiveKit.framework
# 注意：LFLiveKit 2.6 的 podspec 依赖 GPUImage（独立 pod），libLFLiveKit.a 不含 GPUImage 符号；
# 云打包只会链接 frameworks 列表中的库，因此需将 libGPUImage.a 一并合并进 LFLiveKit.framework，
# 否则链接 ELiveRTMPPusher 时会报 undefined symbols（OBJC_CLASS_$_GPUImageVideoCamera 等）。
echo "==> 编译并组装 LFLiveKit.framework（含 GPUImage 合并）..."
(cd "${BUILD_DIR}" && xcodebuild \
  -workspace ELivePusher.xcworkspace \
  -scheme LFLiveKit \
  -configuration Release \
  -sdk iphoneos -arch arm64 \
  CONFIGURATION_BUILD_DIR="${BUILD_DIR}/products-lf" \
  build) || echo "[警告] LFLiveKit scheme 编译失败，可改为在 Xcode 中手动编译 Pods-LFLiveKit 后重跑本脚本"

echo "==> 编译 GPUImage 依赖..."
(cd "${BUILD_DIR}" && xcodebuild \
  -workspace ELivePusher.xcworkspace \
  -scheme GPUImage \
  -configuration Release \
  -sdk iphoneos -arch arm64 \
  CONFIGURATION_BUILD_DIR="${BUILD_DIR}/products-gpu" \
  build) || echo "[警告] GPUImage scheme 编译失败，可改为在 Xcode 中手动编译 Pods-GPUImage 后重跑本脚本"

LF_A=$(find "${BUILD_DIR}/products-lf" -name "libLFLiveKit.a" 2>/dev/null | head -1)
GP_A=$(find "${BUILD_DIR}/products-gpu" -name "libGPUImage.a" 2>/dev/null | head -1)
if [ -n "${LF_A}" ]; then
  LFFW="${OUT_DIR}/LFLiveKit.framework"
  rm -rf "${LFFW}"
  mkdir -p "${LFFW}/Headers"
  if [ -n "${GP_A}" ]; then
    # libtool 静态合并：LFLiveKit + GPUImage（保持 arm64 真机架构）
    xcrun libtool -static -o "${LFFW}/LFLiveKit" "${LF_A}" "${GP_A}"
    echo "    已合并 libGPUImage.a -> LFLiveKit.framework/LFLiveKit"
  else
    cp "${LF_A}" "${LFFW}/LFLiveKit"
    echo "[警告] 未找到 libGPUImage.a，LFLiveKit.framework 缺少 GPUImage 符号（云打包会链接失败）"
  fi
  # 保留 Pod 源码头文件的相对目录结构（LFLiveKit/GPUImage 内存在同名头文件，不可平铺），
  # Pod 伞头 LFLiveKit.h 也在该树内（相对 import 均有效）
  HDR_SRC="${BUILD_DIR}/Pods/LFLiveKit/LFLiveKit"
  (cd "${HDR_SRC}" && find . -name '*.h' -print0) | while IFS= read -r -d '' h; do
    rel="${h#./}"
    mkdir -p "${LFFW}/Headers/$(dirname "${rel}")"
    cp "${HDR_SRC}/${rel}" "${LFFW}/Headers/${rel}"
  done
  # 生成顶层转发伞头（下游 #import <LFLiveKit/LFLiveKit.h> 时转发到树内 Pod 伞头，
  # 避免 Pod 伞头的相对 import 在 framework Headers 根目录下失效）
  cat > "${LFFW}/Headers/LFLiveKit.h" <<'UMBRELLA'
#import "LFLiveKit/LFLiveKit.h"
UMBRELLA
  echo "    已输出: ${LFFW}"
else
  echo "[警告] 未找到 libLFLiveKit.a，LFLiveKit.framework 未生成"
fi

# ----------------------------------------------------------------------- 9. 完成
echo ""
echo "==> 构建完成，产物清单（${OUT_DIR}）："
ls -1 "${OUT_DIR}"
echo ""
echo "提示：若 nativeplugins/ELivePusher/package.json 的 ios.frameworks 中尚未包含"
echo "      LFLiveKit.framework，请将其补充进去后再提交 HBuilderX 云打包。"
