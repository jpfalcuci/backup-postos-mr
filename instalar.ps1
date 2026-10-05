# Instala (ou atualiza) o backup de um posto: copia os arquivos para $Destino, conecta a conta do
# OneDrive e cria duas tarefas agendadas (rodam como SYSTEM, mesmo sem ninguem logado):
#   "Backup Postos - Rapido"   a cada 15 minutos
#   "Backup Postos - Completo" todo dia na HoraCompleto da configuracao (padrao 02:00; se a maquina
#                              estava desligada nessa hora, roda assim que ligar)
# Uso, em PowerShell como administrador:
#   powershell -ExecutionPolicy Bypass -File .\instalar.ps1 -Posto acesso      (usa postos\acesso.json)
#   powershell -ExecutionPolicy Bypass -File .\instalar.ps1 -Config C:\x.json  (configuracao avulsa)
# Rodar de novo atualiza scripts, configuracao e tarefas, mantendo o login e o endereco do healthchecks.
#Requires -RunAsAdministrator
param(
    [string]$Posto,
    [string]$Config,
    [string]$Healthcheck,
    [string]$Destino = 'C:\BackupPostos'
)
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
# Versao do rclone usada e testada; o hash vem de https://downloads.rclone.org/v1.75.1/SHA256SUMS
$RcloneVersao = 'v1.75.1'
$RcloneSha256 = '200eb602c126d82aa38b51e0f6b9ae837473ff99b51278d3f6f837574c494d6e'

if (-not $Config) {
    if (-not $Posto) { throw 'Informe -Posto (acesso, itirapua, janjao, ppp) ou -Config.' }
    $Config = Join-Path $PSScriptRoot "postos\$Posto.json"
}
$cfg = Get-Content $Config -Raw -Encoding UTF8 | ConvertFrom-Json
foreach ($p in $cfg.Pastas) {
    if (-not (Test-Path -LiteralPath $p.Caminho)) { throw "Pasta de origem nao existe: $($p.Caminho)" }
}

# Endereco do healthchecks: o informado agora, senao o da instalacao anterior, senao pergunta.
$instalado = Join-Path $Destino 'config.json'
if (-not $Healthcheck -and (Test-Path $instalado)) {
    $Healthcheck = (Get-Content $instalado -Raw -Encoding UTF8 | ConvertFrom-Json).HealthcheckUrl
}
if (-not $Healthcheck) { $Healthcheck = $cfg.HealthcheckUrl }
if (-not $Healthcheck) { $Healthcheck = Read-Host 'Endereco de ping do healthchecks deste posto (Enter para nenhum)' }
$cfg | Add-Member HealthcheckUrl $Healthcheck.Trim() -Force

Write-Host "Instalando $($cfg.Posto) em $Destino ..."
New-Item -ItemType Directory -Force $Destino | Out-Null
# A pasta guarda o acesso ao OneDrive: so SYSTEM e administradores podem ler.
& icacls $Destino /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Falha ao restringir permissoes da pasta.' }
Copy-Item (Join-Path $PSScriptRoot 'backup.ps1') $Destino -Force
$cfg | ConvertTo-Json -Depth 5 | Set-Content $instalado -Encoding UTF8

$rclone = Join-Path $Destino 'rclone.exe'
$versaoAtual = if (Test-Path $rclone) { (& $rclone version | Select-Object -First 1) -replace '^rclone ', '' }
if ($versaoAtual -ne $RcloneVersao) {
    Write-Host "Baixando rclone $RcloneVersao ..."
    $zip = Join-Path $env:TEMP "rclone-$RcloneVersao.zip"
    Invoke-WebRequest "https://downloads.rclone.org/$RcloneVersao/rclone-$RcloneVersao-windows-amd64.zip" -OutFile $zip -UseBasicParsing
    if ((Get-FileHash $zip -Algorithm SHA256).Hash -ne $RcloneSha256) { Remove-Item $zip; throw 'Download do rclone com hash diferente do esperado.' }
    $pasta = Join-Path $env:TEMP "rclone-$RcloneVersao"
    Expand-Archive $zip $pasta -Force
    Copy-Item (Join-Path $pasta "rclone-$RcloneVersao-windows-amd64\rclone.exe") $rclone -Force
    Remove-Item $zip, $pasta -Recurse -Force
}

$conf = Join-Path $Destino 'rclone.conf'
if (Test-Path $conf) {
    Write-Host 'Conta do OneDrive ja conectada; mantendo rclone.conf existente.'
} else {
    Write-Host ''
    Write-Host 'O navegador vai abrir para entrar na conta do OneDrive DO BACKUP.'
    Write-Host 'Se ele ja estiver logado em outra conta, cole o link numa janela anonima.'
    $saida = (& $rclone authorize onedrive | Out-String)
    if ($saida -notmatch '(?s)--->\s*(\{.*\})\s*<---') { throw "Login nao concluido:`n$saida" }
    $token = $Matches[1]
    # O rclone escolhe sozinho o drive errado (o do Cofre Pessoal); fixamos o drive da propria conta.
    $acesso = ($token | ConvertFrom-Json).access_token
    $drive = Invoke-RestMethod 'https://graph.microsoft.com/v1.0/me/drive?$select=id,owner' -Headers @{ Authorization = "Bearer $acesso" }
    Write-Host "Conectado como: $($drive.owner.user.email)"
    Set-Content $conf -Encoding ASCII -Value @('[onedrive]', 'type = onedrive', "token = $token", "drive_id = $($drive.id)", 'drive_type = personal')
}
$horaCompleto = if ($cfg.HoraCompleto) { $cfg.HoraCompleto } else { '02:00' }
$destinoRemoto = "$($cfg.Remoto):$($cfg.PastaRemota)"
& $rclone mkdir $destinoRemoto --config $conf
if ($LASTEXITCODE -ne 0) { throw "Sem acesso a $destinoRemoto. Confira a conta e a PastaRemota." }
Write-Host "Destino no OneDrive acessivel: $destinoRemoto"

$quem = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
function Acao($modo) {
    New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$Destino\backup.ps1`" -Modo $modo"
}
$base = @{ MultipleInstances = 'IgnoreNew'; StartWhenAvailable = $true; AllowStartIfOnBatteries = $true; DontStopIfGoingOnBatteries = $true }

$rapido = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 15)
Register-ScheduledTask -TaskName 'Backup Postos - Rapido' -Force -Principal $quem -Action (Acao 'Rapido') -Trigger $rapido `
    -Settings (New-ScheduledTaskSettingsSet @base -ExecutionTimeLimit (New-TimeSpan -Hours 2)) | Out-Null
Register-ScheduledTask -TaskName 'Backup Postos - Completo' -Force -Principal $quem -Action (Acao 'Completo') `
    -Trigger (New-ScheduledTaskTrigger -Daily -At $horaCompleto) `
    -Settings (New-ScheduledTaskSettingsSet @base -ExecutionTimeLimit (New-TimeSpan -Hours 12)) | Out-Null

Write-Host ''
Write-Host "Instalado. Tarefas criadas: 'Backup Postos - Rapido' (15 min) e 'Backup Postos - Completo' ($horaCompleto)."
Write-Host "Logs em $Destino\logs. Para rodar o completo agora: Start-ScheduledTask 'Backup Postos - Completo'"
