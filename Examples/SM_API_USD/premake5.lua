-- SPDX-License-Identifier: Apache-2.0
--
-- brepinfo sample (fork addition, see ANDROID_PORT_NOTES.md). Included from premake5.lua (host) and
-- premake5-android.lua (android-aarch64), so one source builds for both.

project "brepinfo"
    kind "ConsoleApp"
    location (workspace_dir.."/%{prj.name}")
    staticruntime "Off"
    use_usd()
    use_usd_tbb()
    link_usd_common()
    files { "brepinfo.cpp" }
    includedirs {
        root.."/source/SM_API_USD/inc",
        root.."/source/SM_API/inc",
        root.."/source/SMLib/inc",
        root.."/source/BREP_SM_USD/inc",   -- UsdBrepSuppressPixarWarnings*.h
        root.."/source/BREP_USD_DATA/inc", -- UsdBrepHeaders.h, from SmApiUsdTessellate.h
    }
    links { "SM_API_USD", "SM_API", "SMLib" }
    filter { "system:windows" }
        defines { "_CRT_SECURE_NO_WARNINGS" }
        buildoptions {"/W4"}
    filter { "system:linux" }
        buildoptions {"-Wno-deprecated"}
    filter { "system:macosx" }
        buildoptions (macos_common_buildoptions())
        linkoptions (macos_common_linkoptions())
    filter {}
