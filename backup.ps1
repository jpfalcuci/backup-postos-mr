# Backup de um posto para o OneDrive via rclone. Nunca apaga nada no destino.
#   -Modo Rapido   : so arquivos alterados nas ultimas 48h das pastas marcadas "Rapido" (tarefa a cada 15 min)
#   -Modo Completo : todas as pastas, comparando tudo (tarefa diaria; pega o que o rapido deixou passar)
# Arquivo que seria sobrescrito no OneDrive vai antes para _versoes/<data-hora>/<pasta>.
param(
    [ValidateSet('Rapido', 'Completo')][string]$Modo = 'Rapido',
    [string]$Pasta = $PSScriptRoot   # onde ficam config.json, rclone.exe, rclone.conf e logs\
)
$ErrorActionPreference = 'Stop'
$cfg = Get-Content (Join-Path $Pasta 'config.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$rclone = Join-Path $Pasta 'rclone.exe'
$logs = Join-Path $Pasta 'logs'
New-Item -ItemType Directory -Force $logs | Out-Null
$log = Join-Path $logs ('{0:yyyy-MM-dd}-{1}.log' -f (Get-Date), $Modo.ToLower())
function Escrever($texto) { Add-Content -Path $log -Value ('{0:yyyy/MM/dd HH:mm:ss} {1}' -f (Get-Date), $texto) -Encoding UTF8 }

# healthchecks.io: cada execucao sem erro avisa "estou vivo". Se o aviso parar de chegar
# (maquina desligada, sem internet, tarefa parada, erro repetido), o healthchecks manda o alerta.
function Avisar($corpo) {
    if (-not $cfg.HealthcheckUrl) { return }
    try { Invoke-RestMethod -Method Post -Uri $cfg.HealthcheckUrl -Body $corpo -TimeoutSec 15 | Out-Null }
    catch { Escrever "Aviso ao healthchecks falhou: $($_.Exception.Message)" }
}

# Uma execucao por vez. O completo espera o rapido terminar (ate 30 min); o rapido nao espera o
# completo e sai avisando que esta vivo (o completo tem limite de 12 h na tarefa agendada).
$trava = New-Object System.Threading.Mutex($false, 'Global\BackupPostos')
$espera = if ($Modo -eq 'Completo') { [TimeSpan]::FromMinutes(30) } else { [TimeSpan]::Zero }
try { $peguei = $trava.WaitOne($espera) }
catch [System.Threading.AbandonedMutexException] { $peguei = $true }   # execucao anterior foi encerrada a forca
if (-not $peguei) { Escrever "$Modo ignorado: outra execucao em andamento."; Avisar "Posto $($cfg.Posto), $Modo ignorado: outra execucao em andamento"; exit 0 }
try {
    $carimbo = Get-Date -Format 'yyyy-MM-dd_HHmmss'
    $falhas = @()
    foreach ($p in $cfg.Pastas) {
        if ($Modo -eq 'Rapido' -and -not $p.Rapido) { continue }
        $destino = "$($cfg.Remoto):$($cfg.PastaRemota)/$($p.Nome)"
        $parametros = @('copy', $p.Caminho, $destino,
            '--backup-dir', "$($cfg.Remoto):$($cfg.PastaRemota)/_versoes/$carimbo/$($p.Nome)",
            '--config', (Join-Path $Pasta 'rclone.conf'), '--log-file', $log, '--log-level', 'INFO',
            '--retries', '3', '--low-level-retries', '10', '--transfers', '4', '--stats', '0', '--ignore-case')
        # Ex.: "07:00,1M 23:00,off" = ate 1 MB/s das 07h as 23h, livre no resto (protege a internet do posto).
        if ($cfg.LimiteBanda) { $parametros += @('--bwlimit', $cfg.LimiteBanda) }
        # Regras na ordem: primeiro o que fica de fora (Excluir), depois o que entra (Filtro; vazio = tudo).
        $incluir = @($p.Filtro | Where-Object { $_ })
        foreach ($x in @($p.Excluir | Where-Object { $_ })) { $parametros += @('--filter', "- $x") }
        foreach ($f in $incluir) { $parametros += @('--filter', "+ $f") }
        if ($incluir) { $parametros += @('--filter', '- **') }
        if ($Modo -eq 'Rapido') { $parametros += @('--max-age', '48h', '--no-traverse') }
        Escrever "== $Modo $($p.Nome): $($p.Caminho) -> $destino"
        & $rclone @parametros
        if ($LASTEXITCODE -ne 0) { $falhas += "$($p.Nome) (codigo $LASTEXITCODE)" }
    }
    if ($falhas) { Escrever "FALHA: $($falhas -join ', ')"; exit 1 }
    Escrever "== $Modo concluido sem erros"
    Avisar "Posto $($cfg.Posto), modo $Modo ok"
}
finally {
    $trava.ReleaseMutex()
    Get-ChildItem $logs -Filter *.log | Where-Object LastWriteTime -lt (Get-Date).AddDays(-60) | Remove-Item -ErrorAction SilentlyContinue
}
