# Arquiva na nuvem, uma unica vez, o que ocupa o disco do posto sem fazer parte do sistema em uso:
#   - copias antigas do banco (.fdb, .fbk, .gdb) nas Origens, menos o banco em uso e menos qualquer
#     banco alterado nos ultimos 30 dias (pode estar em uso por algo que nao conhecemos);
#   - XMLs que so existem nas Origens fora da pasta do sistema (ex.: C:\bkp): eles nao estao mais na
#     pasta do sistema, entao tambem nao estao no backup diario.
# Destino: <PastaRemota>/arquivo-antigo/<caminho original>. Bancos vao compactados, um por vez (o zip
# temporario e apagado logo apos o envio); XMLs vao como estao.
#
# Uso, em PowerShell como administrador (pasta do pacote baixado do GitHub):
#   powershell -ExecutionPolicy Bypass -File .\arquivar-antigos.ps1 -Listar   so mostra o que encontrou
#   powershell -ExecutionPolicy Bypass -File .\arquivar-antigos.ps1           envia (pode interromper e
#                                                                              rodar de novo: continua)
#   powershell -ExecutionPolicy Bypass -File .\arquivar-antigos.ps1 -Apagar   confere na nuvem e, com
#                                                                              confirmacao, apaga no posto
# -Apagar remove as Origens fora da pasta do sistema inteiras (ex.: C:\bkp) e, dentro da pasta do
# sistema, so os bancos antigos ja arquivados. So apaga se tudo estiver confirmado na nuvem.
param(
    [switch]$Listar,
    [switch]$Apagar,
    [string[]]$Origens,
    [string]$Destino = 'C:\BackupPostos'
)
$ErrorActionPreference = 'Stop'
$cfg = Get-Content (Join-Path $Destino 'config.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$rclone = Join-Path $Destino 'rclone.exe'
$conf = Join-Path $Destino 'rclone.conf'
$remoto = "$($cfg.Remoto):$($cfg.PastaRemota)/arquivo-antigo"
New-Item -ItemType Directory -Force (Join-Path $Destino 'logs') | Out-Null
$log = Join-Path $Destino 'logs\arquivo-antigo.log'
function Escrever($texto) {
    $linha = '{0:yyyy/MM/dd HH:mm:ss} {1}' -f (Get-Date), $texto
    Write-Host $linha
    Add-Content -Path $log -Value $linha -Encoding UTF8
}
function NomeRemoto($caminho) { $caminho.Substring([IO.Path]::GetPathRoot($caminho).Length) -replace '\\', '/' }
function Dentro($caminho, $pasta) { $caminho.StartsWith($pasta.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase) }

$sistema = [IO.Path]::GetFullPath($cfg.Pastas[0].Caminho)
$vivo = if ($cfg.Banco) { [IO.Path]::GetFullPath($cfg.Banco.Arquivo) } else { $null }
if (-not $Origens) { $Origens = @('C:\bkp'); if ($vivo) { $Origens += Split-Path $vivo } }
$Origens = @($Origens -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | ForEach-Object { [IO.Path]::GetFullPath($_).TrimEnd('\') })
if (-not $Origens) { Escrever 'Nenhuma das origens existe neste posto. Nada a fazer.'; exit 0 }

# Bancos antigos
$recente = (Get-Date).AddDays(-30)
$todos = @(foreach ($o in $Origens) { Get-ChildItem -LiteralPath $o -Recurse -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in '.fdb', '.fbk', '.gdb' } })
$bancos = @($todos | Where-Object { $_.FullName -ine $vivo -and $_.LastWriteTime -lt $recente })
$ignorados = @($todos | Where-Object { $_.FullName -ieq $vivo -or $_.LastWriteTime -ge $recente })

# XMLs que so existem fora da pasta do sistema (comparacao pelo nome do arquivo)
$foraDoSistema = @($Origens | Where-Object { -not (Dentro $_ $sistema) -and $_ -ine $sistema })
$orfaos = @()
if ($foraDoSistema) {
    Write-Host 'Comparando XMLs com a pasta do sistema (pode levar alguns minutos)...'
    $noSistema = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    Get-ChildItem -LiteralPath $sistema -Recurse -File -Filter *.xml -ErrorAction SilentlyContinue | ForEach-Object { [void]$noSistema.Add($_.Name) }
    $orfaos = @(foreach ($o in $foraDoSistema) {
        Get-ChildItem -LiteralPath $o -Recurse -File -Filter *.xml -Force -ErrorAction SilentlyContinue | Where-Object { -not $noSistema.Contains($_.Name) }
    })
}

$gbBancos = ($bancos | Measure-Object Length -Sum).Sum / 1GB
$gbOrfaos = ($orfaos | Measure-Object Length -Sum).Sum / 1GB
if ($Listar) {
    Write-Host ''
    Write-Host "Posto $($cfg.Posto) - origens: $($Origens -join ', ')"
    Write-Host ('Bancos antigos a arquivar: {0} ({1:N1} GB)' -f $bancos.Count, $gbBancos)
    $bancos | Sort-Object LastWriteTime | ForEach-Object { Write-Host ('  {0:dd/MM/yyyy}  {1,6:N2} GB  {2}' -f $_.LastWriteTime, ($_.Length / 1GB), $_.FullName) }
    if ($ignorados) {
        Write-Host 'Bancos que NAO serao tocados (em uso ou alterados nos ultimos 30 dias):'
        $ignorados | ForEach-Object { Write-Host ('  {0:dd/MM/yyyy}  {1,6:N2} GB  {2}' -f $_.LastWriteTime, ($_.Length / 1GB), $_.FullName) }
    }
    Write-Host ('XMLs que so existem fora da pasta do sistema: {0} ({1:N2} GB)' -f $orfaos.Count, $gbOrfaos)
    foreach ($o in $foraDoSistema) {
        $gb = (Get-ChildItem -LiteralPath $o -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum / 1GB
        Write-Host ('Pasta {0}: {1:N1} GB no total (com -Apagar, sai inteira depois de arquivada)' -f $o, $gb)
    }
    exit 0
}

# O que ja esta na nuvem (nome -> tamanho), para pular o que foi enviado e para conferir antes de apagar
function NaNuvem {
    $mapa = @{}
    foreach ($l in (& $rclone lsf -R --files-only --format 'ps' --separator '|' $remoto --config $conf --log-file $log --log-level ERROR)) {
        $p = $l -split '\|'; $mapa[$p[0]] = [long]$p[1]
    }
    $mapa
}

if (-not $Apagar) {
    $ja = NaNuvem
    Escrever ('Inicio: {0} bancos ({1:N1} GB) e {2} XMLs ({3:N2} GB) para {4}' -f $bancos.Count, $gbBancos, $orfaos.Count, $gbOrfaos, $remoto)
    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
    $zip = Join-Path $env:TEMP 'arquivo-antigo.zip'
    $enviados = 0; $pulados = 0; $falhas = 0
    foreach ($b in $bancos) {
        $nome = (NomeRemoto $b.FullName) + '.zip'
        if ($ja.ContainsKey($nome) -and $ja[$nome] -gt 0) { $pulados++; continue }
        $livre = (Get-PSDrive ([IO.Path]::GetPathRoot($env:TEMP).Substring(0, 1))).Free
        if ($livre -lt $b.Length * 0.4 + 1GB) { Escrever "PULADO (pouco espaco para compactar): $($b.FullName)"; $falhas++; continue }
        try {
            Remove-Item $zip -ErrorAction SilentlyContinue
            $arquivo = [IO.Compression.ZipFile]::Open($zip, 'Create')
            try { [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($arquivo, $b.FullName, $b.Name, 'Optimal') }
            finally { $arquivo.Dispose() }
            $envio = @('copyto', $zip, "$remoto/$nome", '--config', $conf, '--log-file', $log, '--log-level', 'INFO', '--retries', '3')
            if ($cfg.LimiteBanda) { $envio += @('--bwlimit', $cfg.LimiteBanda) }
            & $rclone @envio
            if ($LASTEXITCODE -ne 0) { throw "envio falhou (codigo $LASTEXITCODE)" }
            $enviados++
            Escrever ('Enviado {0:N2} GB -> {1:N2} GB: {2}' -f ($b.Length / 1GB), ((Get-Item $zip).Length / 1GB), $b.FullName)
        }
        catch { $falhas++; Escrever "FALHA: $($b.FullName): $($_.Exception.Message)" }
        finally { Remove-Item $zip -ErrorAction SilentlyContinue }
    }
    if ($orfaos) {
        # Lista relativa a raiz do disco; o rclone copy pula o que ja estiver igual na nuvem.
        $lista = Join-Path $env:TEMP 'arquivo-antigo-xml.txt'
        [IO.File]::WriteAllLines($lista, [string[]]@($orfaos | ForEach-Object { NomeRemoto $_.FullName }), (New-Object Text.UTF8Encoding($false)))
        $raiz = [IO.Path]::GetPathRoot($orfaos[0].FullName)
        $copia = @('copy', $raiz, $remoto, '--files-from', $lista, '--config', $conf, '--log-file', $log, '--log-level', 'INFO', '--retries', '3', '--transfers', '4')
        if ($cfg.LimiteBanda) { $copia += @('--bwlimit', $cfg.LimiteBanda) }
        & $rclone @copia
        if ($LASTEXITCODE -ne 0) { $falhas++; Escrever "FALHA no envio dos XMLs (codigo $LASTEXITCODE); rode de novo para continuar." }
        else { Escrever "XMLs enviados: $($orfaos.Count)" }
        Remove-Item $lista -ErrorAction SilentlyContinue
    }
    Escrever "Fim: $enviados bancos enviados, $pulados ja estavam na nuvem, $falhas falhas."
    if ($falhas) { Escrever 'Rode de novo para tentar o que falhou.' } else { Escrever 'Tudo arquivado. Para liberar o disco, rode com -Apagar.' }
    exit ([int]($falhas -gt 0))
}

# -Apagar: confere cada item na nuvem e so entao apaga, com confirmacao.
$ja = NaNuvem
$faltam = @($bancos | Where-Object { $n = (NomeRemoto $_.FullName) + '.zip'; -not ($ja.ContainsKey($n) -and $ja[$n] -gt 0) })
$faltam += @($orfaos | Where-Object { $n = NomeRemoto $_.FullName; -not ($ja.ContainsKey($n) -and $ja[$n] -eq $_.Length) })
if ($faltam) {
    Escrever "Ainda nao estao na nuvem $($faltam.Count) itens (ex.: $($faltam[0].FullName)). Rode sem -Apagar primeiro. Nada foi apagado."
    exit 1
}
$apagarPastas = $foraDoSistema
$apagarBancos = @($bancos | Where-Object { $b = $_; -not ($foraDoSistema | Where-Object { Dentro $b.FullName $_ }) })
$gbPastas = ($apagarPastas | ForEach-Object { (Get-ChildItem -LiteralPath $_ -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum } | Measure-Object -Sum).Sum / 1GB
$gbSoltos = ($apagarBancos | Measure-Object Length -Sum).Sum / 1GB
Write-Host ''
Write-Host 'Tudo confirmado na nuvem. Vai ser apagado NESTE computador:'
$apagarPastas | ForEach-Object { Write-Host "  pasta inteira: $_" }
$apagarBancos | ForEach-Object { Write-Host ('  {0,6:N2} GB  {1}' -f ($_.Length / 1GB), $_.FullName) }
Write-Host ('Total: {0:N1} GB. O banco em uso ({1}) nao e tocado.' -f ($gbPastas + $gbSoltos), $vivo)
if ((Read-Host 'Digite APAGAR para confirmar') -cne 'APAGAR') { Write-Host 'Cancelado. Nada foi apagado.'; exit 0 }
foreach ($b in $apagarBancos) { Remove-Item -LiteralPath $b.FullName -Force; Escrever "Apagado: $($b.FullName)" }
foreach ($p in $apagarPastas) { Remove-Item -LiteralPath $p -Recurse -Force; Escrever "Apagada a pasta: $p" }
$livre = (Get-PSDrive ([IO.Path]::GetPathRoot($vivo).Substring(0, 1))).Free / 1GB
Escrever ('Concluido. Disco agora com {0:N1} GB livres.' -f $livre)
