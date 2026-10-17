# ============================================================================
#  FNF Mod Manager - графический менеджер модов для Friday Night Funkin'
#  Windows Forms, без сторонних зависимостей. Запускать через FNF-ModManager.bat
# ============================================================================
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.IO.Compression.FileSystem

try { [Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false) } catch {}
[Windows.Forms.Application]::SetUnhandledExceptionMode([Windows.Forms.UnhandledExceptionMode]::CatchException)

# ---------------------------------------------------------------------------
#  Нативные помощники: тёмные вкладки, подсказка в поле поиска, тёмные скроллбары
# ---------------------------------------------------------------------------
if (-not ('DarkTabControl' -as [type])) {
Add-Type -ReferencedAssemblies 'System.Windows.Forms', 'System.Drawing' -TypeDefinition @"
using System;
using System.Drawing;
using System.Windows.Forms;
using System.Runtime.InteropServices;

public class DarkTabControl : TabControl
{
    public Color BarColor = Color.FromArgb(20, 20, 27);
    public Color TabColor = Color.FromArgb(30, 30, 40);
    public Color SelColor = Color.FromArgb(44, 44, 64);
    public Color AccentColor = Color.FromArgb(124, 92, 255);
    public Color TextColor = Color.FromArgb(150, 150, 172);
    public Color SelTextColor = Color.White;

    public DarkTabControl()
    {
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint |
                 ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
        SizeMode = TabSizeMode.Fixed;
        ItemSize = new Size(190, 38);
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        Graphics g = e.Graphics;
        g.Clear(BarColor);
        for (int i = 0; i < TabCount; i++)
        {
            Rectangle r = GetTabRect(i);
            bool sel = (i == SelectedIndex);
            using (SolidBrush b = new SolidBrush(sel ? SelColor : TabColor))
                g.FillRectangle(b, r);
            if (sel)
                using (SolidBrush a = new SolidBrush(AccentColor))
                    g.FillRectangle(a, r.X, r.Bottom - 3, r.Width, 3);
            TextRenderer.DrawText(g, TabPages[i].Text, Font, r, sel ? SelTextColor : TextColor,
                TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.EndEllipsis);
        }
    }
}

public static class NativeHelper
{
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern IntPtr SendMessage(IntPtr hWnd, int msg, IntPtr wParam, string lParam);

    [DllImport("uxtheme.dll", CharSet = CharSet.Unicode)]
    private static extern int SetWindowTheme(IntPtr hWnd, string pszSubAppName, string pszSubIdList);

    public static void SetCue(Control c, string text)
    {
        try { SendMessage(c.Handle, 0x1501, (IntPtr)1, text); } catch { }
    }

    public static void DarkScroll(Control c)
    {
        try { SetWindowTheme(c.Handle, "DarkMode_Explorer", null); } catch { }
    }
}
"@
}

# ---------------------------------------------------------------------------
#  Пути, глобальное состояние
# ---------------------------------------------------------------------------
$script:ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$script:ConfigFile   = Join-Path $script:ScriptDir 'config.json'
$script:ProfilesFile = Join-Path $script:ScriptDir 'profiles.json'
$script:LogFile      = Join-Path $script:ScriptDir 'history.log'
$script:BackupsDir   = Join-Path $script:ScriptDir 'backups'
$script:Utf8Bom      = New-Object System.Text.UTF8Encoding($true)
$script:Utf8NoBom    = New-Object System.Text.UTF8Encoding($false)

$script:Config   = $null
$script:Mods     = @()
$script:Profiles = @()
$script:ModCache = @{}
$script:MetaWarned = @{}
$script:txtLog   = $null
$script:form     = $null
$script:allLists = New-Object System.Collections.ArrayList
$script:darkCtls = New-Object System.Collections.ArrayList

# ---------------------------------------------------------------------------
#  Логирование
# ---------------------------------------------------------------------------
function Write-Log([string]$Status, [string]$Message) {
    $line = '[{0}] [СТАТУС: {1}] {2}' -f (Get-Date -Format 'dd.MM.yyyy HH:mm:ss'), $Status, $Message
    try { [IO.File]::AppendAllText($script:LogFile, $line + [Environment]::NewLine, $script:Utf8Bom) } catch {}
    if ($script:txtLog) {
        try {
            $script:txtLog.AppendText($line + "`r`n")
            $script:txtLog.SelectionStart = $script:txtLog.TextLength
            $script:txtLog.ScrollToCaret()
        } catch {}
    }
}

function Show-Msg([string]$Text, [string]$Icon = 'Information', [string]$Buttons = 'OK', [string]$Title = 'FNF Mod Manager') {
    $b = [Windows.Forms.MessageBoxButtons]$Buttons
    $i = [Windows.Forms.MessageBoxIcon]$Icon
    if ($script:form) { return [Windows.Forms.MessageBox]::Show($script:form, $Text, $Title, $b, $i) }
    return [Windows.Forms.MessageBox]::Show($Text, $Title, $b, $i)
}

function Ensure-Dir([string]$Path) {
    if ($Path -and -not (Test-Path -LiteralPath $Path)) {
        [void][IO.Directory]::CreateDirectory($Path)
    }
}

function Write-JsonFile([string]$Path, [string]$Json) {
    [IO.File]::WriteAllText($Path, $Json, $script:Utf8NoBom)
}

function Format-Size([long]$Bytes) {
    if ($Bytes -ge 1GB) { return ('{0:N2} ГБ' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N1} МБ' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N0} КБ' -f ($Bytes / 1KB)) }
    return "$Bytes Б"
}

# ---------------------------------------------------------------------------
#  Конфигурация
# ---------------------------------------------------------------------------
function Get-DefaultConfig {
    $sd = $script:ScriptDir
    if (Test-Path -LiteralPath (Join-Path $sd 'mods') -PathType Container) {
        $mods = Join-Path $sd 'mods'
    } elseif ((Split-Path -Leaf $sd) -ieq 'mods') {
        $mods = $sd
    } else {
        $par = Split-Path -Parent $sd
        if ($par -and (Test-Path -LiteralPath (Join-Path $par 'mods') -PathType Container)) {
            $mods = Join-Path $par 'mods'
        } else {
            $mods = Join-Path $sd 'mods'
        }
    }
    $base = Split-Path -Parent $mods
    if (-not $base) { $base = $sd }
    [pscustomobject]@{
        ModsPath     = $mods
        DisabledPath = (Join-Path $base 'mods_disabled')
        GameExe      = ''
    }
}

function Save-Config {
    Write-JsonFile $script:ConfigFile ($script:Config | ConvertTo-Json)
}

function Initialize-Config {
    $def = Get-DefaultConfig
    if (Test-Path -LiteralPath $script:ConfigFile -PathType Leaf) {
        try {
            $cfg = [IO.File]::ReadAllText($script:ConfigFile) | ConvertFrom-Json
            $m = ([string]$cfg.ModsPath).Trim().Trim('"').Trim()
            $d = ([string]$cfg.DisabledPath).Trim().Trim('"').Trim()
            $g = ([string]$cfg.GameExe).Trim().Trim('"').Trim()
            if ([string]::IsNullOrWhiteSpace($m)) { $m = $def.ModsPath }
            if ([string]::IsNullOrWhiteSpace($d)) { $d = $def.DisabledPath }
            $script:Config = [pscustomobject]@{ ModsPath = $m; DisabledPath = $d; GameExe = $g }
            return
        } catch {
            Write-Log 'ОШИБКА' "config.json повреждён ($($_.Exception.Message)); создаю заново, старый файл сохранён как config.json.bad"
            try { Move-Item -LiteralPath $script:ConfigFile -Destination ($script:ConfigFile + '.bad') -Force } catch {}
        }
    }
    $script:Config = $def
    Save-Config
    Write-Log 'УСПЕХ' 'Создан файл конфигурации config.json со значениями по умолчанию'
}

# ---------------------------------------------------------------------------
#  Профили
# ---------------------------------------------------------------------------
function Load-Profiles {
    $script:Profiles = @()
    if (-not (Test-Path -LiteralPath $script:ProfilesFile -PathType Leaf)) { return }
    try {
        $raw = [IO.File]::ReadAllText($script:ProfilesFile)
        if ([string]::IsNullOrWhiteSpace($raw)) { return }
        $parsed = ConvertFrom-Json -InputObject $raw
        # Гарантируем массив: 0, 1 или N элементов
        $arr = @($parsed)
        $script:Profiles = @($arr | Where-Object { $_ -and $_.Name })
    } catch {
        Write-Log 'ОШИБКА' "profiles.json повреждён: $($_.Exception.Message)"
        try { Move-Item -LiteralPath $script:ProfilesFile -Destination ($script:ProfilesFile + '.bad') -Force } catch {}
        $script:Profiles = @()
    }
}

function Save-Profiles {
    $arr = @($script:Profiles)
    if ($arr.Count -eq 0) {
        Write-JsonFile $script:ProfilesFile '[]'
        return
    }
    $json = ConvertTo-Json -InputObject $arr -Depth 6
    # PS 5.1 разворачивает одноэлементный массив в объект — принудительно оборачиваем в []
    # Используем StartsWith, чтобы избежать ошибки с wildcard-символом [
    if ($arr.Count -eq 1 -and -not $json.TrimStart().StartsWith('[')) {
        $json = "[$json]"
    }
    Write-JsonFile $script:ProfilesFile $json
}
# ---------------------------------------------------------------------------
#  Иконки и метаданные модов
# ---------------------------------------------------------------------------
function New-SquareIcon($Img, [int]$Size = 44) {
    $bmp = New-Object System.Drawing.Bitmap($Size, $Size)
    $g = [Drawing.Graphics]::FromImage($bmp)
    $g.InterpolationMode = 'HighQualityBicubic'
    $g.SmoothingMode = 'HighQuality'
    $g.PixelOffsetMode = 'HighQuality'
    $side = [Math]::Min($Img.Width, $Img.Height)
    $sx = [int](($Img.Width - $side) / 2)
    $sy = [int](($Img.Height - $side) / 2)
    $src = [Drawing.Rectangle]::new($sx, $sy, $side, $side)
    $dst = [Drawing.Rectangle]::new(0, 0, $Size, $Size)
    $g.DrawImage($Img, $dst, $src, [Drawing.GraphicsUnit]::Pixel)
    $g.Dispose()
    return $bmp
}

function New-PlaceholderIcon([string]$Title, [int]$Size = 44) {
    $palette = @('#7c5cff', '#2ea66f', '#e5853d', '#d9534f', '#3b82f6', '#c04fd6', '#14a3a3', '#b8a21f')
    $h = 0
    foreach ($ch in $Title.ToCharArray()) { $h = ($h * 31 + [int]$ch) % 1000 }
    $col = [Drawing.ColorTranslator]::FromHtml($palette[$h % $palette.Count])
    $bmp = New-Object System.Drawing.Bitmap($Size, $Size)
    $g = [Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $g.TextRenderingHint = 'AntiAliasGridFit'
    $br = [Drawing.SolidBrush]::new($col)
    $g.FillRectangle($br, 0, 0, $Size, $Size)
    $letter = '?'
    if ($Title) { $letter = $Title.Trim().Substring(0, 1).ToUpper() }
    $f = [Drawing.Font]::new('Segoe UI', [single]18, [Drawing.FontStyle]::Bold, [Drawing.GraphicsUnit]::Pixel)
    $sf = [Drawing.StringFormat]::new()
    $sf.Alignment = 'Center'
    $sf.LineAlignment = 'Center'
    $g.DrawString($letter, $f, [Drawing.Brushes]::White, [Drawing.RectangleF]::new(0, 0, $Size, $Size), $sf)
    $sf.Dispose(); $f.Dispose(); $br.Dispose(); $g.Dispose()
    return $bmp
}

function Get-ModIcon([string]$Dir, [string]$Title) {
    foreach ($n in 'pack.png', 'icon.png', 'avatar.png', '_polymod_icon.png') {
        $p = Join-Path $Dir $n
        if (Test-Path -LiteralPath $p -PathType Leaf) {
            try {
                # читаем в память, чтобы не блокировать файл
                $bytes = [IO.File]::ReadAllBytes($p)
                $ms = New-Object System.IO.MemoryStream(, $bytes)
                $img = [Drawing.Image]::FromStream($ms)
                try { return (New-SquareIcon $img) }
                finally { $img.Dispose(); $ms.Dispose() }
            } catch { }
        }
    }
    return (New-PlaceholderIcon $Title)
}

function Read-ModTitle([string]$Dir) {
    foreach ($f in 'pack.json', 'meta.json', '_polymod_meta.json') {
        $p = Join-Path $Dir $f
        if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { continue }
        try {
            $json = [IO.File]::ReadAllText($p, [Text.Encoding]::UTF8) | ConvertFrom-Json
            foreach ($k in 'name', 'title', 'mod_name', 'displayName') {
                $v = $json.$k
                if ($v -is [string] -and $v.Trim()) { return $v.Trim() }
            }
        } catch {
            if (-not $script:MetaWarned.ContainsKey($p)) {
                $script:MetaWarned[$p] = $true
                Write-Log 'ОШИБКА' "Не удалось прочитать $f в «$(Split-Path -Leaf $Dir)» - использую имя папки ($($_.Exception.Message))"
            }
        }
    }
    return $null
}

function Get-ModInfo([string]$Path, [string]$Folder) {
    if ($script:ModCache.ContainsKey($Path)) { return $script:ModCache[$Path] }
    $t = Read-ModTitle $Path
    if (-not $t) { $t = $Folder }
    $info = [pscustomobject]@{ Title = $t; Icon = (Get-ModIcon $Path $t) }
    $script:ModCache[$Path] = $info
    return $info
}

function Clear-ModCache {
    foreach ($k in @($script:ModCache.Keys)) {
        try { $script:ModCache[$k].Icon.Dispose() } catch {}
    }
    $script:ModCache = @{}
    $script:MetaWarned = @{}
}

function Get-ModDirs([string]$Root) {
    if ([string]::IsNullOrWhiteSpace($Root) -or -not (Test-Path -LiteralPath $Root -PathType Container)) { return @() }
    try {
        return @(Get-ChildItem -LiteralPath $Root -Directory -Force -ErrorAction Stop |
            Where-Object { $_.FullName -ne $script:BackupsDir -and -not ($_.Attributes -band [IO.FileAttributes]::Hidden) })
    } catch {
        Write-Log 'ОШИБКА' "Не удалось прочитать папку «$Root»: $($_.Exception.Message)"
        return @()
    }
}

function Load-Mods {
    $checked = @{}
    foreach ($m in $script:Mods) { if ($m.Checked) { $checked["$($m.Active)|$($m.Folder)"] = $true } }
    $list = New-Object System.Collections.ArrayList
    $roots = @(
        @{ Path = $script:Config.ModsPath;     Active = $true },
        @{ Path = $script:Config.DisabledPath; Active = $false }
    )
    foreach ($r in $roots) {
        foreach ($d in (Get-ModDirs $r.Path)) {
            try {
                $info = Get-ModInfo $d.FullName $d.Name
                [void]$list.Add([pscustomobject]@{
                    Folder  = $d.Name
                    Title   = $info.Title
                    Path    = $d.FullName
                    Active  = [bool]$r.Active
                    Icon    = $info.Icon
                    Checked = [bool]$checked["$($r.Active)|$($d.Name)"]
                })
            } catch {
                Write-Log 'ОШИБКА' "Не удалось обработать мод «$($d.Name)»: $($_.Exception.Message)"
            }
        }
    }
    $script:Mods = @($list | Sort-Object { $_.Title.ToLower() })
}

# ---------------------------------------------------------------------------
#  Игра: поиск exe, проверка процесса
# ---------------------------------------------------------------------------
function Get-GameSearchDir {
    $mods = ([string]$script:Config.ModsPath).Trim().Trim('"').Trim().TrimEnd('\', '/')
    if (-not $mods) { return $null }
    return [IO.Path]::GetDirectoryName($mods)
}

function Find-GameExe {
    try {
        # 1) exe, указанный вручную в настройках
        $custom = ([string]$script:Config.GameExe).Trim().Trim('"')
        if ($custom -and [IO.File]::Exists($custom)) { return $custom }

        # 2) автопоиск на уровень выше папки mods
        $parent = Get-GameSearchDir
        if (-not $parent -or -not [IO.Directory]::Exists($parent)) { return $null }
        $exes = @([IO.Directory]::GetFiles($parent, '*.exe') |
            Where-Object { [IO.Path]::GetFileName($_) -notmatch '^(unins|crash|update|vc_?redist|dxsetup)' })
        if ($exes.Count -eq 0) { return $null }
        $pref = @($exes | Where-Object { [IO.Path]::GetFileName($_) -match 'funkin|fnf|psych|engine' })
        if ($pref.Count -gt 0) { return [string]$pref[0] }
        return [string]$exes[0]
    } catch {
        $msg = $_.Exception.Message
        if ($script:ExeWarned -ne $msg) {
            $script:ExeWarned = $msg
            Write-Log 'ОШИБКА' "Поиск exe игры не удался: $msg"
        }
        return $null
    }
}

function Get-GameProcess {
    $names = @('Funkin')
    $exe = Find-GameExe
    if ($exe) { $names += [IO.Path]::GetFileNameWithoutExtension($exe) }
    foreach ($n in ($names | Select-Object -Unique)) {
        $pp = Get-Process -Name $n -ErrorAction SilentlyContinue
        if ($pp) { $pp }
    }
}

function Test-GameBlock([string]$What) {
    $p = @(Get-GameProcess)
    if ($p.Count -gt 0) {
        Write-Log 'ОШИБКА' "Действие «$What» заблокировано: игра запущена (процесс $($p[0].ProcessName), PID $($p[0].Id))"
        [void](Show-Msg "Friday Night Funkin' сейчас запущена.`r`n`r`nЗакройте игру и повторите действие («$What»), иначе файлы модов могут быть повреждены." 'Warning' 'OK' 'Игра запущена')
        return $true
    }
    return $false
}

# ---------------------------------------------------------------------------
#  Операции с модами
# ---------------------------------------------------------------------------
function Move-ModFolder([string]$Src, [string]$Dst) {
    $r1 = [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($Src))
    $r2 = [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($Dst))
    if ($r1 -eq $r2) {
        [IO.Directory]::Move($Src, $Dst)
    } else {
        Copy-Item -LiteralPath $Src -Destination $Dst -Recurse -Force -ErrorAction Stop
        Remove-Item -LiteralPath $Src -Recurse -Force -ErrorAction Stop
    }
}

# Возвращает @{Ok=..; Fail=..}; без диалогов, UI не обновляет
function Move-ModsCore($Mods, [bool]$ToDisabled) {
    $dest = if ($ToDisabled) { $script:Config.DisabledPath } else { $script:Config.ModsPath }
    $verb = if ($ToDisabled) { 'Выключен' } else { 'Включён' }
    $ok = 0; $fail = 0
    try { Ensure-Dir $dest } catch {
        Write-Log 'ОШИБКА' "Не удалось создать папку «$dest»: $($_.Exception.Message)"
        return @{ Ok = 0; Fail = @($Mods).Count }
    }
    foreach ($m in $Mods) {
        try {
            $target = Join-Path $dest $m.Folder
            if (Test-Path -LiteralPath $target) { throw "в папке назначения уже есть «$($m.Folder)»" }
            Move-ModFolder $m.Path $target
            if ($script:ModCache.ContainsKey($m.Path)) {
                $script:ModCache[$target] = $script:ModCache[$m.Path]
                $script:ModCache.Remove($m.Path)
            }
            Write-Log 'УСПЕХ' "$verb мод «$($m.Title)» ($($m.Folder))"
            $ok++
        } catch {
            Write-Log 'ОШИБКА' "$(if ($ToDisabled) { 'Не удалось выключить' } else { 'Не удалось включить' }) мод «$($m.Title)» ($($m.Folder)): $($_.Exception.Message)"
            $fail++
        }
    }
    return @{ Ok = $ok; Fail = $fail }
}

function Move-Mods($Mods, [bool]$ToDisabled) {
    $what = if ($ToDisabled) { 'выключение модов' } else { 'включение модов' }
    if (Test-GameBlock $what) { return }
    $Mods = @($Mods)
    if ($Mods.Count -eq 0) {
        [void](Show-Msg 'Отметьте галочками (или выделите) моды в нужном списке.' 'Information')
        return
    }
    $script:form.Cursor = 'WaitCursor'
    try {
        $res = Move-ModsCore $Mods $ToDisabled
        Refresh-All
    } finally { $script:form.Cursor = 'Default' }
    if ($res.Fail -gt 0) {
        [void](Show-Msg "Перенесено: $($res.Ok), с ошибками: $($res.Fail).`r`nПодробности - на вкладке «История»." 'Warning')
    }
}

function Get-TargetMods($Lv) {
    $c = @($Lv.Items | ForEach-Object { $_.Tag } | Where-Object { $_.Checked })
    if ($c.Count -eq 0) { $c = @($Lv.SelectedItems | ForEach-Object { $_.Tag }) }
    return $c
}

function Set-AllChecked($Lv, [bool]$State) {
    foreach ($it in $Lv.Items) { $it.Tag.Checked = $State }
    $Lv.Invalidate()
}

# ---------------------------------------------------------------------------
#  Бэкапы
# ---------------------------------------------------------------------------
function Get-ZipRoot([string]$Zip) {
    try {
        $z = [IO.Compression.ZipFile]::OpenRead($Zip)
        try {
            foreach ($en in $z.Entries) {
                $n = $en.FullName -replace '\\', '/'
                $p = $n.Split('/')[0]
                if ($p) { return $p }
            }
        } finally { $z.Dispose() }
    } catch { }
    return $null
}

function New-Backups($Mods) {
    $Mods = @($Mods)
    if ($Mods.Count -eq 0) {
        [void](Show-Msg 'Отметьте галочками (или выделите) моды, для которых нужен бэкап.' 'Information')
        return
    }
    Ensure-Dir $script:BackupsDir
    $ok = 0; $fail = 0
    $script:form.Cursor = 'WaitCursor'
    try {
        foreach ($m in $Mods) {
            $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
            $zip = Join-Path $script:BackupsDir ('{0}_{1}.zip' -f $m.Folder, $stamp)
            $i = 1
            while (Test-Path -LiteralPath $zip) {
                $zip = Join-Path $script:BackupsDir ('{0}_{1}_{2}.zip' -f $m.Folder, $stamp, $i)
                $i++
            }
            try {
                $script:slCount.Text = "Создаю бэкап: $($m.Title)..."
                [Windows.Forms.Application]::DoEvents()
                try {
                    Compress-Archive -LiteralPath $m.Path -DestinationPath $zip -CompressionLevel Optimal
                } catch {
                    Write-Log 'ИНФО' "Compress-Archive не справился для «$($m.Folder)» ($($_.Exception.Message)); пробую запасной способ .NET"
                    if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
                    [IO.Compression.ZipFile]::CreateFromDirectory($m.Path, $zip, [IO.Compression.CompressionLevel]::Optimal, $true)
                }
                $size = Format-Size ((Get-Item -LiteralPath $zip).Length)
                Write-Log 'УСПЕХ' "Создан бэкап мода «$($m.Title)» ($($m.Folder)) -> $(Split-Path -Leaf $zip), $size"
                $ok++
            } catch {
                Write-Log 'ОШИБКА' "Не удалось создать бэкап мода «$($m.Title)»: $($_.Exception.Message)"
                $fail++
            }
        }
    } finally { $script:form.Cursor = 'Default' }
    Update-BackupList
    Update-Status
    $icon = if ($fail -gt 0) { 'Warning' } else { 'Information' }
    [void](Show-Msg "Бэкапов создано: $ok, с ошибками: $fail.`r`nПапка: $($script:BackupsDir)" $icon)
}

function Restore-Backup {
    $sel = $script:lvBackups.SelectedItems
    if ($sel.Count -eq 0) {
        [void](Show-Msg 'Выберите бэкап в списке справа.' 'Information')
        return
    }
    if (Test-GameBlock 'восстановление из бэкапа') { return }
    $zip = [string]$sel[0].Tag
    $root = [string]$sel[0].SubItems[1].Text
    if (-not (Test-Path -LiteralPath $zip -PathType Leaf)) {
        [void](Show-Msg 'Файл бэкапа не найден. Обновите список.' 'Warning')
        Update-BackupList
        return
    }
    $existing = @($script:Mods | Where-Object { $_.Folder -eq $root }) | Select-Object -First 1
    $destRoot = if ($existing) { Split-Path -Parent $existing.Path } else { $script:Config.ModsPath }
    $q = "Восстановить мод «$root» из архива?`r`n`r`n"
    if ($existing) { $q += "ТЕКУЩАЯ папка мода будет УДАЛЕНА и заменена содержимым архива:`r`n$($existing.Path)" }
    else { $q += "Мод будет распакован в:`r`n$destRoot" }
    if ((Show-Msg $q 'Question' 'YesNo') -ne 'Yes') { return }

    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('fnfmm_' + [guid]::NewGuid().ToString('N'))
    $script:form.Cursor = 'WaitCursor'
    try {
        [Windows.Forms.Application]::DoEvents()
        # Сначала распаковываем во временную папку: если архив битый, текущий мод остаётся нетронутым
        Expand-Archive -LiteralPath $zip -DestinationPath $tmp -Force
        $src = Join-Path $tmp $root
        if (-not (Test-Path -LiteralPath $src -PathType Container)) { throw 'в архиве не найдена папка мода' }
        Ensure-Dir $destRoot
        if ($existing) { Remove-Item -LiteralPath $existing.Path -Recurse -Force }
        Move-ModFolder $src (Join-Path $destRoot $root)
        if ($existing) { $script:ModCache.Remove($existing.Path) }
        Write-Log 'УСПЕХ' "Мод «$root» восстановлен из бэкапа $(Split-Path -Leaf $zip)"
        Clear-ModCache
        Refresh-All
        [void](Show-Msg "Мод «$root» восстановлен." 'Information')
    } catch {
        Write-Log 'ОШИБКА' "Не удалось восстановить «$root» из $(Split-Path -Leaf $zip): $($_.Exception.Message)"
        [void](Show-Msg "Ошибка восстановления: $($_.Exception.Message)" 'Error')
    } finally {
        $script:form.Cursor = 'Default'
        try { if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force } } catch {}
    }
}

function Remove-Backup {
    $sel = $script:lvBackups.SelectedItems
    if ($sel.Count -eq 0) { [void](Show-Msg 'Выберите бэкап в списке.' 'Information'); return }
    $zip = [string]$sel[0].Tag
    if ((Show-Msg "Удалить файл бэкапа?`r`n$(Split-Path -Leaf $zip)" 'Question' 'YesNo') -ne 'Yes') { return }
    try {
        Remove-Item -LiteralPath $zip -Force
        Write-Log 'УСПЕХ' "Удалён бэкап $(Split-Path -Leaf $zip)"
    } catch {
        Write-Log 'ОШИБКА' "Не удалось удалить бэкап $(Split-Path -Leaf $zip): $($_.Exception.Message)"
    }
    Update-BackupList
}

# ---------------------------------------------------------------------------
#  Профили: действия
# ---------------------------------------------------------------------------
function New-Profile {
    $name = $script:txtProfName.Text.Trim()
    if (-not $name) { [void](Show-Msg 'Введите название профиля.' 'Information'); return }
    $active = @($script:Mods | Where-Object { $_.Active } | ForEach-Object { $_.Folder })
    $exists = @($script:Profiles | Where-Object { $_.Name -eq $name }).Count -gt 0
    if ($exists) {
        if ((Show-Msg "Профиль «$name» уже существует. Перезаписать?" 'Question' 'YesNo') -ne 'Yes') { return }
    }
    try {
        $others = @($script:Profiles | Where-Object { $_.Name -ne $name })
        $new = [pscustomobject]@{
            Name    = $name
            Created = (Get-Date -Format 'dd.MM.yyyy HH:mm:ss')
            Mods    = $active
        }
        $script:Profiles = @($others) + $new
        Save-Profiles
        Write-Log 'УСПЕХ' "Профиль «$name» сохранён (активных модов: $($active.Count))"
    } catch {
        Write-Log 'ОШИБКА' "Не удалось сохранить профиль «$name»: $($_.Exception.Message)"
        [void](Show-Msg "Ошибка сохранения профиля: $($_.Exception.Message)" 'Error')
    }
    Update-ProfileList $name
}

function Get-SelectedProfile {
    if ($script:lvProfiles.SelectedItems.Count -eq 0) { return $null }
    return $script:lvProfiles.SelectedItems[0].Tag
}

function Apply-Profile {
    $prof = Get-SelectedProfile
    if (-not $prof) { [void](Show-Msg 'Выберите профиль в списке.' 'Information'); return }
    if (Test-GameBlock 'применение профиля') { return }
    $want = @($prof.Mods)
    $toEnable  = @($script:Mods | Where-Object { -not $_.Active -and ($want -contains $_.Folder) })
    $toDisable = @($script:Mods | Where-Object { $_.Active -and -not ($want -contains $_.Folder) })
    $known = @($script:Mods | ForEach-Object { $_.Folder })
    $missing = @($want | Where-Object { $known -notcontains $_ })
    $q = "Применить профиль «$($prof.Name)»?`r`n`r`nБудет включено: $($toEnable.Count)`r`nБудет выключено: $($toDisable.Count)"
    if ($missing.Count -gt 0) { $q += "`r`nНе найдено на диске: $($missing.Count)" }
    if ((Show-Msg $q 'Question' 'YesNo') -ne 'Yes') { return }
    $script:form.Cursor = 'WaitCursor'
    try {
        $r1 = Move-ModsCore $toEnable $false
        $r2 = Move-ModsCore $toDisable $true
        foreach ($mf in $missing) { Write-Log 'ОШИБКА' "Профиль «$($prof.Name)»: мод «$mf» не найден ни в активных, ни в выключенных" }
        $fails = $r1.Fail + $r2.Fail
        $st = if ($fails -gt 0 -or $missing.Count -gt 0) { 'ОШИБКА' } else { 'УСПЕХ' }
        Write-Log $st "Применён профиль «$($prof.Name)»: включено $($r1.Ok), выключено $($r2.Ok), ошибок $fails, не найдено $($missing.Count)"
        Refresh-All
    } finally { $script:form.Cursor = 'Default' }
    if ($fails -gt 0 -or $missing.Count -gt 0) {
        [void](Show-Msg "Профиль применён с замечаниями (ошибок: $fails, не найдено модов: $($missing.Count)).`r`nСм. вкладку «История»." 'Warning')
    } else {
        [void](Show-Msg "Профиль «$($prof.Name)» применён." 'Information')
    }
}

function Remove-Profile {
    $prof = Get-SelectedProfile
    if (-not $prof) { [void](Show-Msg 'Выберите профиль в списке.' 'Information'); return }
    if ((Show-Msg "Удалить профиль «$($prof.Name)»?" 'Question' 'YesNo') -ne 'Yes') { return }
    try {
        $script:Profiles = @($script:Profiles | Where-Object { $_.Name -ne $prof.Name })
        Save-Profiles
        Write-Log 'УСПЕХ' "Профиль «$($prof.Name)» удалён"
    } catch {
        Write-Log 'ОШИБКА' "Не удалось удалить профиль «$($prof.Name)»: $($_.Exception.Message)"
    }
    Update-ProfileList
}

# ---------------------------------------------------------------------------
#  Тема и фабрики контролов
# ---------------------------------------------------------------------------
function New-Color([string]$Hex) { [Drawing.ColorTranslator]::FromHtml($Hex) }

$script:cBg      = New-Color '#14141b'
$script:cPanel   = New-Color '#1c1c27'
$script:cPanel2  = New-Color '#232333'
$script:cRow     = New-Color '#1e1e2a'
$script:cRowAlt  = New-Color '#222231'
$script:cSel     = New-Color '#38366a'
$script:cText    = New-Color '#e8e8f2'
$script:cMuted   = New-Color '#8a8aa6'
$script:cBorder  = New-Color '#33334a'
$script:cAccent  = New-Color '#7c5cff'
$script:cBtn     = New-Color '#2e2e44'
$script:cGreen   = New-Color '#2ea66f'
$script:cOrange  = New-Color '#d9742f'
$script:cRed     = New-Color '#c8454a'

$script:brRow    = [Drawing.SolidBrush]::new($script:cRow)
$script:brRowAlt = [Drawing.SolidBrush]::new($script:cRowAlt)
$script:brSel    = [Drawing.SolidBrush]::new($script:cSel)
$script:brText   = [Drawing.SolidBrush]::new($script:cText)
$script:brMuted  = [Drawing.SolidBrush]::new($script:cMuted)
$script:brAccent = [Drawing.SolidBrush]::new($script:cAccent)
$script:brHeader = [Drawing.SolidBrush]::new((New-Color '#2a2a3c'))
$script:penBorder = [Drawing.Pen]::new($script:cBorder, 1)
$script:penBox    = [Drawing.Pen]::new($script:cMuted, 1)
$script:penCheck  = [Drawing.Pen]::new([Drawing.Color]::White, 2)

$script:fontUI    = [Drawing.Font]::new('Segoe UI', [single]9.5)
$script:fontBold  = [Drawing.Font]::new('Segoe UI', [single]10, [Drawing.FontStyle]::Bold)
$script:fontSmall = [Drawing.Font]::new('Segoe UI', [single]8)
$script:fontHead  = [Drawing.Font]::new('Segoe UI', [single]10.5, [Drawing.FontStyle]::Bold)
$script:fontTitle = [Drawing.Font]::new('Segoe UI', [single]17, [Drawing.FontStyle]::Bold)
$script:fontBig   = [Drawing.Font]::new('Segoe UI', [single]12.5, [Drawing.FontStyle]::Bold)
$script:fontMono  = [Drawing.Font]::new('Consolas', [single]10)

$script:sf = [Drawing.StringFormat]::new()
$script:sf.Trimming = 'EllipsisCharacter'
$script:sf.FormatFlags = 'NoWrap'
$script:sf.LineAlignment = 'Near'

function Get-Shade([Drawing.Color]$C, [double]$F) {
    $r = [Math]::Min(255, [int]($C.R * $F)); $g = [Math]::Min(255, [int]($C.G * $F)); $b = [Math]::Min(255, [int]($C.B * $F))
    [Drawing.Color]::FromArgb($r, $g, $b)
}

function New-Btn([string]$Text, [int]$W = 140, [int]$H = 34, [string]$Kind = 'normal') {
    $b = New-Object Windows.Forms.Button
    $b.Text = $Text
    $b.Size = [Drawing.Size]::new($W, $H)
    $b.FlatStyle = 'Flat'
    $b.FlatAppearance.BorderSize = 0
    $col = switch ($Kind) {
        'accent' { $script:cAccent }
        'green'  { $script:cGreen }
        'orange' { $script:cOrange }
        'red'    { $script:cRed }
        default  { $script:cBtn }
    }
    $b.UseVisualStyleBackColor = $false
    $b.BackColor = $col
    $b.FlatAppearance.MouseOverBackColor = (Get-Shade $col 1.25)
    $b.FlatAppearance.MouseDownBackColor = (Get-Shade $col 0.8)
    $b.ForeColor = $script:cText
    $b.Font = $script:fontUI
    $b.Cursor = [Windows.Forms.Cursors]::Hand
    return $b
}

function New-Txt {
    $t = New-Object Windows.Forms.TextBox
    $t.BackColor = $script:cPanel2
    $t.ForeColor = $script:cText
    $t.BorderStyle = 'FixedSingle'
    $t.Font = $script:fontUI
    return $t
}

function New-Lbl([string]$Text, $Font = $null, $Color = $null) {
    $l = New-Object Windows.Forms.Label
    $l.Text = $Text
    $l.AutoSize = $true
    $l.BackColor = [Drawing.Color]::Transparent
    $l.ForeColor = if ($Color) { $Color } else { $script:cText }
    $l.Font = if ($Font) { $Font } else { $script:fontUI }
    return $l
}

function New-Tlp([int]$Cols, [int]$Rows) {
    $t = New-Object Windows.Forms.TableLayoutPanel
    $t.Dock = 'Fill'
    $t.ColumnCount = $Cols
    $t.RowCount = $Rows
    $t.BackColor = $script:cBg
    return $t
}
function Add-Col($T, [Windows.Forms.SizeType]$Type, [single]$Val) { [void]$T.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new($Type, $Val)) }
function Add-Row($T, [Windows.Forms.SizeType]$Type, [single]$Val) { [void]$T.RowStyles.Add([Windows.Forms.RowStyle]::new($Type, $Val)) }

function Fit-Cols($Lv) {
    $n = $Lv.Columns.Count
    if ($n -eq 0) { return }
    $used = 0
    for ($i = 0; $i -lt $n - 1; $i++) { $used += $Lv.Columns[$i].Width }
    $w = $Lv.ClientSize.Width - $used
    if ($w -gt 40) { $Lv.Columns[$n - 1].Width = $w }
}

function Enable-DoubleBuffer($Ctl) {
    try {
        $p = $Ctl.GetType().GetProperty('DoubleBuffered', [Reflection.BindingFlags]'NonPublic,Instance')
        $p.SetValue($Ctl, $true, $null)
    } catch {}
}

# Обычный тёмный список с колонками
function New-DetailList([string[]]$Cols, [int[]]$Widths, [bool]$Check = $false) {
    $lv = New-Object Windows.Forms.ListView
    $lv.View = 'Details'
    $lv.FullRowSelect = $true
    $lv.MultiSelect = $true
    $lv.HideSelection = $false
    $lv.BorderStyle = 'None'
    $lv.BackColor = $script:cRow
    $lv.ForeColor = $script:cText
    $lv.Font = $script:fontUI
    $lv.CheckBoxes = $Check
    $lv.OwnerDraw = $true
    $lv.Dock = 'Fill'
    for ($i = 0; $i -lt $Cols.Count; $i++) { [void]$lv.Columns.Add($Cols[$i], $Widths[$i]) }
    $lv.Add_DrawColumnHeader({
        param($s, $e)
        $e.Graphics.FillRectangle($script:brHeader, $e.Bounds)
        $e.Graphics.DrawLine($script:penBorder, $e.Bounds.Left, $e.Bounds.Bottom - 1, $e.Bounds.Right, $e.Bounds.Bottom - 1)
        $r = [Drawing.Rectangle]::new($e.Bounds.X + 8, $e.Bounds.Y, [Math]::Max(1, $e.Bounds.Width - 8), $e.Bounds.Height)
        [Windows.Forms.TextRenderer]::DrawText($e.Graphics, $e.Header.Text, $script:fontBold, $r, $script:cMuted,
            [Windows.Forms.TextFormatFlags]'VerticalCenter,Left,EndEllipsis')
    })
    $lv.Add_DrawSubItem({ param($s, $e) $e.DrawDefault = $true })
    $lv.Add_Resize({ param($s, $e) Fit-Cols $s })
    Enable-DoubleBuffer $lv
    [void]$script:allLists.Add($lv)
    [void]$script:darkCtls.Add($lv)
    return $lv
}

# Отрисовка строки списка модов: чекбокс + иконка + название + имя папки
$script:drawModItem = {
    param($s, $e)
    $m = $e.Item.Tag
    if ($null -eq $m) { return }
    $g = $e.Graphics
    $b = $e.Bounds
    if ($e.Item.Selected) { $br = $script:brSel }
    elseif (($e.ItemIndex % 2) -eq 1) { $br = $script:brRowAlt }
    else { $br = $script:brRow }
    $g.FillRectangle($br, $b)
    $g.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias

    $cx = $b.X + 10
    $cy = $b.Y + [int](($b.Height - 18) / 2)
    if ($m.Checked) {
        $g.FillRectangle($script:brAccent, $cx, $cy, 18, 18)
        $g.DrawLine($script:penCheck, $cx + 4, $cy + 9, $cx + 8, $cy + 13)
        $g.DrawLine($script:penCheck, $cx + 8, $cy + 13, $cx + 14, $cy + 5)
    } else {
        $g.DrawRectangle($script:penBox, $cx, $cy, 17, 17)
    }

    $ix = $b.X + 38
    $iy = $b.Y + [int](($b.Height - 44) / 2)
    if ($m.Icon) { $g.DrawImage($m.Icon, $ix, $iy, 44, 44) }

    $tx = $ix + 44 + 12
    $w = [Math]::Max(10, $b.Right - $tx - 8)
    $rect1 = [Drawing.RectangleF]::new($tx, $b.Y + 7, $w, 22)
    $rect2 = [Drawing.RectangleF]::new($tx, $b.Y + 30, $w, 18)
    $g.TextRenderingHint = 'ClearTypeGridFit'
    $g.DrawString($m.Title, $script:fontBold, $script:brText, $rect1, $script:sf)
    $g.DrawString($m.Folder, $script:fontSmall, $script:brMuted, $rect2, $script:sf)
    $g.DrawLine($script:penBorder, $b.X, $b.Bottom - 1, $b.Right, $b.Bottom - 1)
}

function New-ModList {
    $lv = New-Object Windows.Forms.ListView
    $lv.View = 'Details'
    $lv.FullRowSelect = $true
    $lv.MultiSelect = $true
    $lv.HideSelection = $false
    $lv.HeaderStyle = 'None'
    $lv.BorderStyle = 'None'
    $lv.BackColor = $script:cRow
    $lv.ForeColor = $script:cText
    $lv.OwnerDraw = $true
    $lv.Dock = 'Fill'
    # хитрость: высота строки задаётся высотой ImageList
    $il = New-Object Windows.Forms.ImageList
    $il.ImageSize = [Drawing.Size]::new(1, 54)
    $lv.SmallImageList = $il
    [void]$lv.Columns.Add('', 300)
    $lv.Add_DrawItem($script:drawModItem)
    $lv.Add_Resize({ param($s, $e) Fit-Cols $s })
    $lv.Add_MouseDown({
        param($s, $e)
        $it = $s.GetItemAt($e.X, $e.Y)
        if ($it -and $it.Tag -and $e.X -lt 36 -and $e.Button -eq 'Left') {
            $it.Tag.Checked = -not $it.Tag.Checked
            $s.Invalidate()
        }
    })
    $lv.Add_KeyDown({
        param($s, $e)
        if ($e.KeyCode -eq 'Space') {
            foreach ($it in $s.SelectedItems) { $it.Tag.Checked = -not $it.Tag.Checked }
            $s.Invalidate()
            $e.Handled = $true
            $e.SuppressKeyPress = $true
        }
    })
    Enable-DoubleBuffer $lv
    [void]$script:allLists.Add($lv)
    [void]$script:darkCtls.Add($lv)
    return $lv
}

function New-ModPanel {
    $p = New-Object Windows.Forms.TableLayoutPanel
    $p.Dock = 'Fill'
    $p.ColumnCount = 1
    $p.RowCount = 4
    $p.BackColor = $script:cPanel
    $p.Padding = [Windows.Forms.Padding]::new(8)
    Add-Col $p 'Percent' 100
    Add-Row $p 'Absolute' 32
    Add-Row $p 'Absolute' 38
    Add-Row $p 'Percent' 100
    Add-Row $p 'Absolute' 42

    $lbl = New-Object Windows.Forms.Label
    $lbl.Dock = 'Fill'
    $lbl.TextAlign = 'MiddleLeft'
    $lbl.Font = $script:fontHead
    $lbl.ForeColor = $script:cText

    $txt = New-Txt
    $txt.Dock = 'Fill'
    $txt.Margin = [Windows.Forms.Padding]::new(0, 4, 0, 6)

    $lv = New-ModList

    $fl = New-Object Windows.Forms.FlowLayoutPanel
    $fl.Dock = 'Fill'
    $fl.BackColor = $script:cPanel
    $fl.Padding = [Windows.Forms.Padding]::new(0, 6, 0, 0)
    $b1 = New-Btn 'Выбрать все' 120 30
    $b2 = New-Btn 'Снять выбор' 120 30
    $b1.Tag = $lv; $b2.Tag = $lv
    $b1.Add_Click({ param($s, $e) Set-AllChecked $s.Tag $true })
    $b2.Add_Click({ param($s, $e) Set-AllChecked $s.Tag $false })
    $fl.Controls.Add($b1)
    $fl.Controls.Add($b2)

    $p.Controls.Add($lbl, 0, 0)
    $p.Controls.Add($txt, 0, 1)
    $p.Controls.Add($lv, 0, 2)
    $p.Controls.Add($fl, 0, 3)
    return @{ Panel = $p; Label = $lbl; Search = $txt; LV = $lv }
}

# ---------------------------------------------------------------------------
#  Обновление интерфейса
# ---------------------------------------------------------------------------
function Update-ModLists {
    $sides = @(
        @{ LV = $script:lvActive;   Box = $script:txtSearchActive;   Active = $true;  Lbl = $script:lblActive;   Name = 'Активные моды' },
        @{ LV = $script:lvDisabled; Box = $script:txtSearchDisabled; Active = $false; Lbl = $script:lblDisabled; Name = 'Выключенные моды' }
    )
    foreach ($side in $sides) {
        $q = $side.Box.Text.Trim()
        $lv = $side.LV
        $total = 0; $shown = 0
        $lv.BeginUpdate()
        try {
            $lv.Items.Clear()
            foreach ($m in $script:Mods) {
                if ($m.Active -ne $side.Active) { continue }
                $total++
                if ($q) {
                    $hit = ($m.Title.IndexOf($q, [StringComparison]::OrdinalIgnoreCase) -ge 0) -or
                           ($m.Folder.IndexOf($q, [StringComparison]::OrdinalIgnoreCase) -ge 0)
                    if (-not $hit) { continue }
                }
                $it = [Windows.Forms.ListViewItem]::new('')
                $it.Tag = $m
                [void]$lv.Items.Add($it)
                $shown++
            }
        } finally { $lv.EndUpdate() }
        $suffix = if ($q) { " (найдено: $shown из $total)" } else { ": $total" }
        $side.Lbl.Text = $side.Name + $suffix
    }
}

function Update-BackupModList {
    $lv = $script:lvBkMods
    $prev = @{}
    foreach ($i in $lv.Items) { if ($i.Checked -and $i.Tag) { $prev[$i.Tag.Path] = $true } }
    $lv.BeginUpdate()
    try {
        $lv.Items.Clear()
        foreach ($m in $script:Mods) {
            $it = [Windows.Forms.ListViewItem]::new([string]$m.Title)
            [void]$it.SubItems.Add([string]$m.Folder)
            [void]$it.SubItems.Add($(if ($m.Active) { 'Активен' } else { 'Выключен' }))
            $it.Tag = $m
            $it.Checked = [bool]$prev[$m.Path]
            [void]$lv.Items.Add($it)
        }
    } finally { $lv.EndUpdate() }
}

function Update-BackupList {
    $lv = $script:lvBackups
    $lv.BeginUpdate()
    try {
        $lv.Items.Clear()
        if (Test-Path -LiteralPath $script:BackupsDir -PathType Container) {
            $files = @(Get-ChildItem -LiteralPath $script:BackupsDir -Filter '*.zip' -File | Sort-Object LastWriteTime -Descending)
            foreach ($f in $files) {
                $root = Get-ZipRoot $f.FullName
                if (-not $root) { $root = $f.BaseName }
                $it = [Windows.Forms.ListViewItem]::new([string]$f.Name)
                [void]$it.SubItems.Add([string]$root)
                [void]$it.SubItems.Add($f.LastWriteTime.ToString('dd.MM.yyyy HH:mm:ss'))
                [void]$it.SubItems.Add((Format-Size $f.Length))
                $it.Tag = $f.FullName
                [void]$lv.Items.Add($it)
            }
        }
    } catch {
        Write-Log 'ОШИБКА' "Не удалось прочитать список бэкапов: $($_.Exception.Message)"
    } finally { $lv.EndUpdate() }
}

function Update-ProfileDetail {
    $script:lbProfMods.Items.Clear()
    $prof = Get-SelectedProfile
    if (-not $prof) { return }
    $script:txtProfName.Text = [string]$prof.Name
    foreach ($f in @($prof.Mods)) {
        $m = @($script:Mods | Where-Object { $_.Folder -eq $f }) | Select-Object -First 1
        if ($m) { [void]$script:lbProfMods.Items.Add("$($m.Title)  ($f)") }
        else    { [void]$script:lbProfMods.Items.Add("$f  - НЕ НАЙДЕН") }
    }
}

function Update-ProfileList([string]$SelectName = $null) {
    $lv = $script:lvProfiles
    if (-not $SelectName -and $lv.SelectedItems.Count -gt 0) { $SelectName = $lv.SelectedItems[0].Tag.Name }
    $lv.BeginUpdate()
    try {
        $lv.Items.Clear()
        foreach ($p in $script:Profiles) {
            $it = [Windows.Forms.ListViewItem]::new([string]$p.Name)
            [void]$it.SubItems.Add([string]@($p.Mods).Count)
            [void]$it.SubItems.Add([string]$p.Created)
            $it.Tag = $p
            [void]$lv.Items.Add($it)
            if ($SelectName -and $p.Name -eq $SelectName) { $it.Selected = $true }
        }
    } finally { $lv.EndUpdate() }
    Update-ProfileDetail
}

function Update-GameLabel {
    $exe = Find-GameExe
    $running = @(Get-GameProcess).Count -gt 0
    if (-not $exe) {
        $script:lblGame.Text = "● exe игры не найден. Искал в: $(Get-GameSearchDir)  (можно указать вручную в «Настройках»)"
        $script:lblGame.ForeColor = $script:cOrange
    } elseif ($running) {
        $script:lblGame.Text = "● Игра запущена  -  $([IO.Path]::GetFileName($exe))"
        $script:lblGame.ForeColor = $script:cGreen
    } else {
        $script:lblGame.Text = "○ Игра не запущена  -  $([IO.Path]::GetFileName($exe))"
        $script:lblGame.ForeColor = $script:cMuted
    }
}

function Update-Status {
    $a = @($script:Mods | Where-Object { $_.Active }).Count
    $d = @($script:Mods | Where-Object { -not $_.Active }).Count
    $script:slCount.Text = "Активных модов: $a   |   Выключенных: $d   |   Всего: $($a + $d)"
    $exe = Find-GameExe
    $script:slGame.Text = if ($exe) { "Игра: $exe" } else { 'Игра: exe не найден' }
    if ($script:lblInfo) {
        $script:lblInfo.Text = "Конфиг: $($script:ConfigFile)`r`nПрофили: $($script:ProfilesFile)`r`nБэкапы: $($script:BackupsDir)`r`nЖурнал: $($script:LogFile)`r`nExe игры: $(if ($exe) { $exe } else { 'не найден' })"
    }
}

function Refresh-All {
    Load-Mods
    Update-ModLists
    Update-BackupModList
    Update-BackupList
    Update-ProfileList
    Update-Status
    Update-GameLabel
}

function Open-InExplorer([string]$Path) {
    try {
        if ([string]::IsNullOrWhiteSpace($Path)) { [void](Show-Msg 'Путь не задан.' 'Information'); return }
        Ensure-Dir $Path
        Start-Process -FilePath 'explorer.exe' -ArgumentList ('"' + $Path + '"')
    } catch {
        Write-Log 'ОШИБКА' "Не удалось открыть «$Path»: $($_.Exception.Message)"
    }
}

function Select-Folder([string]$Initial) {
    $dlg = New-Object Windows.Forms.FolderBrowserDialog
    $dlg.Description = 'Выберите папку'
    if ($Initial -and (Test-Path -LiteralPath $Initial -PathType Container)) { $dlg.SelectedPath = $Initial }
    if ($dlg.ShowDialog($script:form) -eq 'OK') { return $dlg.SelectedPath }
    return $null
}

function Save-Settings {
    $m = $script:txtModsPath.Text.Trim().Trim('"').Trim()
    $d = $script:txtDisabledPath.Text.Trim().Trim('"').Trim()
    $g = $script:txtGameExe.Text.Trim().Trim('"').Trim()
    if (-not $m -or -not $d) { [void](Show-Msg 'Укажите обе папки.' 'Warning'); return }
    try {
        if ($g -and -not [IO.File]::Exists($g)) { throw "указанный exe игры не существует: $g" }
        if (-not [IO.Path]::IsPathRooted($m) -or -not [IO.Path]::IsPathRooted($d)) { throw 'пути должны быть полными (например, C:\Games\FNF\mods)' }
        $fm = [IO.Path]::GetFullPath($m)
        $fd = [IO.Path]::GetFullPath($d)
        if ($fm -notmatch '^[a-zA-Z]:\\$') { $fm = $fm.TrimEnd('\') }
        if ($fd -notmatch '^[a-zA-Z]:\\$') { $fd = $fd.TrimEnd('\') }
        if ($fm -ieq $fd) { throw 'папки активных и выключенных модов не должны совпадать' }
        Ensure-Dir $fm
        Ensure-Dir $fd
        $script:Config = [pscustomobject]@{ ModsPath = $fm; DisabledPath = $fd; GameExe = $g }
        Save-Config
        $script:txtModsPath.Text = $fm
        $script:txtDisabledPath.Text = $fd
        Write-Log 'УСПЕХ' "Настройки сохранены. Активные: $fm; выключенные: $fd; exe: $(if ($g) { $g } else { 'автопоиск' })"
        Clear-ModCache
        Refresh-All
        $found = Find-GameExe
        if ($found) {
            Write-Log 'ИНФО' "Exe игры: $found"
            [void](Show-Msg "Настройки сохранены.`r`nExe игры: $found" 'Information')
        } else {
            Write-Log 'ОШИБКА' "Exe игры не найден в «$(Get-GameSearchDir)»"
            [void](Show-Msg "Настройки сохранены, но exe игры не найден в:`r`n$(Get-GameSearchDir)`r`n`r`nУкажите его вручную в поле «Exe игры».`r`nФайлы в этой папке: $(try { ([IO.Directory]::GetFiles((Get-GameSearchDir)) | ForEach-Object { [IO.Path]::GetFileName($_) } | Select-Object -First 8) -join ', ' } catch { 'не удалось прочитать' })" 'Warning')
        }
    } catch {
        Write-Log 'ОШИБКА' "Не удалось сохранить настройки: $($_.Exception.Message)"
        [void](Show-Msg "Ошибка: $($_.Exception.Message)" 'Error')
    }
}

# ===========================================================================
#  ГЛАВНАЯ ЧАСТЬ: построение окна и запуск
# ===========================================================================
try {
    [Windows.Forms.Application]::EnableVisualStyles()
    [Windows.Forms.Application]::add_ThreadException({
        param($s, $e)
        Write-Log 'ОШИБКА' ("Необработанная ошибка интерфейса: " + $e.Exception.Message)
    })

    Initialize-Config
    Ensure-Dir $script:Config.ModsPath
    Ensure-Dir $script:Config.DisabledPath
    Ensure-Dir $script:BackupsDir
    Load-Profiles

    # ---------------- Окно ----------------
    $form = New-Object Windows.Forms.Form
    $script:form = $form
    $form.Text = "FNF Mod Manager"
    $form.StartPosition = 'CenterScreen'
    $form.ClientSize = [Drawing.Size]::new(1180, 740)
    $form.MinimumSize = [Drawing.Size]::new(1000, 640)
    $form.BackColor = $script:cBg
    $form.ForeColor = $script:cText
    $form.Font = $script:fontUI

    # ---------------- Вкладки ----------------
    $tabs = New-Object DarkTabControl
    $tabs.Dock = 'Fill'
    $tabs.Font = $script:fontBold
    $tabs.Padding = [Drawing.Point]::new(12, 6)

    function New-Page([string]$Title) {
        $tp = New-Object Windows.Forms.TabPage
        $tp.Text = $Title
        $tp.UseVisualStyleBackColor = $false
        $tp.BackColor = $script:cBg
        $tp.ForeColor = $script:cText
        $tp.Padding = [Windows.Forms.Padding]::new(10)
        return $tp
    }
    $tpMods    = New-Page 'Управление модами'
    $tpProf    = New-Page 'Профили'
    $tpBackup  = New-Page 'Резервное копирование'
    $tpSet     = New-Page 'Настройки'
    $tpHistory = New-Page 'История'
    foreach ($tp in @($tpMods, $tpProf, $tpBackup, $tpSet, $tpHistory)) { [void]$tabs.TabPages.Add($tp) }

    # ---------------- Шапка ----------------
    $header = New-Object Windows.Forms.TableLayoutPanel
    $header.Dock = 'Top'
    $header.Height = 76
    $header.ColumnCount = 3
    $header.RowCount = 1
    $header.BackColor = $script:cPanel
    Add-Col $header 'AutoSize' 0
    Add-Col $header 'Percent' 100
    Add-Col $header 'Absolute' 370
    Add-Row $header 'Percent' 100

    $lblTitle = New-Lbl 'FNF MOD MANAGER' $script:fontTitle $script:cText
    $lblTitle.Anchor = 'Left'
    $lblTitle.Margin = [Windows.Forms.Padding]::new(18, 0, 24, 0)

    $script:lblGame = New-Lbl '' $script:fontUI $script:cMuted
    $script:lblGame.Anchor = 'Left'

    $flHead = New-Object Windows.Forms.FlowLayoutPanel
    $flHead.Dock = 'Fill'
    $flHead.FlowDirection = 'RightToLeft'
    $flHead.BackColor = $script:cPanel
    $flHead.Padding = [Windows.Forms.Padding]::new(0, 14, 12, 0)
    $btnLaunch = New-Btn '▶  ЗАПУСТИТЬ FNF' 230 48 'green'
    $btnLaunch.Font = $script:fontBig
    $btnRefresh = New-Btn 'Обновить' 110 48
    $flHead.Controls.Add($btnLaunch)
    $flHead.Controls.Add($btnRefresh)

    $header.Controls.Add($lblTitle, 0, 0)
    $header.Controls.Add($script:lblGame, 1, 0)
    $header.Controls.Add($flHead, 2, 0)

    # ---------------- Строка состояния ----------------
    $ss = New-Object Windows.Forms.StatusStrip
    $ss.BackColor = $script:cPanel
    $ss.ForeColor = $script:cText
    $ss.SizingGrip = $false
    $script:slCount = New-Object Windows.Forms.ToolStripStatusLabel
    $script:slCount.ForeColor = $script:cText
    $script:slCount.Font = $script:fontBold
    $script:slGame = New-Object Windows.Forms.ToolStripStatusLabel
    $script:slGame.Spring = $true
    $script:slGame.TextAlign = 'MiddleRight'
    $script:slGame.ForeColor = $script:cMuted
    [void]$ss.Items.Add($script:slCount)
    [void]$ss.Items.Add($script:slGame)

    # Порядок добавления важен для Dock: Fill первым, края - после него
    $form.Controls.Add($tabs)
    $form.Controls.Add($header)
    $form.Controls.Add($ss)

    # ================= Вкладка 1: Управление модами =================
    $tlpM = New-Tlp 3 1
    Add-Col $tlpM 'Percent' 50
    Add-Col $tlpM 'Absolute' 200
    Add-Col $tlpM 'Percent' 50
    Add-Row $tlpM 'Percent' 100

    $pa = New-ModPanel
    $pd = New-ModPanel
    $script:lvActive = $pa.LV;   $script:txtSearchActive = $pa.Search;   $script:lblActive = $pa.Label
    $script:lvDisabled = $pd.LV; $script:txtSearchDisabled = $pd.Search; $script:lblDisabled = $pd.Label
    $pa.Search.Add_TextChanged({ Update-ModLists })
    $pd.Search.Add_TextChanged({ Update-ModLists })

    $mid = New-Object Windows.Forms.TableLayoutPanel
    $mid.Dock = 'Fill'
    $mid.ColumnCount = 1
    $mid.RowCount = 4
    $mid.BackColor = $script:cBg
    Add-Col $mid 'Percent' 100
    Add-Row $mid 'Percent' 50
    Add-Row $mid 'Absolute' 64
    Add-Row $mid 'Absolute' 64
    Add-Row $mid 'Percent' 50
    $btnDisable = New-Btn 'Выключить выбранные  →' 170 54 'orange'
    $btnEnable  = New-Btn '←  Включить выбранные' 170 54 'green'
    $btnDisable.Dock = 'Fill'; $btnDisable.Margin = [Windows.Forms.Padding]::new(10, 5, 10, 5)
    $btnEnable.Dock = 'Fill';  $btnEnable.Margin = [Windows.Forms.Padding]::new(10, 5, 10, 5)
    $mid.Controls.Add($btnDisable, 0, 1)
    $mid.Controls.Add($btnEnable, 0, 2)

    $tlpM.Controls.Add($pa.Panel, 0, 0)
    $tlpM.Controls.Add($mid, 1, 0)
    $tlpM.Controls.Add($pd.Panel, 2, 0)
    $tpMods.Controls.Add($tlpM)

    $btnDisable.Add_Click({ Move-Mods @(Get-TargetMods $script:lvActive) $true })
    $btnEnable.Add_Click({ Move-Mods @(Get-TargetMods $script:lvDisabled) $false })

    # ================= Вкладка 2: Профили =================
    $tlpP = New-Tlp 2 3
    Add-Col $tlpP 'Percent' 58
    Add-Col $tlpP 'Percent' 42
    Add-Row $tlpP 'Absolute' 30
    Add-Row $tlpP 'Percent' 100
    Add-Row $tlpP 'Absolute' 64

    $l1 = New-Lbl 'Сохранённые профили' $script:fontHead; $l1.Margin = [Windows.Forms.Padding]::new(2, 6, 0, 0)
    $l2 = New-Lbl 'Состав выбранного профиля' $script:fontHead; $l2.Margin = [Windows.Forms.Padding]::new(10, 6, 0, 0)
    $script:lvProfiles = New-DetailList @('Название', 'Модов', 'Создан') @(240, 70, 170)
    $script:lvProfiles.MultiSelect = $false
    $script:lvProfiles.Margin = [Windows.Forms.Padding]::new(0, 0, 8, 0)
    $script:lvProfiles.Add_SelectedIndexChanged({ Update-ProfileDetail })

    $script:lbProfMods = New-Object Windows.Forms.ListBox
    $script:lbProfMods.Dock = 'Fill'
    $script:lbProfMods.BackColor = $script:cRow
    $script:lbProfMods.ForeColor = $script:cText
    $script:lbProfMods.BorderStyle = 'None'
    $script:lbProfMods.Font = $script:fontUI
    $script:lbProfMods.Margin = [Windows.Forms.Padding]::new(8, 0, 0, 0)
    [void]$script:darkCtls.Add($script:lbProfMods)

    $flP = New-Object Windows.Forms.FlowLayoutPanel
    $flP.Dock = 'Fill'
    $flP.BackColor = $script:cBg
    $flP.Padding = [Windows.Forms.Padding]::new(0, 12, 0, 0)
    $lblName = New-Lbl 'Название:'; $lblName.Margin = [Windows.Forms.Padding]::new(0, 8, 6, 0)
    $script:txtProfName = New-Txt
    $script:txtProfName.Width = 240
    $script:txtProfName.Margin = [Windows.Forms.Padding]::new(0, 5, 12, 0)
    $btnProfCreate = New-Btn 'Создать профиль' 160 36 'accent'
    $btnProfApply  = New-Btn 'Применить профиль' 170 36 'green'
    $btnProfDelete = New-Btn 'Удалить профиль' 150 36 'red'
    foreach ($c in @($lblName, $script:txtProfName, $btnProfCreate, $btnProfApply, $btnProfDelete)) { $flP.Controls.Add($c) }

    $tlpP.Controls.Add($l1, 0, 0)
    $tlpP.Controls.Add($l2, 1, 0)
    $tlpP.Controls.Add($script:lvProfiles, 0, 1)
    $tlpP.Controls.Add($script:lbProfMods, 1, 1)
    $tlpP.Controls.Add($flP, 0, 2)
    $tlpP.SetColumnSpan($flP, 2)
    $tpProf.Controls.Add($tlpP)

    $btnProfCreate.Add_Click({ New-Profile })
    $btnProfApply.Add_Click({ Apply-Profile })
    $btnProfDelete.Add_Click({ Remove-Profile })

    # ================= Вкладка 3: Резервное копирование =================
    $tlpB = New-Tlp 2 3
    Add-Col $tlpB 'Percent' 45
    Add-Col $tlpB 'Percent' 55
    Add-Row $tlpB 'Absolute' 30
    Add-Row $tlpB 'Percent' 100
    Add-Row $tlpB 'Absolute' 56

    $b1 = New-Lbl 'Все обнаруженные моды (отметьте нужные)' $script:fontHead; $b1.Margin = [Windows.Forms.Padding]::new(2, 6, 0, 0)
    $b2 = New-Lbl 'Созданные бэкапы' $script:fontHead; $b2.Margin = [Windows.Forms.Padding]::new(10, 6, 0, 0)
    $script:lvBkMods = New-DetailList @('Название', 'Папка', 'Статус') @(210, 150, 90) $true
    $script:lvBkMods.Margin = [Windows.Forms.Padding]::new(0, 0, 8, 0)
    $script:lvBackups = New-DetailList @('Файл', 'Мод', 'Создан', 'Размер') @(250, 130, 150, 90)
    $script:lvBackups.MultiSelect = $false
    $script:lvBackups.Margin = [Windows.Forms.Padding]::new(8, 0, 0, 0)

    $flB1 = New-Object Windows.Forms.FlowLayoutPanel
    $flB1.Dock = 'Fill'; $flB1.BackColor = $script:cBg; $flB1.Padding = [Windows.Forms.Padding]::new(0, 10, 0, 0)
    $btnBackup = New-Btn 'Создать бэкап (.zip)' 190 36 'accent'
    $flB1.Controls.Add($btnBackup)

    $flB2 = New-Object Windows.Forms.FlowLayoutPanel
    $flB2.Dock = 'Fill'; $flB2.BackColor = $script:cBg; $flB2.Padding = [Windows.Forms.Padding]::new(8, 10, 0, 0)
    $btnRestore = New-Btn 'Восстановить из бэкапа' 200 36 'green'
    $btnBkDelete = New-Btn 'Удалить бэкап' 130 36 'red'
    $btnBkOpen = New-Btn 'Открыть папку' 130 36
    foreach ($c in @($btnRestore, $btnBkDelete, $btnBkOpen)) { $flB2.Controls.Add($c) }

    $tlpB.Controls.Add($b1, 0, 0)
    $tlpB.Controls.Add($b2, 1, 0)
    $tlpB.Controls.Add($script:lvBkMods, 0, 1)
    $tlpB.Controls.Add($script:lvBackups, 1, 1)
    $tlpB.Controls.Add($flB1, 0, 2)
    $tlpB.Controls.Add($flB2, 1, 2)
    $tpBackup.Controls.Add($tlpB)

    $btnBackup.Add_Click({
        $t = @($script:lvBkMods.CheckedItems | ForEach-Object { $_.Tag })
        if ($t.Count -eq 0) { $t = @($script:lvBkMods.SelectedItems | ForEach-Object { $_.Tag }) }
        New-Backups $t
    })
    $btnRestore.Add_Click({ Restore-Backup })
    $btnBkDelete.Add_Click({ Remove-Backup })
    $btnBkOpen.Add_Click({ Open-InExplorer $script:BackupsDir })

    # ================= Вкладка 4: Настройки =================
    $tlpS = New-Object Windows.Forms.TableLayoutPanel
    $tlpS.Dock = 'Top'
    $tlpS.Height = 440
    $tlpS.ColumnCount = 4
    $tlpS.RowCount = 8
    $tlpS.BackColor = $script:cBg
    Add-Col $tlpS 'Percent' 100
    Add-Col $tlpS 'Absolute' 110
    Add-Col $tlpS 'Absolute' 200
    Add-Col $tlpS 'Absolute' 10
    Add-Row $tlpS 'Absolute' 34
    Add-Row $tlpS 'Absolute' 46
    Add-Row $tlpS 'Absolute' 34
    Add-Row $tlpS 'Absolute' 46
    Add-Row $tlpS 'Absolute' 34
    Add-Row $tlpS 'Absolute' 46
    Add-Row $tlpS 'Absolute' 56
    Add-Row $tlpS 'Percent' 100

    $lm = New-Lbl 'Папка активных модов (mods):' $script:fontHead; $lm.Margin = [Windows.Forms.Padding]::new(2, 10, 0, 0)
    $ld = New-Lbl 'Папка выключенных модов:' $script:fontHead; $ld.Margin = [Windows.Forms.Padding]::new(2, 10, 0, 0)
    $script:txtModsPath = New-Txt
    $script:txtModsPath.Dock = 'Fill'; $script:txtModsPath.Margin = [Windows.Forms.Padding]::new(2, 6, 8, 6)
    $script:txtModsPath.Text = $script:Config.ModsPath
    $script:txtDisabledPath = New-Txt
    $script:txtDisabledPath.Dock = 'Fill'; $script:txtDisabledPath.Margin = [Windows.Forms.Padding]::new(2, 6, 8, 6)
    $script:txtDisabledPath.Text = $script:Config.DisabledPath
    $btnBrM = New-Btn 'Обзор...' 100 32; $btnBrM.Margin = [Windows.Forms.Padding]::new(0, 6, 8, 6)
    $btnBrD = New-Btn 'Обзор...' 100 32; $btnBrD.Margin = [Windows.Forms.Padding]::new(0, 6, 8, 6)
    $btnOpM = New-Btn 'Открыть в Проводнике' 190 32; $btnOpM.Margin = [Windows.Forms.Padding]::new(0, 6, 0, 6)
    $btnOpD = New-Btn 'Открыть в Проводнике' 190 32; $btnOpD.Margin = [Windows.Forms.Padding]::new(0, 6, 0, 6)
    $lg = New-Lbl 'Exe игры (необязательно; если пусто - ищется на уровень выше папки mods):' $script:fontHead; $lg.Margin = [Windows.Forms.Padding]::new(2, 10, 0, 0)
    $script:txtGameExe = New-Txt
    $script:txtGameExe.Dock = 'Fill'; $script:txtGameExe.Margin = [Windows.Forms.Padding]::new(2, 6, 8, 6)
    $script:txtGameExe.Text = [string]$script:Config.GameExe
    $btnBrG = New-Btn 'Обзор...' 100 32; $btnBrG.Margin = [Windows.Forms.Padding]::new(0, 6, 8, 6)
    $btnClrG = New-Btn 'Сбросить (автопоиск)' 190 32; $btnClrG.Margin = [Windows.Forms.Padding]::new(0, 6, 0, 6)
    $btnSave = New-Btn 'Сохранить' 160 38 'accent'; $btnSave.Margin = [Windows.Forms.Padding]::new(2, 10, 0, 6)
    $script:lblInfo = New-Lbl '' $script:fontSmall $script:cMuted
    $script:lblInfo.Margin = [Windows.Forms.Padding]::new(2, 8, 0, 0)

    $tlpS.Controls.Add($lm, 0, 0);               $tlpS.SetColumnSpan($lm, 3)
    $tlpS.Controls.Add($script:txtModsPath, 0, 1)
    $tlpS.Controls.Add($btnBrM, 1, 1)
    $tlpS.Controls.Add($btnOpM, 2, 1)
    $tlpS.Controls.Add($ld, 0, 2);               $tlpS.SetColumnSpan($ld, 3)
    $tlpS.Controls.Add($script:txtDisabledPath, 0, 3)
    $tlpS.Controls.Add($btnBrD, 1, 3)
    $tlpS.Controls.Add($btnOpD, 2, 3)
    $tlpS.Controls.Add($lg, 0, 4);               $tlpS.SetColumnSpan($lg, 3)
    $tlpS.Controls.Add($script:txtGameExe, 0, 5)
    $tlpS.Controls.Add($btnBrG, 1, 5)
    $tlpS.Controls.Add($btnClrG, 2, 5)
    $tlpS.Controls.Add($btnSave, 0, 6)
    $tlpS.Controls.Add($script:lblInfo, 0, 7);   $tlpS.SetColumnSpan($script:lblInfo, 3)
    $tpSet.Controls.Add($tlpS)

    $btnBrG.Add_Click({
        $dlg = New-Object Windows.Forms.OpenFileDialog
        $dlg.Filter = 'Программы (*.exe)|*.exe'
        $dlg.Title = 'Выберите exe игры'
        $start = Get-GameSearchDir
        if ($start -and [IO.Directory]::Exists($start)) { $dlg.InitialDirectory = $start }
        if ($dlg.ShowDialog($script:form) -eq 'OK') { $script:txtGameExe.Text = $dlg.FileName }
    })
    $btnClrG.Add_Click({ $script:txtGameExe.Text = '' })

    $btnBrM.Add_Click({
        $p = Select-Folder $script:txtModsPath.Text
        if ($p) { $script:txtModsPath.Text = $p }
    })
    $btnBrD.Add_Click({
        $p = Select-Folder $script:txtDisabledPath.Text
        if ($p) { $script:txtDisabledPath.Text = $p }
    })
    $btnOpM.Add_Click({ Open-InExplorer $script:txtModsPath.Text.Trim() })
    $btnOpD.Add_Click({ Open-InExplorer $script:txtDisabledPath.Text.Trim() })
    $btnSave.Add_Click({ Save-Settings })

    # ================= Вкладка 5: История =================
    $tlpH = New-Tlp 1 2
    Add-Col $tlpH 'Percent' 100
    Add-Row $tlpH 'Percent' 100
    Add-Row $tlpH 'Absolute' 50

    $script:txtLog = New-Object Windows.Forms.TextBox
    $script:txtLog.Multiline = $true
    $script:txtLog.ReadOnly = $true
    $script:txtLog.ScrollBars = 'Vertical'
    $script:txtLog.WordWrap = $true
    $script:txtLog.Dock = 'Fill'
    $script:txtLog.BackColor = $script:cRow
    $script:txtLog.ForeColor = $script:cText
    $script:txtLog.BorderStyle = 'None'
    $script:txtLog.Font = $script:fontMono
    [void]$script:darkCtls.Add($script:txtLog)

    $flH = New-Object Windows.Forms.FlowLayoutPanel
    $flH.Dock = 'Fill'; $flH.BackColor = $script:cBg; $flH.Padding = [Windows.Forms.Padding]::new(0, 10, 0, 0)
    $btnLogClear = New-Btn 'Очистить окно' 150 34
    $btnLogOpen = New-Btn 'Открыть history.log' 190 34
    $flH.Controls.Add($btnLogClear)
    $flH.Controls.Add($btnLogOpen)

    $tlpH.Controls.Add($script:txtLog, 0, 0)
    $tlpH.Controls.Add($flH, 0, 1)
    $tpHistory.Controls.Add($tlpH)

    $btnLogClear.Add_Click({ $script:txtLog.Clear() })
    $btnLogOpen.Add_Click({
        try {
            if (-not (Test-Path -LiteralPath $script:LogFile)) { [IO.File]::WriteAllText($script:LogFile, '', $script:Utf8Bom) }
            Start-Process -FilePath 'notepad.exe' -ArgumentList ('"' + $script:LogFile + '"')
        } catch { Write-Log 'ОШИБКА' "Не удалось открыть history.log: $($_.Exception.Message)" }
    })

    # Подгружаем последние записи журнала в окно
    try {
        if (Test-Path -LiteralPath $script:LogFile -PathType Leaf) {
            $tail = @(Get-Content -LiteralPath $script:LogFile -Tail 300 -Encoding UTF8)
            if ($tail.Count -gt 0) { $script:txtLog.Text = ($tail -join "`r`n") + "`r`n" }
        }
    } catch {}

    # ================= Общие обработчики =================
    $btnRefresh.Add_Click({
        Clear-ModCache
        Refresh-All
        Write-Log 'ИНФО' 'Список модов обновлён'
    })

    $btnLaunch.Add_Click({
        $exe = Find-GameExe
        if (-not $exe) {
            $par = Get-GameSearchDir
            Write-Log 'ОШИБКА' "Не найден exe игры в папке «$par»"
            [void](Show-Msg "Не найден .exe файл игры.`r`nОн должен лежать на уровень выше папки модов:`r`n$par" 'Warning')
            return
        }
        if (@(Get-GameProcess).Count -gt 0) {
            [void](Show-Msg 'Игра уже запущена.' 'Information')
            return
        }
        try {
            Start-Process -FilePath $exe -WorkingDirectory (Split-Path -Parent $exe)
            Write-Log 'УСПЕХ' "Запущена игра: $exe"
        } catch {
            Write-Log 'ОШИБКА' "Не удалось запустить игру: $($_.Exception.Message)"
            [void](Show-Msg "Не удалось запустить игру: $($_.Exception.Message)" 'Error')
        }
    })

    $timer = New-Object Windows.Forms.Timer
    $timer.Interval = 3000
    $timer.Add_Tick({ try { Update-GameLabel } catch {} })

    $form.Add_Shown({
        foreach ($c in @($script:txtSearchActive, $script:txtSearchDisabled)) {
            [NativeHelper]::SetCue($c, 'Поиск по названию или папке...')
        }
        foreach ($c in $script:darkCtls) { [NativeHelper]::DarkScroll($c) }
        foreach ($lv in $script:allLists) { Fit-Cols $lv }
        $timer.Start()
    })
    $form.Add_FormClosing({ $timer.Stop() })

    Write-Log 'ИНФО' "Менеджер модов запущен. Активные: $($script:Config.ModsPath); выключенные: $($script:Config.DisabledPath)"
    Refresh-All

    [Windows.Forms.Application]::Run($form)
}
catch {
    $msg = $_.Exception.Message + "`r`n" + $_.ScriptStackTrace
    try { [IO.File]::AppendAllText((Join-Path $script:ScriptDir 'crash.log'), "[$(Get-Date)] $msg`r`n", $script:Utf8Bom) } catch {}
    try { [void][Windows.Forms.MessageBox]::Show("Критическая ошибка:`r`n`r`n$msg", 'FNF Mod Manager', 'OK', 'Error') } catch {}
}
