# 汉化包快照 · 2026-11-28

> 本目录是**构建期汉化**的一套快照。目录名和文件名里的 `2026-11-28` 就是这套映射的制作日期。
> 同步主仓库后如果汉化失效，请先对照本文末尾的「过时后如何排查」。
>
> **本方案是纯附加的**：没有修改任何现有源码、`.csproj/.vbproj`、`Directory.Build.props`
> 或两个 workflow 文件；只新增了本目录和 `Managed Source/Directory.Build.targets` 这个自动接入点。
> 同步上游时不会产生源码冲突。

## 1. 它解决什么问题

本仓库的 WinForms 界面文字是硬编码在 `*.Designer.vb` 里的
（例如 `Me.btnRefresh.Text = "Refresh list"`），不是资源文件；而且默认发布形态是
`PublishSingleFile`，卫星程序集（`.zh-CN.resx`）默认不会打包进单文件 exe。
所以常规「加一个中文语言资源包」的办法对这个项目无效。

这里的做法是：**在 `dotnet publish` 之前，把工作区里的源码字面量替换成中文**，再照常构建。
因此界面、MessageBox、异常文本、Trace/Console 日志都会变成中文，且三个发布变体
（`net10-x64-single` / `net48` / `net10-x64`）以及 `build-all.yml` 的 CLI、Analyze、Setup
共用同一套映射。脚本只改 CI 的临时工作区，不写回仓库文件。

## 2. 文件清单

| 文件 | 作用 |
| --- | --- |
| `apply-zh-cn_2026-11-28.ps1` | 执行汉化的脚本。每行都有注释说明意图；逐条打印替换日志。 |
| `strings-zh-cn_2026-11-28.json` | 映射表。JSON 不支持注释，字段含义见第 4 节。 |
| `README_zh-CN_2026-11-28.md` | 本说明。 |
| `../../README.md` | 汉化包索引。 |
| `../../../Managed Source/Directory.Build.targets` | 自动接入点（新增文件，不改任何构建脚本）。 |

制作时对应的上游 `master` 提交：`b26f56c4fefaee021584c5bbb3a82592c4562189`
（提交信息：`docs(ci): document the artifact layout and the double-zip trap`）。

## 3. 如何自动接入构建（为什么不用改 build.yml）

MSBuild 会自动导入项目目录树上方的 `Directory.Build.targets`。新增的
`Managed Source/Directory.Build.targets` 定义了一个 `BeforeBuild` 钩子：

* 第一次真正编译时调用本脚本；成功后写 `localization-report/zh-cn_2026-11-28/.applied`，
  同一 job 的后续项目 / 多个 TFM 不再重复执行；
* 日志同时进入 Actions Step Summary 和报告目录（无需改 workflow 去上传 artifact）；
* 关闭方式：删除该 targets 文件，或 `dotnet publish -p:ZH_CN_DISABLE=true`；
* 同步上游后若源码变了，删掉 `.applied` 标记即可重新应用。

## 4. 映射表的四个字段

```jsonc
{
  "_meta": { ... },     // 快照元信息：日期、上游提交、维护方法、转义约定
  "exact":  { ... },    // 整条字面量精确匹配 -> 中文（界面文案、关键提示，优先执行）
  "phrases":{ ... },    // 词组替换（日志、报错，覆盖面广）
  "resx":   { ... },    // "相对路径|data name" -> 中文，替换 <value>，不动 resheader
  "doNotTranslate": [...] // 品牌名/字体名等：跳过词组替换，避免把品牌拆开翻译
}
```

关键约定（写新条目时必须遵守）：

1. **key 是「人眼看到的字符串」，不是源码原文。** VB 的 `""` 已还原成 `"`，C# 的 `\"`
   已还原成 `"`；脚本写回时会重新转义。
2. **`{...}` 占位符必须逐字照抄**，例如 `{ex.JoinMessages()}`、`{offset:X8}`。
   脚本把占位符视为代码，不翻译、不转义，避免把 `DiskDeviceNumber` 之类的标识符翻坏。
   插值表达式里出现的引号（如 `{string.Join(", ", checksums)}`）也属于占位符，照抄即可。
3. 长条目的换行：映射表统一用 `\n`（LF）。源码里若实际是 CRLF，脚本匹配时会归一化、
   写回时自动还原。
4. 大小写：PowerShell 5.1 的 `ConvertFrom-Json` 把属性名当**不区分大小写**，
   所以映射表里不能同时出现 `Cannot` 和 `cannot`。脚本的词组替换本身忽略大小写，
   只需保留一种写法。
5. 词组替换带**词边界**并允许可选复数 `s`：`File` 不会误伤 `filename`，`Drivers` 也能覆盖
   单数 `driver`。

## 5. 脚本每步在干什么（便于逐行理解）

1. 打印横幅：脚本版本、快照日期、上游提交、映射文件 SHA256、PowerShell 版本。
2. 读映射 JSON，构建精确字典、按长度降序排列的词组列表、resx 字典和跳过列表。
3. 遍历 `Managed Source` 下所有 `.vb` / `.cs` / `.resx`，排除 `TestProject`、`obj`、`bin`。
   *注意*：PowerShell 5.1 里 `-LiteralPath` 会让 `-Include` 失效，因此脚本改用扩展名过滤，
   否则会把 `.dll` 当文本改写、直接损坏产物。
4. 用正则切出字符串字面量；VB 的 `""`、C# 的 `@"` / `@$"` / `$@"` / `"..."` 都覆盖。
   插值占位符 `{...}` 在整个正则里被当作不可分割的单元。
5. 每条字面量：先查 `exact`；未命中且「像给人看的文案」时再做 `phrases`；
   路径、注册表键、XML 注释、带 `.dll` 的文件名等一律跳过词组替换。
6. 逐条打印 `EXACT` / `PHRASE` / `RESX` 日志（含文件名、行号、原文、译文）。
7. 只写回真正有变化的文件，且统一写成 **UTF-8 with BOM** —— VB 编译器在没有 BOM 时
   可能按系统 ANSI 代码页解码，中文会变乱码。
8. 输出报告目录：`apply.log`（完整日志）、`untranslated.txt`（未翻译候选）、
   `changed-files.txt`、`summary.json`（计数）。同时写入 GitHub Actions 的 Step Summary。
9. 故意**不因「未翻译候选 / 失效映射」而让构建失败**：上游改文案后仍要能出包，
   但过时信息会明明白白留在日志和报告里。

## 6. 本地验证（不需要 .NET SDK）

在有 PowerShell 5.1 或 7 的机器上：

```powershell
# 只分析、不写回源码
pwsh -File .github/localization/zh-CN_2026-11-28/apply-zh-cn_2026-11-28.ps1 `
  -SourceRoot 'Managed Source' -ReportDir 'E:\zh-report' -DryRun
```

然后在 `E:\zh-report\summary.json` 看计数，在 `untranslated.txt` 看漏掉的文案。
真机出包仍以 GitHub Actions 为准。

## 7. 过时后如何排查（同步主仓库之后必读）

打开 Actions 的构建日志，看汉化脚本那一步（`apply-zh-cn_2026-11-28.ps1`）：

| 日志关键字 | 含义 | 处理 |
| --- | --- | --- |
| `MAPPING_STALE` | 映射表里的某条 exact key 在源码里再也找不到了 | 上游改了/删了这句文案。删掉或更新映射表中该条目。 |
| `untranslated.txt` 里的行 | 源码里出现了新的英文文案，映射表没覆盖 | 把 `文件:行号` 和原文抄进 `exact`，给出中文译文。 |
| `[EXACT]` / `[PHRASE]` 条数骤降 | 汉化大面积失效 | 先核对脚本版本/映射 SHA256，再看是不是上游换了文件结构或编码。 |
| 产物仍是英文 | 脚本根本没跑，或跑在错误目录 | 检查 `Directory.Build.targets` 是否还在、`ZH_CN_DISABLE` 是否被设置、标记文件是否误留。 |

更新流程建议：

1. 同步上游后，先本地跑一次 `-DryRun`（见第 6 节），**不要**直接改映射；
2. 看 `summary.json` 的 `stale_exact_keys` 和 `untranslated_candidates`；
3. 只改映射 JSON（必要时改脚本正则），把文件/目录复制成新的日期快照，
   例如 `zh-CN_2027-01-15/`，再更新 `Directory.Build.targets` 里的版本路径；
4. 保留旧快照目录一两代，方便回滚和对照。

## 8. 已知限制

* 品牌/产品名（`Arsenal Image Mounter`、`DiscUtils`、`libewf` 等）和字体名保持原样，
  这是有意为之，不是在 `doNotTranslate` 里漏掉了。
* 部分技术性标识符、格式串、注册表路径不能翻译，翻了会破坏功能，因此保留 ASCII。
* `TestProject`（不随产品发布）不参与汉化。
* 词组替换是保守的批量兜底，个别句子可能呈「中英混杂」；追求质量的条目请加进 `exact`。
* 脚本每次运行都假定源码是**全新英文 checkout**；在已汉化的源码上再跑一次会大量
  命中 `MAPPING_STALE`，这是正常现象，不是错误。
