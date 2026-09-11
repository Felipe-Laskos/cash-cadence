# CashCadence

Dashboard de finanças pessoais em Elixir, Phoenix 1.8 e LiveView, feito para substituir uma planilha de
controle mensal. A entrada de dados vem da importação de extratos e faturas exportados do banco
(OFX, CSV e PDF), com revisão em uma caixa de entrada antes de virar lançamento; despesas fixas, competência
mensal e relatórios são calculados a partir do livro de lançamentos.

Projeto pessoal, single-user, pensado para rodar localmente.

## Stack

- Elixir 1.18 / OTP 27, Phoenix 1.8, LiveView 1.2, Ecto + Postgres 17
- Tailwind 4 e daisyUI (tema escuro por padrão, claro opcional)
- Extração de PDF e OCR com ferramentas locais (poppler, Tesseract, ocrmypdf) chamadas pelo app

## Rodando

Pré-requisitos: Elixir 1.18 com OTP 27 e Docker.

```bash
docker compose up -d --wait   # Postgres em localhost:5433
mix setup                     # dependências, banco, migrações, assets
mix phx.server                # http://localhost:4000
```

Antes de commitar:

```bash
mix precommit
```

No WSL, instale `inotify-tools` para o live reload funcionar (`sudo apt install inotify-tools`).

Para carregar a planilha original (arquivos fora do repositório, em `priv/repo/seeds/private/`):

```bash
mix cash.import_sheet
```

O primeiro acesso cria a única conta em `/users/register`; depois disso o cadastro fecha.
