# Detect the host platform.
# Set PLATFORM environment variable to override default behavior.
# Supported platform types - 'linux', 'win', 'mac'
# 'msys' is the git bash shell, built using mingw-w64, running under Microsoft
# Windows.
function detect-platform() {
  # set PLATFORM to android on linux host to build android
  case "$OSTYPE" in
  darwin*)      PLATFORM=${PLATFORM:-mac} ;;
  linux*)       PLATFORM=${PLATFORM:-linux} ;;
  win32*|msys*) PLATFORM=${PLATFORM:-win} ;;
  *)            echo "Building on unsupported OS: $OSTYPE"; exit 1; ;;
  esac
}

# Cleanup the output directory.
#
# $1: The output directory.
function clean() {
  local outdir="$1"
  rm -rf $outdir/* $outdir/.gclient*
}

# Make sure depot tools are present.
#
# $1: The platform type.
# $2: The depot tools url.
# $3: The depot tools directory.
function check::depot-tools() {
  local platform="$1"
  local depot_tools_url="$2"
  local depot_tools_dir="$3"

  if [ ! -d $depot_tools_dir ]; then
    git clone -q $depot_tools_url $depot_tools_dir
    if [ $platform = 'win' ]; then
      # run gclient.bat to get python
      pushd $depot_tools_dir >/dev/null
      ./gclient.bat
      popd >/dev/null
    fi
  else
    pushd $depot_tools_dir >/dev/null
      git reset --hard -q
    popd >/dev/null
  fi
}

# Make sure a package is installed. Depends on sudo to be installed first.
#
# $1: The name of the package
# $2: Existence check binary. Defaults to name of the package.
function ensure-package() {
  local name="$1"
  local binary="${2:-$1}"
  if ! which $binary > /dev/null ; then
    sudo apt-get update -qq
    sudo apt-get install -y $name
  fi
}

# Check if any of the arguments is executable (logical OR condition).
# Using plain "type" without any option because has-binary is intended
# to know if there is a program that one can call regardless if it is
# an alias, builtin, function, or a disk file that would be executed.
function has-binary () {
  type "$1" &> /dev/null ;
}

# Setup Visual Studio build environment variables.
function init-msenv() {

  # Rudimentary support for VS2017 in default install location due to
  # lack of VS1S0COMNTOOLS environment variable.
  if [ -d "C:/Program Files (x86)/Microsoft Visual Studio/2017/Community/VC/Auxiliary/Build" ]; then
    vcvars_path="C:/Program Files (x86)/Microsoft Visual Studio/2017/Community/VC/Auxiliary/Build"
  elif [ ! -z "$VS140COMNTOOLS" ]; then
    vcvars_path="${VS140COMNTOOLS}../../VC"
  else
    echo "Building under Microsoft Windows requires Microsoft Visual Studio 2015 Update 3"
    exit 1
  fi

  export DEPOT_TOOLS_WIN_TOOLCHAIN=0
  pushd "$vcvars_path" >/dev/null
    OLDIFS=$IFS
    IFS=$'\n'
    msvars=$(cmd //c "vcvarsall.bat $TARGET_CPU && set")

    for line in $msvars; do
      case $line in
      INCLUDE=*|LIB=*|LIBPATH=*)
        export $line ;;
      PATH=*)
        PATH=$(echo $line | sed \
          -e 's/PATH=//' \
          -e 's/\([a-zA-Z]\):[\\\/]/\/\1\//g' \
          -e 's/\\/\//g' \
          -e 's/;\//:\//g'):$PATH
        export PATH
        ;;
      esac
    done
    IFS=$OLDIFS
  popd >/dev/null
}

# Make sure all build dependencies are present and platform specific
# environment variables are set.
#
# $1: The platform type.
function check::build::env() {
  local platform="$1"
  local target_cpu="$2"

  case $platform in
  mac)
    # for GNU version of cp: gcp
    which gcp || brew install coreutils
    ;;
  linux)
    if ! grep -v \# /etc/apt/sources.list | grep -q multiverse ; then
      echo "*** Warning: The Multiverse repository is probably not enabled ***"
      echo "*** which is required for things like msttcorefonts.           ***"
    fi
    if ! which sudo > /dev/null ; then
      apt-get update -qq
      apt-get install -y sudo
    fi
    ensure-package curl
    ensure-package git
    ensure-package python
    ensure-package lbzip2
    ensure-package lsb-release lsb_release
    ;;
  win)
    init-msenv

    # Required programs that may be missing on Windows
    # TODO: check before running platform specific commands
    REQUIRED_PROGS=(
      bash
      sed
      git
      openssl
      find
      grep
      xargs
      pwd
      curl
      rm
      cat
      # strings
    )

    # Check that required programs exist on the system.
    # If they are missing, we abort.
    for f in "${REQUIRED_PROGS[@]}" ; do
      if ! has-binary "$f" ; then
        echo "Error: '$f' is not installed." >&2
        exit 1
      fi
    done
    ;;
  esac
}

# Make sure all WebRTC build dependencies are present.
# $1: The platform type.
function check::webrtc::deps() {
  local platform="$1"
  local outdir="$2"
  local target_os="$3"

  case $platform in
  linux)
    # Automatically accepts ttf-mscorefonts EULA
    echo ttf-mscorefonts-installer msttcorefonts/accepted-mscorefonts-eula select true | sudo debconf-set-selections
    sudo $outdir/src/build/install-build-deps.sh --no-syms --no-arm --no-chromeos-fonts --no-nacl --no-prompt
    ;;
  esac

  if [ $target_os = 'android' ]; then
    sudo $outdir/src/build/install-build-deps-android.sh
  fi
}

# Check out a specific revision.
#
# $1: The target OS type.
# $2: The output directory.
# $3: Revision represented as a git SHA.
function checkout() {
  local target_os="$1"
  local outdir="$2"
  local revision="$3"

  pushd $outdir >/dev/null
  local prev_target_os=$(cat $outdir/.webrtcbuilds_target_os 2>/dev/null)
  if [[ -n "$prev_target_os" && "$target_os" != "$prev_target_os" ]]; then
    echo The target OS has changed. Refetching sources for the new target OS
    rm -rf src .gclient*
  fi

  # Fetch only the first-time, otherwise sync.
  if [ ! -d src ]; then
    case $target_os in
    android)
      yes | fetch --nohooks webrtc_android
      ;;
    ios)
      fetch --nohooks webrtc_ios
      ;;
    *)
      fetch --nohooks webrtc
      ;;
    esac
  fi

  # Remove all unstaged files that can break gclient sync
  # NOTE: need to redownload resources
  pushd src >/dev/null
  # git reset --hard &&
  git clean -f
  popd >/dev/null

  # Checkout the specific revision after fetch
  gclient sync --force --revision $revision

  # Cache the target OS
  echo $target_os > $outdir/.webrtcbuilds_target_os
  popd >/dev/null
}

# Patch a checkout for before building libraries.
#
# $1: The platform type.
# $2: The output directory.
function patch() {
  local platform="$1"
  local outdir="$2"

  pushd $outdir/src >/dev/null
    # This removes the examples from being built.
    sed -i.bak 's|"//webrtc/examples",|#"//webrtc/examples",|' BUILD.gn

    # This patches a GN error with the video_loopback executable depending on a
    # test but since we disable building tests GN detects a dependency error.
    # Replacing the outer conditional with 'rtc_include_tests' works around this.
    # sed -i.bak 's|if (!build_with_chromium)|if (rtc_include_tests)|' webrtc/BUILD.gn

    # Enable RTTI if required by removing the 'no_rtti' compiler flag.
    # This fixes issues when compiling WebRTC with other libraries that have RTTI enabled.
    # if [ $ENABLE_RTTI = 1 ]; then
    #   echo "Enabling RTTI"
    #   sed -i.bak 's|"//build/config/compiler:no_rtti",|#"//build/config/compiler:no_rtti",|' \
    #     build/config/BUILDCONFIG.gn
    # fi
  popd >/dev/null
}

# Compile using ninja.
#
# $1 The output directory, 'out/$TARGET_OS-$TARGET_CPU/Debug', or 'out/$TARGET_OS-$TARGET_CPU/Release'
# $2 Additional gn arguments
function compile::ninja() {
  local outputdir="$1"
  local gn_args="$2"

  echo "Generating project files at $outputdir with: $gn_args"
  gn gen $outputdir --args="$gn_args"
  pushd $outputdir >/dev/null
    ninja -C .
  popd >/dev/null
}

# Combine build artifact objects into one library.
#
# The Microsoft Windows tools use different file extensions than the other tools:
# '.obj' as the object file extension, instead of '.o'
# '.lib' as the static library file extension, instead of '.a'
# '.dll' as the shared library file extension, instead of '.so'
#
# The Microsoft Windows tools have different names than the other tools:
# 'lib' as the librarian, instead of 'ar'. 'lib' must be found through the path
# variable $VS140COMNTOOLS.
#
# $1: The platform
# $2: The list of object file paths to be combined
# $3: The output library name
function combine::objects() {
  local platform="$1"
  local outputdir="$2"
  local libname="libwebrtc_full"

  # if [ $platform = 'win' ]; then
  #   local extname='obj'
  # else
  #   local extname='o'
  # fi

  pushd $outputdir >/dev/null
    rm -f $libname.*

    # Prevent blacklisted objects such as ones containing a main function from
    # being combined.
    # Blacklist objects from video_capture_external and device_info_external so
    # that the internal video capture module implementations get linked.
    # unittest_main because it has a main function defined.
    local blacklist="unittest|examples|tools|yasm/|protobuf_lite|main.o|video_capture_external.o|device_info_external.o"

    # Method 1: Collect all .o files from .ninja_deps and some missing intrinsics
    local objlist=$(strings .ninja_deps | grep -o ".*\.o")
    local extras=$(find \
      obj/third_party/libvpx/libvpx_* \
      obj/third_party/libjpeg_turbo/simd_asm \
      obj/third_party/boringssl/boringssl_asm -name "*\.o")
    echo "$objlist" | tr ' ' '\n' | grep -v -E $blacklist >$libname.list
    echo "$extras" | tr ' ' '\n' | grep -v -E $blacklist >>$libname.list

    # Method 2: Collect all .o files from output directory
    # local objlist=$(find . -name '*.o' | grep -v -E $blacklist)
    # echo "$objlist" >$libname.list

    # Combine all objects into one static library
    case $platform in
    win)
      # TODO: Support VS 2017
      "$VS140COMNTOOLS../../VC/bin/lib" /OUT:$libname.lib @$libname.list
      ;;
    *)
      # Combine *.o objects using ar
      cat $libname.list | xargs ar -crs $libname.a

      # Combine *.o objects into a thin library using ar
      # cat $libname.list | xargs ar -ccT $libname.a

      ranlib $libname.a
      ;;
    esac
  popd >/dev/null
}

# Combine built static libraries into one library.
#
# NOTE: This method is currently preferred since combining .o objects is
# causing undefined references to libvpx intrinsics on both Linux and Windows.
#
# The Microsoft Windows tools use different file extensions than the other tools:
# '.obj' as the object file extension, instead of '.o'
# '.lib' as the static library file extension, instead of '.a'
# '.dll' as the shared library file extension, instead of '.so'
#
# The Microsoft Windows tools have different names than the other tools:
# 'lib' as the librarian, instead of 'ar'. 'lib' must be found through the path
# variable $VS140COMNTOOLS.
#
# $1: The platform
# $2: The list of object file paths to be combined
# $3: The output library name
function combine::static() {
  local platform="$1"
  local outputdir="$2"
  local libname="$3"

  echo $libname
  pushd $outputdir >/dev/null
    rm -f $libname.*

    # Find only the libraries we need
    if [ $platform = 'win' ]; then
      local whitelist="boringssl.dll.lib|protobuf_lite.dll.lib|webrtc\.lib|field_trial_default.lib|metrics_default.lib"
    else
      local whitelist="boringssl\.a|protobuf_full\.a|webrtc\.a|field_trial_default\.a|metrics_default\.a"
    fi
    cat .ninja_log | tr '\t' '\n' | grep -E $whitelist | sort -u >$libname.list

    # Combine all objects into one static library
    case $platform in
    win)
      # TODO: Support VS 2017
      "$VS140COMNTOOLS../../VC/bin/lib" /OUT:$libname.lib @$libname.list
      ;;
    *)
      # Combine *.a static libraries
      echo "CREATE $libname.a" >$libname.ar
      while read a; do
        echo "ADDLIB $a" >>$libname.ar
      done <$libname.list
      echo "SAVE" >>$libname.ar
      echo "END" >>$libname.ar
      ar -M < $libname.ar
      ranlib $libname.a
      ;;
    esac
  popd >/dev/null
}

# Compile the libraries.
#
# $1: The platform type.
# $2: The output directory.
function compile() {
  local platform="$1"
  local outdir="$2"
  local target_os="$3"
  local target_cpu="$4"
  local blacklist="$5"

  # Set default default common  and target args.
  # `rtc_include_tests=false`: Disable all unit tests
  local common_args="rtc_include_tests=false"
  local target_args="target_os=\"$target_os\" target_cpu=\"$target_cpu\""

  # Build WebRTC with RTII enbled.
  [ $ENABLE_RTTI = 1 ] && common_args+=" use_rtti=true"

  # Static vs Dynamic CRT: When `is_component_build` is false static CTR will be
  # enforced.By default Debug builds are dynamic and Release builds are static.
  [ $ENABLE_STATIC_LIBS = 1 ] && common_args+=" is_component_build=false"

  # `enable_iterator_debugging=false`: Disable libstdc++ debugging facilities
  # unless all your compiled applications and dependencies define _GLIBCXX_DEBUG=1.
  # This will cause errors like: undefined reference to `non-virtual thunk to
  # cricket::VideoCapturer::AddOrUpdateSink(rtc::VideoSinkInterface<webrtc::VideoFrame>*,
  # rtc::VideoSinkWants const&)'
  [ $ENABLE_ITERATOR_DEBUGGING = 0 ] && common_args+=" enable_iterator_debugging=false"

  # Use clang or gcc to compile WebRTC.
  # The default compiler used by Chromium/WebRTC is clang, so there are frequent
  # bugs and incompatabilities with gcc, especially with newer versions >= 4.8.
  # Use gcc at your own risk, but it may be necessary if your compiler doesn't
  # like the clang compiled libraries, so the option is there.
  # Set `is_clang=false` and `use_sysroot=false` to build using gcc.
  if [ $ENABLE_CLANG = 0 ]; then
    target_args+=" is_clang=false"
    [ $platform = 'linux' ] && target_args+=" use_sysroot=false"
  fi

  pushd $outdir/src >/dev/null
    compile::ninja "out/$target_os-$target_cpu/Debug" "$common_args $target_args is_debug=true"
    compile::ninja "out/$target_os-$target_cpu/Release" "$common_args $target_args is_debug=false symbol_level=0"

    if [ $COMBINE_LIBRARIES = 1 ]; then
      combine::static $platform "out/$target_os-$target_cpu/Debug" libwebrtc_full
      combine::static $platform "out/$target_os-$target_cpu/Release" libwebrtc_full
    fi
  popd >/dev/null
}

# Package a compiled build into an archive file in the output directory.
#
# $1: The platform type.
# $2: The output directory.
# $3: Label of the package.
# $4: The project's resource dirctory.
function package() {
  local platform="$1"
  local outdir="$2"
  local label="$3"
  local resourcedir="$4"

  if [ $platform = 'mac' ]; then
    CP='gcp'
  else
    CP='cp'
  fi

  if [ $platform = 'win' ]; then
    OUTFILE=$label.7z
  else
    OUTFILE=$label.tar.gz
  fi

  pushd $outdir >/dev/null

    # Create directory structure
    mkdir -p $label/include $label/lib/$TARGET_CPU packages
    pushd src >/dev/null

      # Find and copy header files
      find api audio call common_audio common_video examples logging media \
        modules ortc p2p pc rtc_base rtc_tools sdk stats system_wrappers \
        test video voice_engine -name "*.h" \
        -exec $CP --parents '{}' $outdir/$label/include ';'
      find . -maxdepth 1 -name "*.h" -exec $CP --parents '{}' $outdir/$label/include ';'

      # Find and copy dependencies
      # The following build dependencies were excluded: gflags, ffmpeg, openh264, openmax_dl, winsdk_samples, yasm
      find third_party -name "*.h" -o -name README -o -name LICENSE -o -name COPYING | \
        grep -E 'boringssl|expat/files|jsoncpp/source/json|libjpeg|libjpeg_turbo|libsrtp|libyuv|libvpx|opus|protobuf|usrsctp/usrsctpout/usrsctpout' | \
        grep -v /third_party | \
        xargs -I '{}' $CP --parents '{}' $outdir/$label/include
    popd >/dev/null

    # Find and copy libraries
    configs="Debug Release"
    for cfg in $configs; do
      mkdir -p $outdir/$label/lib/$TARGET_CPU/$cfg
      pushd src/out/$TARGET_OS-$TARGET_CPU/$cfg >/dev/null
        if [ $COMBINE_LIBRARIES = 1 ]; then
          find . -name '*.so' -o -name '*.dll' -o -name '*.lib' -o -name '*.a' -o -name '*.jar' | \
            grep -E 'webrtc_full' | \
            xargs -I '{}' $CP '{}' $outdir/$label/lib/$TARGET_CPU/$cfg
        else
          find . -name '*.so' -o -name '*.dll' -o -name '*.lib' -o -name '*.a' -o -name '*.jar' | \
            grep -E 'webrtc\.|boringssl|protobuf|system_wrappers' | \
            xargs -I '{}' $CP '{}' $outdir/$label/lib/$TARGET_CPU/$cfg
        fi
      popd >/dev/null
    done

    # For linux, add pkgconfig files
    if [ $platform = 'linux' ]; then
      configs="Debug Release"
      for cfg in $configs; do
        mkdir -p $label/lib/$TARGET_CPU/$cfg/pkgconfig
        CONFIG=$cfg envsubst '$CONFIG' < $resourcedir/pkgconfig/libwebrtc_full.pc.in > \
          $label/lib/$TARGET_CPU/$cfg/pkgconfig/libwebrtc_full.pc
      done
    fi

    # Archive up the package
    rm -f $OUTFILE
    pushd $label >/dev/null
      if [ $platform = 'win' ]; then
        $DEPOT_TOOLS_DIR/win_toolchain/7z/7z.exe a -t7z -m0=lzma2 -mx=9 -mfb=64 -md=32m -ms=on -ir!lib/$TARGET_CPU -ir!linclude -r ../packages/$OUTFILE
      else
        tar -czvf ../packages/$OUTFILE lib/$TARGET_CPU include
      fi
    popd >/dev/null

  popd >/dev/null
}

# Build and merge the output manifest.
#
# $1: The platform type.
# $2: The output directory.
# $3: Label of the package.
function manifest() {
  local platform="$1"
  local outdir="$2"
  local label="$3"

  if [ $platform = 'win' ]; then
    OUTFILE=$label.7z
  else
    OUTFILE=$label.tar.gz
  fi

  mkdir -p $outdir/packages
  pushd $outdir/packages >/dev/null
    # Create a JSON manifest
    rm -f $label.json
    cat << EOF > $label.json
{
  "file": "$OUTFILE",
  "date": "$(current-rev-date)",
  "branch": "${BRANCH}",
  "revision": "${REVISION_NUMBER}",
  "sha": "${REVISION}",
  "crc": "$(file-crc $OUTFILE)",
  "target_os": "${TARGET_OS}",
  "target_cpu": "${TARGET_CPU}"
}
EOF

    # # Merge JSON manifests
    # # node manifest.js
    # rm -f manifest.json
    # echo '[' > manifest.json
    # files=(*.json)
    # (
    #   set -- "${files[@]}"
    #   until (( $# == 1 )); do
    #     if [ ! $1 = 'manifest.json' ]; then
    #       cat $1 >> manifest.json
    #       echo ',' >> manifest.json
    #     fi
    #     shift
    #   done
    #   cat $1 >> manifest.json
    # )
    # sed -i ':a;N;$!ba;s/\n//g' manifest.json
    # sed -i 's/{/\n  {/g' manifest.json
    # echo ']' >> manifest.json

  popd >/dev/null
}

# Return the latest revision date from the current git repo.
function current-rev-date() {
  git log -1 --format=%cd
}

# Return the latest revision from the git repo.
#
# $1: The git repo URL
function file-crc() {
  local file_path="$1"
   md5sum $file_path | grep -o '^\S*'
}

# Return the latest revision from the git repo.
#
# $1: The git repo URL
function latest-rev() {
  local repo_url="$1"
  git ls-remote $repo_url HEAD | cut -f1
}

# Return the associated revision number for a given git sha revision.
#
# $1: The git repo URL
# $2: The revision git sha string
function revision-number() {
  local repo_url="$1"
  local revision="$2"
  # This says curl the revision log with text format, base64 decode it using
  # openssl since its more portable than just 'base64', take the last line which
  # contains the commit revision number and output only the matching {#nnn} part
  openssl base64 -d -A <<< $(curl --silent $repo_url/+/$revision?format=TEXT) \
    | tail -1 | egrep -o '{#([0-9]+)}' | tr -d '{}#'
}

# Return a short revision sha.
#
# $1: The revision string
function short-rev() {
  local revision="$1"
  echo $revision | cut -c -7
}
