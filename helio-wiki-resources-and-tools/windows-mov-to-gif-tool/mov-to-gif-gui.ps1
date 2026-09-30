#requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [string[]] $InitialFiles,

    [switch] $AutoStart,

    [switch] $CloseWhenDone
)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

[System.Windows.Forms.Application]::EnableVisualStyles()

function Resolve-NativeTool {
    param([Parameter(Mandatory = $true)][string] $BaseName)

    $localPath = Join-Path -Path $PSScriptRoot -ChildPath ($BaseName + '.exe')
    if ([System.IO.File]::Exists($localPath)) {
        return [System.IO.Path]::GetFullPath($localPath)
    }

    $command = Get-Command ($BaseName + '.exe') -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($null -ne $command) {
        return $command.Source
    }
    return $null
}

function Quote-ProcessArgument {
    param([Parameter(Mandatory = $true)][string] $Value)

    # Windows file names cannot contain a quotation mark. Doubling trailing
    # backslashes keeps CommandLineToArgvW from consuming the closing quote.
    $escaped = $Value.Replace('"', '\"')
    $trailingSlashes = 0
    for ($index = $escaped.Length - 1; $index -ge 0 -and $escaped[$index] -eq '\'; $index--) {
        $trailingSlashes++
    }
    if ($trailingSlashes -gt 0) {
        $escaped += ('\' * $trailingSlashes)
    }
    return '"' + $escaped + '"'
}

$script:process = $null
$script:stdoutTask = $null
$script:stderrTask = $null

$form = New-Object System.Windows.Forms.Form
$form.Text = 'MOV 转 GIF（保持原尺寸和原帧节奏）'
$form.StartPosition = 'CenterScreen'
$form.Size = New-Object System.Drawing.Size(920, 700)
$form.MinimumSize = New-Object System.Drawing.Size(760, 560)
$form.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
$form.AllowDrop = $true

$titleLabel = New-Object System.Windows.Forms.Label
$titleLabel.Text = '把 MOV 拖到此窗口，或点击“添加 MOV”'
$titleLabel.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 14, [System.Drawing.FontStyle]::Bold)
$titleLabel.AutoSize = $true
$titleLabel.Location = New-Object System.Drawing.Point(18, 16)
$form.Controls.Add($titleLabel)

$policyLabel = New-Object System.Windows.Forms.Label
$policyLabel.Text = '默认保持原分辨率，不缩放、不裁剪、不主动降帧；GIF 输出到 MOV 原目录。'
$policyLabel.AutoSize = $true
$policyLabel.ForeColor = [System.Drawing.Color]::FromArgb(70, 70, 70)
$policyLabel.Location = New-Object System.Drawing.Point(20, 49)
$form.Controls.Add($policyLabel)

$fileList = New-Object System.Windows.Forms.ListBox
$fileList.Location = New-Object System.Drawing.Point(20, 78)
$fileList.Size = New-Object System.Drawing.Size(690, 170)
$fileList.Anchor = 'Top,Left,Right'
$fileList.HorizontalScrollbar = $true
$fileList.SelectionMode = 'MultiExtended'
$form.Controls.Add($fileList)

$addButton = New-Object System.Windows.Forms.Button
$addButton.Text = '添加 MOV'
$addButton.Location = New-Object System.Drawing.Point(725, 78)
$addButton.Size = New-Object System.Drawing.Size(155, 34)
$addButton.Anchor = 'Top,Right'
$form.Controls.Add($addButton)

$removeButton = New-Object System.Windows.Forms.Button
$removeButton.Text = '移除选中'
$removeButton.Location = New-Object System.Drawing.Point(725, 120)
$removeButton.Size = New-Object System.Drawing.Size(155, 34)
$removeButton.Anchor = 'Top,Right'
$form.Controls.Add($removeButton)

$clearButton = New-Object System.Windows.Forms.Button
$clearButton.Text = '清空列表'
$clearButton.Location = New-Object System.Drawing.Point(725, 162)
$clearButton.Size = New-Object System.Drawing.Size(155, 34)
$clearButton.Anchor = 'Top,Right'
$form.Controls.Add($clearButton)

$overwriteCheck = New-Object System.Windows.Forms.CheckBox
$overwriteCheck.Text = '允许覆盖已经存在的同名 GIF'
$overwriteCheck.AutoSize = $true
$overwriteCheck.Location = New-Object System.Drawing.Point(20, 260)
$form.Controls.Add($overwriteCheck)

$startButton = New-Object System.Windows.Forms.Button
$startButton.Text = '开始转换'
$startButton.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10, [System.Drawing.FontStyle]::Bold)
$startButton.Location = New-Object System.Drawing.Point(725, 214)
$startButton.Size = New-Object System.Drawing.Size(155, 70)
$startButton.Anchor = 'Top,Right'
$form.Controls.Add($startButton)

$progressBar = New-Object System.Windows.Forms.ProgressBar
$progressBar.Location = New-Object System.Drawing.Point(20, 294)
$progressBar.Size = New-Object System.Drawing.Size(860, 18)
$progressBar.Anchor = 'Top,Left,Right'
$form.Controls.Add($progressBar)

$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Text = '正在检查 FFmpeg…'
$statusLabel.AutoEllipsis = $true
$statusLabel.Location = New-Object System.Drawing.Point(20, 320)
$statusLabel.Size = New-Object System.Drawing.Size(860, 24)
$statusLabel.Anchor = 'Top,Left,Right'
$form.Controls.Add($statusLabel)

$logBox = New-Object System.Windows.Forms.RichTextBox
$logBox.Location = New-Object System.Drawing.Point(20, 350)
$logBox.Size = New-Object System.Drawing.Size(860, 260)
$logBox.Anchor = 'Top,Bottom,Left,Right'
$logBox.ReadOnly = $true
$logBox.BackColor = [System.Drawing.Color]::White
$logBox.Font = New-Object System.Drawing.Font('Consolas', 9)
$logBox.DetectUrls = $false
$form.Controls.Add($logBox)

$openFolderButton = New-Object System.Windows.Forms.Button
$openFolderButton.Text = '打开选中文件所在目录'
$openFolderButton.Location = New-Object System.Drawing.Point(20, 620)
$openFolderButton.Size = New-Object System.Drawing.Size(200, 30)
$openFolderButton.Anchor = 'Bottom,Left'
$form.Controls.Add($openFolderButton)

$clearLogButton = New-Object System.Windows.Forms.Button
$clearLogButton.Text = '清空日志'
$clearLogButton.Location = New-Object System.Drawing.Point(230, 620)
$clearLogButton.Size = New-Object System.Drawing.Size(110, 30)
$clearLogButton.Anchor = 'Bottom,Left'
$form.Controls.Add($clearLogButton)

function Append-Log {
    param([string] $Text)

    if ([string]::IsNullOrEmpty($Text)) { return }
    $logBox.AppendText($Text + [Environment]::NewLine)
    $logBox.SelectionStart = $logBox.TextLength
    $logBox.ScrollToCaret()
}

function Add-MovFiles {
    param([string[]] $Paths)

    foreach ($path in @($Paths)) {
        if ([string]::IsNullOrWhiteSpace($path)) { continue }
        if (-not [System.IO.File]::Exists($path)) {
            Append-Log ('忽略不存在的文件：{0}' -f $path)
            continue
        }
        if ([System.IO.Path]::GetExtension($path) -ine '.mov') {
            Append-Log ('忽略非 MOV 文件：{0}' -f $path)
            continue
        }
        $fullPath = [System.IO.Path]::GetFullPath($path)
        $alreadyAdded = $false
        foreach ($item in $fileList.Items) {
            if ([string]::Equals([string]$item, $fullPath, [System.StringComparison]::OrdinalIgnoreCase)) {
                $alreadyAdded = $true
                break
            }
        }
        if (-not $alreadyAdded) {
            [void] $fileList.Items.Add($fullPath)
        }
    }
    $startButton.Enabled = ($fileList.Items.Count -gt 0) -and ($null -eq $script:process)
}

function Set-RunningState {
    param([bool] $Running)

    $addButton.Enabled = -not $Running
    $removeButton.Enabled = -not $Running
    $clearButton.Enabled = -not $Running
    $overwriteCheck.Enabled = -not $Running
    $startButton.Enabled = (-not $Running) -and ($fileList.Items.Count -gt 0)
    if ($Running) {
        $progressBar.Style = 'Marquee'
        $progressBar.MarqueeAnimationSpeed = 25
    } else {
        $progressBar.Style = 'Blocks'
        $progressBar.Value = 0
    }
}

$addButton.Add_Click({
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Title = '选择一个或多个 MOV 文件'
    $dialog.Filter = 'MOV 视频 (*.mov)|*.mov|所有文件 (*.*)|*.*'
    $dialog.Multiselect = $true
    if ($dialog.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) {
        Add-MovFiles -Paths $dialog.FileNames
    }
    $dialog.Dispose()
})

$removeButton.Add_Click({
    $selected = @($fileList.SelectedItems)
    foreach ($item in $selected) { $fileList.Items.Remove($item) }
    $startButton.Enabled = ($fileList.Items.Count -gt 0) -and ($null -eq $script:process)
})

$clearButton.Add_Click({
    $fileList.Items.Clear()
    $startButton.Enabled = $false
})

$clearLogButton.Add_Click({ $logBox.Clear() })

$openFolderButton.Add_Click({
    if ($fileList.SelectedItem) {
        $folder = [System.IO.Path]::GetDirectoryName([string]$fileList.SelectedItem)
        Start-Process -FilePath 'explorer.exe' -ArgumentList (Quote-ProcessArgument -Value $folder)
    } else {
        [System.Windows.Forms.MessageBox]::Show($form, '请先在列表中选中一个 MOV。', '提示', 'OK', 'Information') | Out-Null
    }
})

$form.Add_DragEnter({
    param($sender, $eventArgs)
    if ($eventArgs.Data.GetDataPresent([System.Windows.Forms.DataFormats]::FileDrop)) {
        $eventArgs.Effect = [System.Windows.Forms.DragDropEffects]::Copy
    }
})

$form.Add_DragDrop({
    param($sender, $eventArgs)
    Add-MovFiles -Paths ([string[]]$eventArgs.Data.GetData([System.Windows.Forms.DataFormats]::FileDrop))
})

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 150
$timer.Add_Tick({
    if (($null -ne $script:process) -and $script:process.HasExited) {
        $script:process.WaitForExit()
        $standardOutput = $script:stdoutTask.Result
        $standardError = $script:stderrTask.Result
        if (-not [string]::IsNullOrWhiteSpace($standardOutput)) {
            Append-Log $standardOutput.TrimEnd()
        }
        if (-not [string]::IsNullOrWhiteSpace($standardError)) {
            Append-Log $standardError.TrimEnd()
        }
        $exitCode = $script:process.ExitCode
        $script:process.Dispose()
        $script:process = $null
        $script:stdoutTask = $null
        $script:stderrTask = $null
        Set-RunningState -Running $false

        if ($exitCode -eq 0) {
            $statusLabel.Text = '转换完成：全部成功。'
            $statusLabel.ForeColor = [System.Drawing.Color]::DarkGreen
            [System.Media.SystemSounds]::Asterisk.Play()
        } else {
            $statusLabel.Text = ('转换结束，但存在错误（返回码 {0}）。请查看下方完整日志。' -f $exitCode)
            $statusLabel.ForeColor = [System.Drawing.Color]::DarkRed
            [System.Media.SystemSounds]::Hand.Play()
        }

        if ($CloseWhenDone) {
            $form.Close()
        }
    }
})

$startButton.Add_Click({
    if ($fileList.Items.Count -eq 0) { return }

    $coreScript = Join-Path $PSScriptRoot 'mov-to-gif.ps1'
    if (-not [System.IO.File]::Exists($coreScript)) {
        [System.Windows.Forms.MessageBox]::Show($form, '缺少 mov-to-gif.ps1，无法开始转换。', '缺少文件', 'OK', 'Error') | Out-Null
        return
    }

    $arguments = @(
        '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
        '-File', (Quote-ProcessArgument -Value $coreScript)
    )
    if ($overwriteCheck.Checked) { $arguments += '-Force' }
    foreach ($item in $fileList.Items) {
        $arguments += (Quote-ProcessArgument -Value ([string]$item))
    }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'powershell.exe'
    $psi.Arguments = ($arguments -join ' ')
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    $psi.StandardOutputEncoding = $utf8
    $psi.StandardErrorEncoding = $utf8

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi

    try {
        [void] $process.Start()
        $script:process = $process
        $script:stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $script:stderrTask = $process.StandardError.ReadToEndAsync()
        Append-Log ('===== 开始转换 {0} 个文件：{1} =====' -f $fileList.Items.Count, (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
        $statusLabel.Text = ('正在转换 {0} 个文件，请不要关闭窗口…' -f $fileList.Items.Count)
        $statusLabel.ForeColor = [System.Drawing.Color]::DarkBlue
        Set-RunningState -Running $true
    } catch {
        $process.Dispose()
        Append-Log ('无法启动转换：{0}' -f $_.Exception.Message)
        $statusLabel.Text = '无法启动转换，请查看日志。'
        $statusLabel.ForeColor = [System.Drawing.Color]::DarkRed
    }
})

$form.Add_FormClosing({
    param($sender, $eventArgs)
    if ($null -ne $script:process) {
        $eventArgs.Cancel = $true
        [System.Windows.Forms.MessageBox]::Show(
            $form,
            '转换仍在进行。为避免产生不完整文件，请等待转换结束后再关闭窗口。',
            '正在转换',
            'OK',
            'Warning'
        ) | Out-Null
    }
})

$ffmpeg = Resolve-NativeTool -BaseName 'ffmpeg'
$ffprobe = Resolve-NativeTool -BaseName 'ffprobe'
if (($null -eq $ffmpeg) -or ($null -eq $ffprobe)) {
    $statusLabel.Text = '缺少 FFmpeg：请把 ffmpeg.exe 和 ffprobe.exe 放到本工具目录，或加入系统 PATH。'
    $statusLabel.ForeColor = [System.Drawing.Color]::DarkRed
    $startButton.Enabled = $false
    Append-Log '无法转换：没有同时找到 ffmpeg.exe 和 ffprobe.exe。'
    if ($null -eq $ffmpeg) { Append-Log '缺少：ffmpeg.exe' }
    if ($null -eq $ffprobe) { Append-Log '缺少：ffprobe.exe' }
} else {
    $statusLabel.Text = 'FFmpeg 已就绪。添加 MOV 后即可开始转换。'
    $statusLabel.ForeColor = [System.Drawing.Color]::DarkGreen
    Append-Log ('ffmpeg：{0}' -f $ffmpeg)
    Append-Log ('ffprobe：{0}' -f $ffprobe)
}

Add-MovFiles -Paths $InitialFiles
$form.Add_Shown({
    if ($AutoStart -and $startButton.Enabled) {
        $startButton.PerformClick()
    }
})
$timer.Start()
[void] $form.ShowDialog()
$timer.Stop()
$timer.Dispose()
$form.Dispose()
