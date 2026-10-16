# Atualizacao automatica do posto (tarefa "Backup Postos - Atualizar", uma vez por dia).
# Compara a versao instalada com o ramo 'producao' do GitHub; se houver versao nova, baixa, confere a
# sintaxe dos scripts e a configuracao do posto, espera o backup em andamento terminar e reinstala sem
# perguntar nada (login do OneDrive, healthchecks e senha do banco ficam como estao).
# So chega aos postos o que for publicado em 'producao' (git push origin main:producao).
param([string]$Destino = $PSScriptRoot)
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$Repo = 'jpfalcuci/backup-postos-mr'
$Ramo = 'producao'
$logs = Join-Path $Destino 'logs'
New-Item -ItemType Directory -Force $logs | Out-Null
$log = Join-Path $logs ('{0:yyyy-MM-dd}-atualizacao.log' -f (Get-Date))
function Escrever($texto) { Add-Content -Path $log -Value ('{0:yyyy/MM/dd HH:mm:ss} {1}' -f (Get-Date), $texto) -Encoding UTF8 }
$arquivoVersao = Join-Path $Destino 'versao.txt'
$tmp = $null
try {
    $sha = (Invoke-RestMethod "https://api.github.com/repos/$Repo/commits/$Ramo" -Headers @{ 'User-Agent' = 'backup-postos-mr' } -TimeoutSec 60).sha
    $atual = if (Test-Path $arquivoVersao) { (Get-Content $arquivoVersao -Raw).Trim() } else { '' }
    if ($sha -eq $atual) { Escrever "Sem atualizacao (versao $($sha.Substring(0, 7)))."; exit 0 }

    $cfg = Get-Content (Join-Path $Destino 'config.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $tmp = Join-Path $env:TEMP "backup-postos-mr-$($sha.Substring(0, 7))"
    Remove-Item $tmp, "$tmp.zip" -Recurse -Force -ErrorAction SilentlyContinue
    Invoke-WebRequest "https://github.com/$Repo/archive/$sha.zip" -OutFile "$tmp.zip" -UseBasicParsing
    Expand-Archive "$tmp.zip" $tmp -Force
    $pacote = Join-Path $tmp "backup-postos-mr-$sha"

    # Confere antes de trocar: scripts sem erro de sintaxe e configuracao do posto legivel.
    foreach ($script in 'backup.ps1', 'instalar.ps1', 'atualizar.ps1') {
        $erros = $null
        [void][Management.Automation.Language.Parser]::ParseFile((Join-Path $pacote $script), [ref]$null, [ref]$erros)
        if ($erros) { throw "$script com erro de sintaxe: $($erros[0].Message)" }
    }
    Get-Content (Join-Path $pacote "postos\$($cfg.Posto).json") -Raw -Encoding UTF8 | ConvertFrom-Json | Out-Null

    # Mesma trava do backup.ps1: nao troca arquivos com backup rodando.
    $trava = New-Object System.Threading.Mutex($false, 'Global\BackupPostos')
    try { $peguei = $trava.WaitOne([TimeSpan]::FromMinutes(60)) }
    catch [System.Threading.AbandonedMutexException] { $peguei = $true }
    if (-not $peguei) { throw 'backup em andamento ha mais de 60 min; nova tentativa na proxima rodada' }
    try {
        # No PowerShell 5.1, stderr de programa com ErrorActionPreference=Stop vira excecao: o codigo de saida decide.
        $ErrorActionPreference = 'Continue'
        $saida = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pacote 'instalar.ps1') -Posto $cfg.Posto -Destino $Destino -Atualizacao 2>&1
        $codigo = $LASTEXITCODE
        $ErrorActionPreference = 'Stop'
    }
    finally { $trava.ReleaseMutex() }
    $saida | ForEach-Object { Escrever "  $_" }
    if ($codigo -ne 0) { throw "instalar.ps1 terminou com codigo $codigo" }
    Set-Content $arquivoVersao $sha -Encoding ASCII
    Escrever "Atualizado de '$atual' para $sha."
}
catch { Escrever "FALHA na atualizacao: $($_.Exception.Message)"; exit 1 }
finally { if ($tmp) { Remove-Item $tmp, "$tmp.zip" -Recurse -Force -ErrorAction SilentlyContinue } }
