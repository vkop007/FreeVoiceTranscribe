# Builds the Windows application bundle in zig-out/bin/
# - Compiles free-voice-transcribe.exe via `zig build` (or falls back to MinGW gcc / clang / MSVC cl.exe with src/main.c)
# - Copies scripts/copilot_bridge.ps1 next to the executable
# - Optionally compiles src/enhance_win.cs into libenhance.dll (NativeAOT) if the .NET 8+ SDK is installed
# - Pass -Package (or set $env:PACKAGE_RELEASE = '1') to also produce release .zip and standalone .exe assets in zig-out/

param(
    [switch]$Package
)

$ErrorActionPreference = 'Stop'
Set-Location (Split-Path -Parent $PSScriptRoot)

$outDir = "zig-out\bin"
New-Item -ItemType Directory -Force -Path "$outDir\scripts" | Out-Null

$built = $false
if (Get-Command zig -ErrorAction SilentlyContinue) {
    try {
        Write-Host "Building free-voice-transcribe.exe (x86_64) with Zig..."
        zig build -Dtarget=x86_64-windows-gnu -Doptimize=ReleaseSafe
        if (Test-Path "$outDir\free-voice-transcribe.exe") {
            $built = $true
        }
    } catch {
        Write-Warning "zig build encountered an error, trying alternative compilers..."
    }
}

if (-not $built -and (Get-Command zig -ErrorAction SilentlyContinue)) {
    try {
        Write-Host "Compiling directly with 'zig cc' (x86_64-windows-gnu)..."
        zig cc -target x86_64-windows-gnu -O2 -I src `
            src\main.c src\orb_math.c src\shim_win.c `
            -luser32 -lgdi32 -lshell32 -lwinmm -ladvapi32 -lole32 `
            "-Wl,-subsystem,windows" `
            -o "$outDir\free-voice-transcribe.exe"
        if (Test-Path "$outDir\free-voice-transcribe.exe") {
            $built = $true
        }
    } catch {
        Write-Warning "zig cc failed, trying GCC/Clang/MSVC..."
    }
}

if (-not $built -and (Get-Command gcc -ErrorAction SilentlyContinue)) {
    Write-Host "Building free-voice-transcribe.exe with GCC (MinGW)..."
    gcc -O2 -I src src\main.c src\orb_math.c src\shim_win.c `
        -luser32 -lgdi32 -lshell32 -lwinmm -ladvapi32 -lole32 -mwindows `
        -o "$outDir\free-voice-transcribe.exe"
    $built = $true
} elseif (-not $built -and (Get-Command clang -ErrorAction SilentlyContinue)) {
    Write-Host "Building free-voice-transcribe.exe with Clang..."
    clang -O2 -I src src\main.c src\orb_math.c src\shim_win.c `
        -luser32 -lgdi32 -lshell32 -lwinmm -ladvapi32 -lole32 "-Wl,/SUBSYSTEM:WINDOWS" `
        -o "$outDir\free-voice-transcribe.exe"
    $built = $true
} elseif (-not $built -and (Get-Command cl -ErrorAction SilentlyContinue)) {
    Write-Host "Building free-voice-transcribe.exe with MSVC cl.exe..."
    cl /O2 /I src src\main.c src\orb_math.c src\shim_win.c `
        user32.lib gdi32.lib shell32.lib winmm.lib advapi32.lib ole32.lib `
        /link /SUBSYSTEM:WINDOWS /OUT:"$outDir\free-voice-transcribe.exe"
    $built = $true
}

if (-not $built -and -not (Test-Path "$outDir\free-voice-transcribe.exe")) {
    throw "Build failed: could not produce free-voice-transcribe.exe."
}

Copy-Item -Force "scripts\copilot_bridge.ps1" "$outDir\scripts\copilot_bridge.ps1"
Copy-Item -Force "scripts\copilot_bridge.ps1" "$outDir\copilot_bridge.ps1"
Copy-Item -Force "$outDir\free-voice-transcribe.exe" "$outDir\FreeVoiceTranscribe.exe"

if (Get-Command dotnet -ErrorAction SilentlyContinue) {
    Write-Host ".NET SDK detected — building optional NativeAOT Windows Copilot Runtime library (libenhance.dll)..."
    $tmpProj = Join-Path $env:TEMP "FVTEnhanceWin"
    Remove-Item -Recurse -Force $tmpProj -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force -Path $tmpProj | Out-Null
    Copy-Item "src\enhance_win.cs" "$tmpProj\enhance_win.cs"
    $csprojContent = @"
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>net8.0-windows10.0.22621.0</TargetFramework>
    <OutputType>Library</OutputType>
    <PublishAot>true</PublishAot>
    <AllowUnsafeBlocks>true</AllowUnsafeBlocks>
    <AssemblyName>libenhance</AssemblyName>
  </PropertyGroup>
</Project>
"@
    Set-Content -Path (Join-Path $tmpProj "FVTEnhanceWin.csproj") -Value $csprojContent
    try {
        dotnet publish "$tmpProj\FVTEnhanceWin.csproj" -c Release -o $outDir --nologo
        if (Test-Path "$outDir\libenhance.dll") {
            Write-Host "Built $outDir\libenhance.dll"
        }
    } catch {
        Write-Warning "Skipping optional NativeAOT libenhance.dll build (built-in copilot_bridge.ps1 will be used)."
    }
    Remove-Item -Recurse -Force $tmpProj -ErrorAction SilentlyContinue
}

Write-Host "Built $outDir\FreeVoiceTranscribe.exe — run: .\$outDir\FreeVoiceTranscribe.exe"

if ($Package -or ($env:PACKAGE_RELEASE -eq '1')) {
    $stageX64 = "zig-out\package-win-x64\FreeVoiceTranscribe"
    Remove-Item -Recurse -Force "zig-out\package-win-x64" -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force -Path "$stageX64\scripts" | Out-Null

    Copy-Item -Force "$outDir\free-voice-transcribe.exe" "$stageX64\FreeVoiceTranscribe.exe"
    Copy-Item -Force "$outDir\free-voice-transcribe.exe" "$stageX64\free-voice-transcribe.exe"
    Copy-Item -Force "scripts\copilot_bridge.ps1" "$stageX64\copilot_bridge.ps1"
    Copy-Item -Force "scripts\copilot_bridge.ps1" "$stageX64\scripts\copilot_bridge.ps1"
    Copy-Item -Force "README.md" "$stageX64\README.md"
    Copy-Item -Force "LICENSE" "$stageX64\LICENSE"
    if (Test-Path "$outDir\libenhance.dll") {
        Copy-Item -Force "$outDir\libenhance.dll" "$stageX64\libenhance.dll"
    }

    $zipX64 = "zig-out\FreeVoiceTranscribe-Windows-x64.zip"
    $exeX64 = "zig-out\FreeVoiceTranscribe-Windows-x64.exe"
    Remove-Item -Force $zipX64, $exeX64 -ErrorAction SilentlyContinue
    Compress-Archive -Path "$stageX64\*" -DestinationPath $zipX64 -Force
    Copy-Item -Force "$outDir\free-voice-transcribe.exe" $exeX64
    Write-Host "Packaged $zipX64 and $exeX64"

    if (Get-Command zig -ErrorAction SilentlyContinue) {
        Write-Host "Cross-compiling free-voice-transcribe.exe (ARM64 for Copilot+ PCs) with Zig..."
        $arm64Success = $false
        try {
            zig build -Dtarget=aarch64-windows-gnu -Doptimize=ReleaseSafe -p "zig-out\win-arm64"
            if (Test-Path "zig-out\win-arm64\bin\free-voice-transcribe.exe") {
                $arm64Success = $true
            }
        } catch {
            Write-Warning "zig build for aarch64-windows-gnu failed, attempting zig cc..."
        }
        if (-not $arm64Success) {
            try {
                New-Item -ItemType Directory -Force -Path "zig-out\win-arm64\bin" | Out-Null
                zig cc -target aarch64-windows-gnu -O2 -I src `
                    src\main.c src\orb_math.c src\shim_win.c `
                    -luser32 -lgdi32 -lshell32 -lwinmm -ladvapi32 -lole32 `
                    "-Wl,-subsystem,windows" `
                    -o "zig-out\win-arm64\bin\free-voice-transcribe.exe"
                if (Test-Path "zig-out\win-arm64\bin\free-voice-transcribe.exe") {
                    $arm64Success = $true
                }
            } catch {
                Write-Warning "zig cc for ARM64 failed."
            }
        }
        if ($arm64Success) {
            $stageArm64 = "zig-out\package-win-arm64\FreeVoiceTranscribe"
            Remove-Item -Recurse -Force "zig-out\package-win-arm64" -ErrorAction SilentlyContinue
            New-Item -ItemType Directory -Force -Path "$stageArm64\scripts" | Out-Null

            Copy-Item -Force "zig-out\win-arm64\bin\free-voice-transcribe.exe" "$stageArm64\FreeVoiceTranscribe.exe"
            Copy-Item -Force "zig-out\win-arm64\bin\free-voice-transcribe.exe" "$stageArm64\free-voice-transcribe.exe"
            Copy-Item -Force "scripts\copilot_bridge.ps1" "$stageArm64\copilot_bridge.ps1"
            Copy-Item -Force "scripts\copilot_bridge.ps1" "$stageArm64\scripts\copilot_bridge.ps1"
            Copy-Item -Force "README.md" "$stageArm64\README.md"
            Copy-Item -Force "LICENSE" "$stageArm64\LICENSE"

            $zipArm64 = "zig-out\FreeVoiceTranscribe-Windows-arm64.zip"
            $exeArm64 = "zig-out\FreeVoiceTranscribe-Windows-arm64.exe"
            Remove-Item -Force $zipArm64, $exeArm64 -ErrorAction SilentlyContinue
            Compress-Archive -Path "$stageArm64\*" -DestinationPath $zipArm64 -Force
            Copy-Item -Force "zig-out\win-arm64\bin\free-voice-transcribe.exe" $exeArm64
            Write-Host "Packaged $zipArm64 and $exeArm64"
        }
    }
}
