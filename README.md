# Backup dos postos para o OneDrive

Copia a pasta do sistema TACGas3 (XMLs de NFC-e/NF-e, configurações e programas) de cada posto
para uma pasta do OneDrive, usando o [rclone](https://rclone.org). Arquivo apagado no posto
**continua no OneDrive**, e arquivo alterado tem a versão anterior guardada em `_versoes/<data-hora>/`.
A única coisa que o backup apaga no destino são essas versões anteriores, depois de 30 dias
(`VersoesDias`).

Um vigia externo, o [healthchecks.io](https://healthchecks.io), manda alerta no Telegram se um
posto ficar mais de 2 horas sem backup bem-sucedido: máquina desligada, sem internet, tarefa parada
ou erro repetido.

## Instalar ou atualizar num posto

Abra o **PowerShell como administrador** no posto e cole a linha abaixo, trocando `acesso` pelo
posto (`acesso`, `itirapua`, `janjao` ou `ppp`):

```powershell
[Net.ServicePointManager]::SecurityProtocol='Tls12'; $d="$env:TEMP\backup-postos-mr"; iwr https://github.com/jpfalcuci/backup-postos-mr/archive/refs/heads/producao.zip -OutFile "$d.zip" -UseBasicParsing; Expand-Archive "$d.zip" $d -Force; powershell -ExecutionPolicy Bypass -File "$d\backup-postos-mr-producao\instalar.ps1" -Posto acesso
```

Na primeira vez, o instalador:

1. pergunta o **endereço de ping do healthchecks** do posto (`https://hc-ping.com/...`);
2. se o posto não tem `TacON.ini`, pergunta usuário e senha do banco Firebird (ficam em
   `C:\BackupPostos\banco.ini`);
3. baixa o rclone e confere o hash do arquivo;
4. abre o navegador para entrar na **conta do OneDrive do backup** (se o navegador estiver logado
   em outra conta, cole o link numa janela anônima);
5. cria as tarefas agendadas, que rodam como SYSTEM mesmo sem ninguém logado.

Depois disso o posto **se atualiza sozinho**, uma vez por dia (veja abaixo). Rodar a mesma linha de
novo também atualiza, mantendo o login, o endereço do healthchecks e a senha do banco. Tudo fica em
`C:\BackupPostos`, pasta que só administradores abrem.

## Atualização automática

A tarefa `Backup Postos - Atualizar` (06:00, ou assim que a máquina ligar) compara a versão
instalada com o ramo **`producao`** deste repositório. Se houver versão nova, baixa, confere a
sintaxe dos scripts e a configuração do posto, espera o backup em andamento terminar e reinstala sem
perguntar nada. Se algo falhar, a versão atual continua rodando e a falha aparece no relatório.

Só chega aos postos o que estiver em `producao`. O trabalho é feito e testado em `main`; para
publicar:

```bash
git push origin main:producao
```

O relatório diário mostra a versão (commit) que cada posto está rodando.

## Como funciona

| Tarefa | Quando | O que faz |
|---|---|---|
| Backup Postos - Rapido | a cada 15 min | envia o que mudou nas últimas 48 h |
| Backup Postos - Completo | 1x por dia (`HoraCompleto`) | compara tudo, envia o que faltar, faz o backup do banco e grava o relatório |
| Backup Postos - Atualizar | 1x por dia (`HoraAtualizacao`, padrão 06:00) | instala a versão nova do ramo `producao`, se houver |

- Se a máquina estava desligada na hora do completo, ele roda assim que ela ligar.
- Arquivo antigo colocado na pasta (cópia preserva a data) só sobe no completo.
- Ficam de fora da cópia de arquivos o banco Firebird (`Dados`, `*.fdb`, `*.fbk`), que não pode ser
  copiado em uso, e os `LOG`, que mudam o tempo todo.
- O banco tem backup próprio no completo: o `GBAK` do sistema gera uma cópia consistente com o
  sistema aberto, que é compactada e enviada para `<PastaRemota>/banco/TG3_<data>.zip`. Ficam os
  últimos 7 dias (`Banco.Dias`). Usuário e senha são lidos do `TacON.ini` do próprio posto, ou do
  `C:\BackupPostos\banco.ini` criado na instalação; nenhuma senha fica neste repositório.
- `LimiteBanda` segura o envio durante o expediente para não tomar a internet do posto.

Se o último backup do banco bem-sucedido tiver mais de 30 horas, o rápido passa a avisar **falha**
ao healthchecks (o alerta chega mesmo com os arquivos em dia) até o banco voltar a sair.

Cada completo grava um relatório em `<PastaRemota>/_status/ultimo.txt` no OneDrive: o que ficou
de fora (conferência arquivo a arquivo), erros recentes, espaço em disco e resultado das tarefas.
Dá para acompanhar o posto sem acesso remoto.

Para rodar o completo na hora: `Start-ScheduledTask 'Backup Postos - Completo'`.
Logs: `C:\BackupPostos\logs`.

## Configuração de cada posto

Fica em [`postos/`](postos). Os campos:

| Campo | Significado |
|---|---|
| `PastaRemota` | destino dentro do OneDrive da conta de backup |
| `HoraCompleto` | horário do completo diário (máquina precisa estar ligada) |
| `LimiteBanda` | formato do `--bwlimit` do rclone, ex. `06:00,512k 23:00,off` |
| `VersoesDias` | dias que as versões anteriores ficam em `_versoes` (padrão 30) |
| `Banco` | backup do Firebird: `Arquivo` (.FDB), `Gbak`, `Credenciais` (ini com `User`/`Pass` em base64) e `Dias` |
| `Pastas[].Caminho` | pasta local copiada |
| `Pastas[].Excluir` | padrões que não vão (`Dados/**`, `*.fdb`) |
| `Pastas[].Filtro` | se preenchido, só esses padrões vão (vazio = tudo) |
| `Pastas[].Rapido` | se a pasta entra também no envio a cada 15 min |

O endereço do healthchecks **não** fica neste repositório: é informado na instalação.

## Arquivar cópias antigas (uso único)

`arquivar-antigos.ps1` envia para `<PastaRemota>/arquivo-antigo/` as cópias antigas do banco (`.fdb`, `.fbk`, `.gdb`, menos o banco em uso e os alterados nos últimos 30 dias) que estão em `C:\bkp` e na pasta do banco, e os XMLs que só existem em `C:\bkp`. Os bancos vão compactados, um por vez. Depois de tudo conferido na nuvem, `-Apagar` libera o disco, com confirmação.

```powershell
powershell -ExecutionPolicy Bypass -File "$env:TEMP\backup-postos-mr\backup-postos-mr-producao\arquivar-antigos.ps1" -Listar
```

Sem `-Listar`, envia (pode interromper e rodar de novo). Com `-Apagar`, apaga no posto o que já estiver confirmado na nuvem.

## Desinstalar

```powershell
powershell -ExecutionPolicy Bypass -File "$env:TEMP\backup-postos-mr\backup-postos-mr-producao\desinstalar.ps1" -ApagarPasta
```

Remove as tarefas e `C:\BackupPostos`. Nada é apagado no OneDrive.
