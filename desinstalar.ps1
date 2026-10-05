# Remove as tarefas agendadas do backup. Nao apaga nada no OneDrive.
#Requires -RunAsAdministrator
param([string]$Destino = 'C:\BackupPostos', [switch]$ApagarPasta)
$ErrorActionPreference = 'Stop'
foreach ($t in 'Backup Postos - Rapido', 'Backup Postos - Completo') {
    if (Get-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue) {
        Stop-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $t -Confirm:$false
        Write-Host "Tarefa removida: $t"
    }
}
if ($ApagarPasta -and (Test-Path $Destino)) { Remove-Item $Destino -Recurse -Force; Write-Host "Pasta removida: $Destino" }
else { Write-Host "Pasta preservada (logs e acesso ao OneDrive): $Destino" }
