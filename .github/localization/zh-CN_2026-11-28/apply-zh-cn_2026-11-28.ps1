<#
.SYNOPSIS
    Arsenal Image Mounter 构建期汉化脚本（快照日期：2026-11-28）。

.DESCRIPTION
    本脚本在 dotnet publish 之前运行，把托管源码里的英文字符串就地替换成中文，
    使 CI 产出的 exe/dll 的界面、报错、日志直接显示中文。
    为什么不直接用 .zh-CN.resx 卫星资源：
      1) 本仓库的 WinForms Designer 把按钮文字硬编码成 .Text = "..." ；
         只有 Localizable=True 的窗体才会走 ComponentResourceManager，卫星资源对它们无效。
      2) 单文件发布（PublishSingleFile）默认不会把卫星程序集打进 exe，运行目录一乱就丢汉化。
      3) 直接改源码字面量与 TFM / RID / 打包方式完全解耦，三个变体都能用同一份映射。

    设计原则（也是"过时后如何排查"的答案）：
      * 本脚本和映射表是"快照"，文件名/目录名带日期，并在 $UpstreamCommit 里记录针对的上游提交。
        同步主仓库后如果某条映射失效，脚本会打印 MAPPING_STALE（映射存在但源码里再也找不到），
        并打印 UNTRANSLATED（源码里出现新英文句子但映射表里没有），据此定位需要更新的条目。
      * 全部替换都逐条打印日志（文件、行号、原文、译文、替换方式），并写入报告目录，
        便于把 CI 日志和本地产物一一对应。
      * 不改动 Git 里的原始源文件：CI 每次都是全新 checkout，脚本只改工作区副本；
        同步上游时不会与本脚本产生源码冲突。

    替换分两级：
      1) exact  —— 整条字面量精确匹配，用于界面文案和关键提示（质量最高，优先执行）。
      2) phrases —— 对剩余字面量的非占位符片段做词组替换，用于覆盖面广的日志/报错。
                     {0} / {ex} / {offset:X8} 等插值占位符原样保留，绝不翻译。

.PARAMETER SourceRoot
    需要汉化的源码根目录，默认 "Managed Source"（相对 CI 工作区根目录）。

.PARAMETER MappingFile
    映射表 JSON 路径，默认是同目录下的 strings-zh-cn_2026-11-28.json。

.PARAMETER ReportDir
    报告输出目录，默认 "localization-report/zh-cn_2026-11-28"。

.PARAMETER DryRun
    只分析、只打日志，不写回源文件（本地验证用）。

.EXAMPLE
    pwsh -File .github/localization/zh-CN_2026-11-28/apply-zh-cn_2026-11-28.ps1

.NOTES
    兼容 PowerShell 5.1（本地）与 PowerShell 7（CI）。
    源文件统一以 UTF-8 with BOM 写回：VB 编译器在没有 BOM 时可能按系统 ANSI 代码页解码，
    中文会变成乱码；C#/resx 带 BOM 也完全合法。
#>
[CmdletBinding()]
param(
    [string]$SourceRoot  = 'Managed Source',
    [string]$MappingFile = (Join-Path $PSScriptRoot 'strings-zh-cn_2026-11-28.json'),
    [string]$ReportDir   = 'localization-report/zh-cn_2026-11-28',
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

# ---- 快照元信息：同步上游后排查"汉化为何失效"的第一手线索 -------------------
$ScriptVersion  = '2026-11-28.1'
$SnapshotDate   = '2026-11-28'
$UpstreamCommit = 'b26f56c4fefaee021584c5bbb3a82592c4562189'  # 制作映射时的 master HEAD
# ---------------------------------------------------------------------------

# 日志同时保存在内存和报告文件里；Write-Log 是唯一出口，保证 CI 控制台和落盘内容一致。
$script:LogLines = [System.Collections.Generic.List[string]]::new()
function Write-Log {
    param(
        [ValidateSet('INFO', 'WARN', 'ERROR', 'EXACT', 'PHRASE', 'RESX')]
        [string]$Level,
        [string]$Message
    )
    # 时间戳用本地时间即可：CI 日志本身带 UTC 时间戳，这里方便与本地复现对照。
    $line = '[{0}] [{1,-6}] {2}' -f (Get-Date -Format 'HH:mm:ss'), $Level, $Message
    $script:LogLines.Add($line)
    switch ($Level) {
        'WARN'  { Write-Warning $line }
        'ERROR' { Write-Error $line }
        default { Write-Host $line }
    }
}

Write-Log INFO "=============================================================="
Write-Log INFO "Arsenal Image Mounter 汉化开始"
Write-Log INFO "脚本版本      : $ScriptVersion"
Write-Log INFO "映射快照日期  : $SnapshotDate"
Write-Log INFO "对应上游提交  : $UpstreamCommit"
Write-Log INFO "源码根目录    : $SourceRoot"
Write-Log INFO "映射文件      : $MappingFile"
Write-Log INFO "报告目录      : $ReportDir"
Write-Log INFO "DryRun        : $($DryRun.IsPresent)"
Write-Log INFO "PowerShell    : $($PSVersionTable.PSVersion)"
Write-Log INFO "=============================================================="

# ---- 前置检查：早失败、失败原因明确 -----------------------------------------
if (-not (Test-Path -LiteralPath $SourceRoot -PathType Container)) {
    throw "源码根目录不存在: $SourceRoot （注意本脚本需在工作区根目录运行）"
}
if (-not (Test-Path -LiteralPath $MappingFile -PathType Leaf)) {
    throw "映射文件不存在: $MappingFile —— 汉化已中止，产物将是英文原版。"
}

$mapBytes = [IO.File]::ReadAllBytes($MappingFile)
$mapHash = (Get-FileHash -LiteralPath $MappingFile -Algorithm SHA256).Hash
Write-Log INFO "映射文件大小  : $($mapBytes.Length) 字节；SHA256=$mapHash"

# PS 5.1 的 ConvertFrom-Json 对 BOM 敏感，先按 UTF8 读文本再转换。
$mapText = [IO.File]::ReadAllText($MappingFile, [Text.Encoding]::UTF8)
$map = $mapText | ConvertFrom-Json
if ($null -eq $map) { throw "映射文件解析结果为空: $MappingFile" }

# 用 Ordinal 字典，避免 PowerShell 默认哈希表忽略大小写导致误替换。
$exactMap = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::Ordinal)
foreach ($p in $map.exact.PSObject.Properties) {
    if ($exactMap.ContainsKey($p.Name)) { Write-Log WARN "映射表存在重复 exact key: $($p.Name)" }
    $exactMap[$p.Name] = [string]$p.Value
}
$phraseList = @($map.phrases.PSObject.Properties | Sort-Object { $_.Name.Length } -Descending)
$resxMap = @{}
foreach ($p in $map.resx.PSObject.Properties) { $resxMap[$p.Name] = [string]$p.Value }
$skipList = @()
if ($map.doNotTranslate) { $skipList = @($map.doNotTranslate | ForEach-Object { [string]$_ }) }

Write-Log INFO "映射条目      : exact=$($exactMap.Count)  phrases=$($phraseList.Count)  resx=$($resxMap.Count)  doNotTranslate=$($skipList.Count)"
Write-Log INFO "词组替换顺序  : 按 key 长度降序（长词优先，避免 'disk' 抢先替换 'virtual disk'）"

# 这些字面量不是给人看的文案：路径、注册表键、XML 文档、文件名、品牌/字体名等。
# 误翻译它们会改变运行时行为（找不到文件 / 注册表读写失败），因此只跳过"词组替换"；
# exact 映射仍然生效（因为 exact 是人工逐条确认过的）。
function Test-Processable {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text))            { return $false }
    if ($Text.Length -lt 4)                             { return $false }
    if ($Text -notmatch ' ')                            { return $false }   # 单个词/标识符不处理
    if ($Text -notmatch '[A-Za-z]{2}')                  { return $false }   # 没有英文字母
    if ($Text.Contains('<') -or $Text.Contains('>'))    { return $false }   # XML 文档注释
    if ($Text.Contains('\'))                            { return $false }   # 路径 / 注册表键
    if ($Text -match 'HKEY_|http:|https:|://')          { return $false }
    if ($Text -match '\.(dll|exe|zip|json|cs|vb|resx)\b') { return $false }
    foreach ($s in $skipList) { if ($Text.Contains($s)) { return $false } }
    return $true
}

# C# / VB 的字面量在源码里是"转义后的形态"，映射表里存的是"人眼看到的形态"。
# 两个函数负责在两者之间转换，保证映射表可读、且写回源码时语法依然正确。
# 插值占位符 {expr} 内部是"代码"不是"文案"：里面的引号/花括号必须原样保留。
# 因此转义/反转义都只在占位符之外的自然语言片段上进行。
function ConvertFrom-SourceLiteral {
    param([string]$Raw, [string]$Kind)   # Kind: vb | csverb | cs
    $parts = [regex]::Split($Raw, '(\{[^{}]*\})')
    for ($i = 0; $i -lt $parts.Length; $i++) {
        if ($i % 2 -eq 1) { continue }   # 占位符：原样保留
        $seg = $parts[$i]
        if ($Kind -eq 'vb' -or $Kind -eq 'csverb') {
            $parts[$i] = $seg.Replace('""', '"')
            continue
        }
        $sb = New-Object Text.StringBuilder
        for ($j = 0; $j -lt $seg.Length; $j++) {
            $c = $seg[$j]
            if ($c -eq '\' -and ($j + 1) -lt $seg.Length) {
                $n = $seg[$j + 1]
                switch ($n) {
                    'n' { [void]$sb.Append("`n"); $j++ }
                    'r' { [void]$sb.Append("`r"); $j++ }
                    't' { [void]$sb.Append("`t"); $j++ }
                    '0' { [void]$sb.Append([char]0); $j++ }
                    '"' { [void]$sb.Append('"'); $j++ }
                    '\' { [void]$sb.Append('\'); $j++ }
                    default { [void]$sb.Append($c) }
                }
            } else { [void]$sb.Append($c) }
        }
        $parts[$i] = $sb.ToString()
    }
    return ($parts -join '')
}

function ConvertTo-SourceLiteral {
    param([string]$Text, [string]$Kind)
    $parts = [regex]::Split($Text, '(\{[^{}]*\})')
    for ($i = 0; $i -lt $parts.Length; $i++) {
        if ($i % 2 -eq 1) { continue }
        $seg = $parts[$i]
        if ($Kind -eq 'vb' -or $Kind -eq 'csverb') {
            $parts[$i] = $seg.Replace('"', '""')
        } else {
            $parts[$i] = $seg.Replace('\', '\\').Replace('"', '\"').
                              Replace("`r", '\r').Replace("`n", '\n').Replace("`t", '\t')
        }
    }
    return ($parts -join '')
}

# 把插值/格式占位符（{0}、{ex}、{offset:X8} 等）挖出来原样保留，
# 只翻译占位符之间的自然语言，避免把 {DiskDeviceNumber} 之类的代码符号翻坏。
function ConvertWith-Placeholders {
    param([string]$Text)
    $parts = [regex]::Split($Text, '(\{[^{}]*\})')
    $changed = $false
    for ($i = 0; $i -lt $parts.Length; $i++) {
        # 奇数下标是占位符，直接跳过。
        if ($i % 2 -eq 1) { continue }
        $seg = $parts[$i]
        foreach ($kv in $phraseList) {
            $from = $kv.Name
            # 词边界 + 可选复数 s：避免把 "File" 误替换进 "filename"，
            # 同时让保留下来的 "Drivers" 也能覆盖单数 "driver"。
            $tail = if ($from -match '[A-Za-z0-9]$') { 's?\b' } else { '\b' }
            $pattern = '\b' + [regex]::Escape($from) + $tail
            if ([regex]::IsMatch($seg, $pattern, [Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
                $seg = [regex]::Replace($seg, $pattern, [string]$kv.Value,
                                        [Text.RegularExpressions.RegexOptions]::IgnoreCase)
                $changed = $true
            }
        }
        $parts[$i] = $seg
    }
    return @{ Text = ($parts -join ''); Changed = $changed }
}

function ConvertTo-XmlText {
    param([string]$Text)
    return $Text.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;')
}

# ---- 统计计数器 --------------------------------------------------------------
$stat = @{
    FilesScanned = 0; FilesChanged = 0; Exact = 0; Phrase = 0; Resx = 0
    Untranslated = 0; BytesBefore = 0; BytesAfter = 0
}
$exactHits = @{}
$untranslatedLines = [System.Collections.Generic.List[string]]::new()
$changedFiles = [System.Collections.Generic.List[string]]::new()

# 正则说明：
#   vb     : VB 字符串，内部双引号写成 ""。
#   cs     : C# 普通字符串，支持 \. 转义；先匹配逐字字符串 @"..."，再匹配普通字符串。
$rxVb = [regex]'"((?:[^"{}]|""|\{[^{}]*\}|\{\{|\}\})*)"'
# C# 逐字字符串有三种前缀写法：@"..."、@$"..."、$@"..."，都要先于普通字符串匹配，
# 否则 @"\\?\..." 会被当成普通字符串转义，把路径里的反斜杠越改越多。
$rxCs = [regex]'(?:(?<verb>@"|@\$"|\$@")(?<vinner>(?:[^"{}]|""|\{[^{}]*\}|\{\{|\}\})*)")|(?<rinner>"(?:\\.|[^"\\{}]|\{[^{}]*\}|\{\{|\}\})*")'
$rxResx = [regex]'<data name="(?<name>[^"]+)"[^>]*>\s*<value>(?<val>.*?)</value>'

# 不处理测试项目和中间目录：测试不随产品发布，obj/bin 里是生成物。
$excludedDirPattern = '\\(obj|bin|TestProject)\\'

Write-Log INFO "开始扫描源码（排除目录正则: $excludedDirPattern）"
# 注意：不能用 -LiteralPath + -Include 组合 —— PowerShell 5.1 会忽略 -Include，
# 结果把 .dll/.zip 当文本读进来改写，产物直接损坏（本地实测踩过这个坑）。
$allFiles = @(Get-ChildItem -LiteralPath $SourceRoot -Recurse -File |
              Where-Object { $_.Extension -in '.vb', '.cs', '.resx' -and
                             $_.FullName -notmatch $excludedDirPattern } |
              Sort-Object FullName)
Write-Log INFO "待扫描文件数: $($allFiles.Count)"

foreach ($file in $allFiles) {
    # 统一用正斜杠：映射表里的 resx key 写成 "目录/文件.resx|data名"，跨平台一致。
    $rel = $file.FullName.Substring((Resolve-Path -LiteralPath $SourceRoot).Path.Length + 1).Replace('\', '/')
    $stat.FilesScanned++
    $original = [IO.File]::ReadAllText($file.FullName, [Text.Encoding]::UTF8)
    $stat.BytesBefore += $original.Length   # 统一按字符数统计（中文 1 字符 = 3 字节，按文件字节数比会误判为"变短"）

    if ($file.Extension -ieq '.resx') {
        # ---- resx：按 data name 精确替换 <value>，不改 resheader -----------------
        $sb = New-Object Text.StringBuilder
        $pos = 0
        $lineNo = 1
        $scanPos = 0
        foreach ($m in $rxResx.Matches($original)) {
            for ($i = $scanPos; $i -lt $m.Index; $i++) { if ($original[$i] -eq "`n") { $lineNo++ } }
            $scanPos = $m.Index
            [void]$sb.Append($original.Substring($pos, $m.Index - $pos))
            $key = "$rel|$($m.Groups['name'].Value)"
            $newToken = $m.Value
            if ($resxMap.ContainsKey($key)) {
                $zh = ConvertTo-XmlText $resxMap[$key]
                $newToken = $m.Value.Replace($m.Groups['val'].Value, $zh)
                $stat.Resx++
                Write-Log RESX "$rel : $lineNo  $key  =>  $zh"
            }
            [void]$sb.Append($newToken)
            $pos = $m.Index + $m.Length
        }
        [void]$sb.Append($original.Substring($pos))
        $updated = $sb.ToString()
    }
    else {
        # ---- .vb / .cs：逐字面量替换 --------------------------------------------
        $kindVb = ($file.Extension -ieq '.vb')
        $rx = if ($kindVb) { $rxVb } else { $rxCs }
        $sb = New-Object Text.StringBuilder
        $pos = 0
        $lineNo = 1
        $scanPos = 0
        foreach ($m in $rx.Matches($original)) {
            for ($i = $scanPos; $i -lt $m.Index; $i++) { if ($original[$i] -eq "`n") { $lineNo++ } }
            $scanPos = $m.Index

            [void]$sb.Append($original.Substring($pos, $m.Index - $pos))

            $openPrefix = '"'   # 默认普通字符串；逐字字符串要保留 @" / @$" / $@" 原前缀
            if ($kindVb) {
                $raw = $m.Groups[1].Value
                $kind = 'vb'
            } elseif ($m.Groups['vinner'].Success) {
                $raw = $m.Groups['vinner'].Value
                $kind = 'csverb'
                $openPrefix = $m.Groups['verb'].Value
            } else {
                $raw = $m.Groups['rinner'].Value.Substring(1, $m.Groups['rinner'].Value.Length - 2)
                $kind = 'cs'
            }

            $canonical = ConvertFrom-SourceLiteral -Raw $raw -Kind $kind
            $newCanonical = $canonical
            $method = ''

            # 第一级：整句精确替换（人工确认过的界面文案 / 关键提示）。
            # C# 逐字字符串里可能带 CRLF，映射表统一存 LF；匹配时归一化，写回时还原。
            $canonicalForMatch = $canonical.Replace("`r`n", "`n")
            $hadCrlf = ($canonicalForMatch -cne $canonical)
            if ($exactMap.ContainsKey($canonicalForMatch)) {
                $newCanonical = $exactMap[$canonicalForMatch]
                if ($hadCrlf) { $newCanonical = $newCanonical.Replace("`n", "`r`n") }
                $method = 'EXACT'
                $stat.Exact++
                if (-not $exactHits.ContainsKey($canonicalForMatch)) { $exactHits[$canonicalForMatch] = 0 }
                $exactHits[$canonicalForMatch]++
            }
            # 第二级：词组替换（只动自然语言片段，占位符原样保留）。
            elseif (Test-Processable $canonical) {
                $r = ConvertWith-Placeholders $canonical
                if ($r.Changed) {
                    $newCanonical = $r.Text
                    $method = 'PHRASE'
                    $stat.Phrase++
                } else {
                    $stat.Untranslated++
                    $untranslatedLines.Add(('{0}:{1}`t{2}' -f $rel, $lineNo, ($canonical -replace '\s+', ' ')))
                }
            }

            if ($method) {
                $previewFrom = ($canonical -replace '\s+', ' ')
                $previewTo = ($newCanonical -replace '\s+', ' ')
                Write-Log $method ("{0}:{1}`n      原文: {2}`n      译文: {3}" -f $rel, $lineNo, $previewFrom, $previewTo)
            }
            # 重新包回引号：ConvertTo-SourceLiteral 只处理字面量"内部"，
            # 漏掉外壳会让 VB/C# 源码语法直接崩（本地实测抓到过这个坑）。
            $escapedInner = ConvertTo-SourceLiteral -Text $newCanonical -Kind $kind
            $newToken = $openPrefix + $escapedInner + '"'
            [void]$sb.Append($newToken)
            $pos = $m.Index + $m.Length
        }
        [void]$sb.Append($original.Substring($pos))
        $updated = $sb.ToString()
    }

    if ($updated -cne $original) {
        $stat.FilesChanged++
        $changedFiles.Add($rel)
        if (-not $DryRun) {
            # UTF-8 with BOM：VB 编译器在 CI/本地用系统 ANSI 解码无 BOM 文件时会乱码。
            $utf8Bom = New-Object Text.UTF8Encoding($true)
            [IO.File]::WriteAllText($file.FullName, $updated, $utf8Bom)
        }
        Write-Log INFO ("文件已{0}: {1}  ({2} -> {3} 字节)" -f `
            $(if ($DryRun) { '模拟改写' } else { '改写' }), $rel, $original.Length, $updated.Length)
        $stat.BytesAfter += $updated.Length
    } else {
        $stat.BytesAfter += $original.Length
    }
}

# ---- 过时检测：映射在源码里再也找不到 = 上游改了文案 -------------------------
$staleKeys = [System.Collections.Generic.List[string]]::new()
foreach ($k in $exactMap.Keys) {
    if (-not $exactHits.ContainsKey($k)) { $staleKeys.Add($k) }
}
$staleKeys.Sort()
foreach ($k in $staleKeys) {
    Write-Log WARN "MAPPING_STALE: exact 映射未命中任何源码字面量，上游可能已改写该文案 => $k"
}
Write-Log INFO "MAPPING_STALE 数量: $($staleKeys.Count)"

# ---- 报告落盘 ----------------------------------------------------------------
if (-not (Test-Path -LiteralPath $ReportDir -PathType Container)) {
    New-Item -ItemType Directory -Force -Path $ReportDir | Out-Null
}
$logPath = Join-Path $ReportDir 'apply.log'
[IO.File]::WriteAllLines($logPath, $script:LogLines, (New-Object Text.UTF8Encoding($false)))

$untranslatedPath = Join-Path $ReportDir 'untranslated.txt'
[IO.File]::WriteAllLines($untranslatedPath, $untranslatedLines, (New-Object Text.UTF8Encoding($false)))

$changedPath = Join-Path $ReportDir 'changed-files.txt'
[IO.File]::WriteAllLines($changedPath, $changedFiles, (New-Object Text.UTF8Encoding($false)))

$summary = [ordered]@{
    script_version = $ScriptVersion
    snapshot_date  = $SnapshotDate
    upstream_commit = $UpstreamCommit
    mapping_sha256 = $mapHash
    started_at     = (Get-Date).ToString('o')
    dry_run        = [bool]$DryRun
    files_scanned  = $stat.FilesScanned
    files_changed  = $stat.FilesChanged
    exact_replaced = $stat.Exact
    phrase_replaced = $stat.Phrase
    resx_replaced  = $stat.Resx
    untranslated_candidates = $stat.Untranslated
    stale_exact_keys = $staleKeys.Count
    bytes_before   = $stat.BytesBefore
    bytes_after    = $stat.BytesAfter
}
$summaryPath = Join-Path $ReportDir 'summary.json'
[IO.File]::WriteAllText($summaryPath, ($summary | ConvertTo-Json -Depth 4), (New-Object Text.UTF8Encoding($false)))

Write-Log INFO "报告已写入: $logPath"
Write-Log INFO "报告已写入: $untranslatedPath"
Write-Log INFO "报告已写入: $changedPath"
Write-Log INFO "报告已写入: $summaryPath"

# GitHub Actions 的 Step Summary：打开 CI 日志第一屏就能看到汉化是否生效。
if ($env:GITHUB_STEP_SUMMARY) {
    $md = @(
        '## 汉化 (zh-CN ' + $SnapshotDate + ')'
        ''
        '- 快照对应上游提交: `' + $UpstreamCommit + '`'
        '- 映射表 SHA256: `' + $mapHash + '`'
        '- 扫描文件: ' + $stat.FilesScanned + '，改写文件: ' + $stat.FilesChanged
        '- 精确替换: ' + $stat.Exact + '，词组替换: ' + $stat.Phrase + '，resx 替换: ' + $stat.Resx
        '- 未翻译候选: ' + $stat.Untranslated + '，失效映射: ' + $staleKeys.Count
        ''
        '详细报告见 artifact `Localization-Report-zh-CN`（含逐条原文/译文与未翻译清单）。'
    )
    Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Value ($md -join "`n") -Encoding UTF8
}

Write-Log INFO "=============================================================="
Write-Log INFO "汉化结束: exact=$($stat.Exact) phrase=$($stat.Phrase) resx=$($stat.Resx) 未翻译候选=$($stat.Untranslated) 失效映射=$($staleKeys.Count)"
Write-Log INFO "=============================================================="

# 注意：这里故意不因"未翻译候选/失效映射"而失败。
# 上游改文案后构建仍应能出包，同时把过时信息明明白白写进日志和报告。
