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
    # Banco Firebird: no completo, GBAK (copia consistente com o sistema em uso), compacta e envia para
    # <PastaRemota>/banco/<nome>_<data>.zip, guardando Banco.Dias dias (padrao 7). Usuario e senha vem do
    # TacON.ini do proprio posto (base64), nunca da configuracao nem do repositorio.
    $bancoResumo = $null
    if ($Modo -eq 'Completo' -and $cfg.Banco) {
        $b = $cfg.Banco
        $pastaBanco = Join-Path $Pasta 'banco'
        try {
            $ini = Get-Content $b.Credenciais -Encoding UTF8
            function Ler64($chave) { [Text.Encoding]::ASCII.GetString([Convert]::FromBase64String((($ini | Select-String "^$chave=" | Select-Object -First 1).Line -replace "^$chave=", '').Trim())) }
            # O gbak le usuario e senha destas variaveis de ambiente; assim nao aparecem na linha de comando.
            foreach ($par in @(@('ISC_USER', 'User'), @('ISC_PASSWORD', 'Pass'))) { [Environment]::SetEnvironmentVariable($par[0], (Ler64 $par[1])) }
            $nomeBase = [IO.Path]::GetFileNameWithoutExtension($b.Arquivo)
            $tamanhoBanco = (Get-Item -LiteralPath $b.Arquivo).Length
            $livre = (Get-PSDrive ([IO.Path]::GetPathRoot($Pasta).Substring(0, 1))).Free
            if ($livre -lt $tamanhoBanco * 1.5) { throw ('pouco espaco em disco: {0:N1} GB livres para um banco de {1:N1} GB' -f ($livre/1GB), ($tamanhoBanco/1GB)) }
            Remove-Item $pastaBanco -Recurse -Force -ErrorAction SilentlyContinue
            New-Item -ItemType Directory $pastaBanco | Out-Null
            $fbk = Join-Path $pastaBanco "$nomeBase.fbk"
            $zip = Join-Path $pastaBanco ('{0}_{1:yyyy-MM-dd}.zip' -f $nomeBase, (Get-Date))
            Escrever "== Banco: GBAK de $($b.Arquivo)"
            $inicio = Get-Date
            # No PowerShell 5.1, stderr de programa com ErrorActionPreference=Stop vira excecao: o codigo de saida decide.
            $ErrorActionPreference = 'Continue'
            $saidaGbak = & $b.Gbak -b -g "127.0.0.1:$($b.Arquivo)" $fbk 2>&1
            $codigoGbak = $LASTEXITCODE
            $ErrorActionPreference = 'Stop'
            if ($codigoGbak -ne 0 -or -not (Test-Path $fbk) -or (Get-Item $fbk).Length -eq 0) {
                throw "GBAK falhou (codigo $codigoGbak): $(($saidaGbak | Select-Object -Last 3) -join ' | ')"
            }
            $minGbak = ((Get-Date) - $inicio).TotalMinutes
            Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
            $arquivoZip = [IO.Compression.ZipFile]::Open($zip, 'Create')
            try { [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($arquivoZip, $fbk, "$nomeBase.fbk", 'Optimal') }
            finally { $arquivoZip.Dispose() }
            $remotoBanco = "$($cfg.Remoto):$($cfg.PastaRemota)/banco"
            $conf = Join-Path $Pasta 'rclone.conf'
            $envio = @('copyto', $zip, "$remotoBanco/$(Split-Path $zip -Leaf)", '--config', $conf, '--log-file', $log, '--log-level', 'INFO', '--retries', '3')
            if ($cfg.LimiteBanda) { $envio += @('--bwlimit', $cfg.LimiteBanda) }
            & $rclone @envio
            if ($LASTEXITCODE -ne 0) { throw "envio do banco falhou (codigo $LASTEXITCODE)" }
            $bancoResumo = 'ok: GBAK {0:N1} min, {1:N0} MB -> zip {2:N0} MB' -f $minGbak, ((Get-Item $fbk).Length/1MB), ((Get-Item $zip).Length/1MB)
            Escrever "== Banco $bancoResumo"
            # Guarda os ultimos Banco.Dias dias, pela data no nome do arquivo.
            $diasBanco = if ($b.Dias) { [int]$b.Dias } else { 7 }
            foreach ($antigo in (& $rclone lsf $remotoBanco --files-only --config $conf --log-file $log --log-level ERROR)) {
                if ($antigo -notmatch '_(\d{4}-\d{2}-\d{2})\.zip$') { continue }
                if ([datetime]::ParseExact($Matches[1], 'yyyy-MM-dd', $null) -lt (Get-Date).Date.AddDays(-$diasBanco)) {
                    & $rclone deletefile "$remotoBanco/$antigo" --config $conf --log-file $log --log-level INFO
                    Escrever "Backup do banco $antigo apagado (mais de $diasBanco dias)."
                }
            }
        }
        catch { $bancoResumo = "FALHOU: $($_.Exception.Message)"; $falhas += 'banco'; Escrever "FALHA banco: $($_.Exception.Message)" }
        finally {
            Remove-Item Env:\ISC_USER, Env:\ISC_PASSWORD -ErrorAction SilentlyContinue
            Remove-Item $pastaBanco -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    # Unica exclusao no destino: no completo, apaga pastas de _versoes mais antigas que VersoesDias
    # (padrao 30). A idade vem do nome da pasta (data do envio), nunca da data dos arquivos.
    if ($Modo -eq 'Completo') {
        $dias = if ($cfg.VersoesDias) { [int]$cfg.VersoesDias } else { 30 }
        $versoes = "$($cfg.Remoto):$($cfg.PastaRemota)/_versoes"
        $conf = Join-Path $Pasta 'rclone.conf'
        foreach ($pastaVersao in (& $rclone lsf $versoes --dirs-only --config $conf --log-file $log --log-level ERROR)) {
            $nome = $pastaVersao.TrimEnd('/')
            if ($nome -notmatch '^\d{4}-\d{2}-\d{2}_\d{6}$') { continue }
            $quando = [datetime]::ParseExact($nome, 'yyyy-MM-dd_HHmmss', $null)
            if ($quando -lt (Get-Date).AddDays(-$dias)) {
                & $rclone purge "$versoes/$nome" --config $conf --log-file $log --log-level INFO
                Escrever "Versoes de $nome apagadas (mais de $dias dias)."
            }
        }
    }
    # Relatorio do completo em <PastaRemota>/_status/ultimo.txt, para conferir o posto sem acesso remoto:
    # o que ficou de fora do OneDrive (rclone check), erros do log, disco e resultado das tarefas.
    if ($Modo -eq 'Completo') {
        try {
            $conf = Join-Path $Pasta 'rclone.conf'
            $rel = New-Object System.Collections.Generic.List[string]
            $rel.Add("Posto $($cfg.Posto) - relatorio do completo de $(Get-Date -Format 'dd/MM/yyyy HH:mm')")
            $versao = Get-Content (Join-Path $Pasta 'versao.txt') -ErrorAction SilentlyContinue | Select-Object -First 1
            $ultimaAtualizacao = Get-ChildItem $logs -Filter '*atualizacao.log' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime |
                Select-Object -Last 1 | Get-Content -Encoding UTF8 | Select-Object -Last 1
            $rel.Add('Versao: ' + $(if ($versao) { $versao.Substring(0, 7) } else { 'instalada a mao' }) + $(if ($ultimaAtualizacao) { " | ultima atualizacao: $ultimaAtualizacao" } else { '' }))
            $rel.Add('Envio: ' + $(if ($falhas) { 'FALHOU em ' + ($falhas -join ', ') } else { 'ok' }))
            if ($bancoResumo) { $rel.Add("Banco: $bancoResumo") }
            $disco = Get-PSDrive C
            $rel.Add(('Disco C: {0:N1} GB livres de {1:N1} GB' -f ($disco.Free/1GB), (($disco.Free + $disco.Used)/1GB)))
            foreach ($t in Get-ScheduledTask -TaskName 'Backup Postos*' -ErrorAction SilentlyContinue) {
                $info = $t | Get-ScheduledTaskInfo
                $rel.Add(('Tarefa {0}: ultima {1:dd/MM HH:mm}, resultado {2}' -f $t.TaskName, $info.LastRunTime, $info.LastTaskResult))
            }
            foreach ($p in $cfg.Pastas) {
                $combinado = Join-Path $env:TEMP 'backup-postos-check.txt'
                $chk = @('check', $p.Caminho, "$($cfg.Remoto):$($cfg.PastaRemota)/$($p.Nome)", '--one-way', '--size-only',
                    '--ignore-case', '--combined', $combinado, '--config', $conf, '--log-file', $log, '--log-level', 'ERROR')
                foreach ($x in @($p.Excluir | Where-Object { $_ })) { $chk += @('--filter', "- $x") }
                $incluir = @($p.Filtro | Where-Object { $_ })
                foreach ($f in $incluir) { $chk += @('--filter', "+ $f") }
                if ($incluir) { $chk += @('--filter', '- **') }
                & $rclone @chk | Out-Null
                $linhas = @(Get-Content $combinado -Encoding UTF8 -ErrorAction SilentlyContinue)
                $problemas = @($linhas | Where-Object { $_ -notmatch '^= ' })
                $rel.Add('')
                $rel.Add("Conferencia $($p.Nome): $(@($linhas | Where-Object { $_ -match '^= ' }).Count) iguais, $($problemas.Count) faltando ou diferentes no OneDrive (+ falta, * diferente)")
                foreach ($l in ($problemas | Select-Object -First 50)) {
                    $arq = Get-Item -LiteralPath (Join-Path $p.Caminho $l.Substring(2)) -ErrorAction SilentlyContinue
                    $rel.Add(('  {0} {1:dd/MM/yyyy HH:mm} {2,10:N0} bytes  {3}' -f $l.Substring(0, 1), $arq.LastWriteTime, $arq.Length, $l.Substring(2)))
                }
                Remove-Item $combinado -ErrorAction SilentlyContinue
            }
            $rel.Add('')
            $rel.Add('Erros nos logs das ultimas 24 h (ate 30):')
            Get-ChildItem $logs -Filter *.log | Where-Object LastWriteTime -gt (Get-Date).AddDays(-1) |
                Get-Content -Encoding UTF8 | Select-String 'Failed to copy|FALHA|Relatorio nao' |
                Where-Object { $_.Line -match '^(\d{4}/\d{2}/\d{2} \d{2}:\d{2}:\d{2})' -and [datetime]::ParseExact($Matches[1], 'yyyy/MM/dd HH:mm:ss', $null) -gt (Get-Date).AddDays(-1) } |
                Select-Object -Last 30 | ForEach-Object { $rel.Add('  ' + $_.Line) }
            $arquivoRel = Join-Path $Pasta 'ultimo-relatorio.txt'
            $rel | Set-Content $arquivoRel -Encoding UTF8
            & $rclone copyto $arquivoRel "$($cfg.Remoto):$($cfg.PastaRemota)/_status/ultimo.txt" --config $conf --log-file $log --log-level ERROR
        }
        catch { Escrever "Relatorio nao gerado: $($_.Exception.Message)" }
    }
    if ($falhas) { Escrever "FALHA: $($falhas -join ', ')"; exit 1 }
    Escrever "== $Modo concluido sem erros"
    Avisar "Posto $($cfg.Posto), modo $Modo ok"
}
finally {
    $trava.ReleaseMutex()
    Get-ChildItem $logs -Filter *.log | Where-Object LastWriteTime -lt (Get-Date).AddDays(-60) | Remove-Item -ErrorAction SilentlyContinue
}
