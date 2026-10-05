# Backup dos postos para o OneDrive

Copia a pasta do sistema TACGas3 (XMLs de NFC-e/NF-e, configurações e programas) de cada posto
para uma pasta do OneDrive, usando o [rclone](https://rclone.org). **Nunca apaga nada no destino**:
arquivo apagado no posto continua no OneDrive, e arquivo alterado tem a versão anterior guardada em
`_versoes/<data-hora>/`.

Um vigia externo, o [healthchecks.io](https://healthchecks.io), manda alerta no Telegram se um
posto ficar mais de 2 horas sem backup bem-sucedido: máquina desligada, sem internet, tarefa parada
ou erro repetido.

## Instalar ou atualizar num posto

Abra o **PowerShell como administrador** no posto e cole a linha abaixo, trocando `acesso` pelo
posto (`acesso`, `itirapua`, `janjao` ou `ppp`):

```powershell
[Net.ServicePointManager]::SecurityProtocol='Tls12'; $d="$env:TEMP\backup-postos-mr"; iwr https://github.com/jpfalcuci/backup-postos-mr/archive/refs/heads/main.zip -OutFile "$d.zip" -UseBasicParsing; Expand-Archive "$d.zip" $d -Force; powershell -ExecutionPolicy Bypass -File "$d\backup-postos-mr-main\instalar.ps1" -Posto acesso
```

Na primeira vez, o instalador:

1. pergunta o **endereço de ping do healthchecks** do posto (`https://hc-ping.com/...`);
2. baixa o rclone e confere o hash do arquivo;
3. abre o navegador para entrar na **conta do OneDrive do backup** (se o navegador estiver logado
   em outra conta, cole o link numa janela anônima);
4. cria as tarefas agendadas, que rodam como SYSTEM mesmo sem ninguém logado.

Rodar a mesma linha de novo **atualiza** scripts, configuração e tarefas, mantendo o login e o
endereço do healthchecks. Tudo fica em `C:\BackupPostos`, pasta que só administradores abrem.

## Como funciona

| Tarefa | Quando | O que faz |
|---|---|---|
| Backup Postos - Rapido | a cada 15 min | envia o que mudou nas últimas 48 h |
| Backup Postos - Completo | 1x por dia (`HoraCompleto`) | compara tudo e envia o que faltar |

- Se a máquina estava desligada na hora do completo, ele roda assim que ela ligar.
- Arquivo antigo colocado na pasta (cópia preserva a data) só sobe no completo.
- Ficam de fora o banco Firebird (`Dados`, `*.fdb`, `*.fbk`), que não pode ser copiado em uso, e os
  `LOG`, que mudam o tempo todo.
- `LimiteBanda` segura o envio durante o expediente para não tomar a internet do posto.

Para rodar o completo na hora: `Start-ScheduledTask 'Backup Postos - Completo'`.
Logs: `C:\BackupPostos\logs`.

## Configuração de cada posto

Fica em [`postos/`](postos). Os campos:

| Campo | Significado |
|---|---|
| `PastaRemota` | destino dentro do OneDrive da conta de backup |
| `HoraCompleto` | horário do completo diário (máquina precisa estar ligada) |
| `LimiteBanda` | formato do `--bwlimit` do rclone, ex. `06:00,512k 23:00,off` |
| `Pastas[].Caminho` | pasta local copiada |
| `Pastas[].Excluir` | padrões que não vão (`Dados/**`, `*.fdb`) |
| `Pastas[].Filtro` | se preenchido, só esses padrões vão (vazio = tudo) |
| `Pastas[].Rapido` | se a pasta entra também no envio a cada 15 min |

O endereço do healthchecks **não** fica neste repositório: é informado na instalação.

## Desinstalar

```powershell
powershell -ExecutionPolicy Bypass -File "$env:TEMP\backup-postos-mr\backup-postos-mr-main\desinstalar.ps1" -ApagarPasta
```

Remove as tarefas e `C:\BackupPostos`. Nada é apagado no OneDrive.
