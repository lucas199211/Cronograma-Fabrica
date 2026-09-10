-- Rode este script inteiro no Supabase Dashboard > SQL Editor > New query > Run.

create table if not exists public.cronograma_state (
  id int primary key,
  data jsonb not null,
  updated_at timestamptz not null default now()
);

alter table public.cronograma_state enable row level security;

drop policy if exists "authenticated can read" on public.cronograma_state;
create policy "authenticated can read" on public.cronograma_state
  for select using (auth.role() = 'authenticated');

drop policy if exists "authenticated can insert" on public.cronograma_state;
create policy "authenticated can insert" on public.cronograma_state
  for insert with check (auth.role() = 'authenticated');

drop policy if exists "authenticated can update" on public.cronograma_state;
create policy "authenticated can update" on public.cronograma_state
  for update using (auth.role() = 'authenticated') with check (auth.role() = 'authenticated');

-- habilita realtime (sincronizar edições entre navegadores ao vivo)
alter publication supabase_realtime add table public.cronograma_state;

-- ============================================================
-- Anexos de orçamento (clipe nas linhas de fornecedor)
-- ============================================================
-- 1) Crie o bucket antes de rodar o resto: Dashboard > Storage > New
--    bucket > nome "anexos" > deixe "Public bucket" DESLIGADO (privado).
-- 2) Com o bucket criado, rode o script abaixo.

drop policy if exists "authenticated can upload anexos" on storage.objects;
create policy "authenticated can upload anexos" on storage.objects
  for insert with check (bucket_id = 'anexos' and auth.role() = 'authenticated');

drop policy if exists "authenticated can read anexos" on storage.objects;
create policy "authenticated can read anexos" on storage.objects
  for select using (bucket_id = 'anexos' and auth.role() = 'authenticated');

drop policy if exists "authenticated can delete anexos" on storage.objects;
create policy "authenticated can delete anexos" on storage.objects
  for delete using (bucket_id = 'anexos' and auth.role() = 'authenticated');

-- ============================================================
-- Backup automatico de hora em hora (independe do app / roda no banco)
-- ============================================================
-- Guarda, uma vez por hora-relogio, o estado de como o cronograma estava
-- ANTES da primeira alteracao daquela hora -- ou seja, sempre sobra uma
-- foto de no maximo 1h atras. Dispara sozinho a cada UPDATE em
-- cronograma_state, direto no Postgres, entao protege ate contra um bug
-- no painel (como o que causou a perda de 21/08) -- nao depende do JS do
-- app rodar certo. (Era 1x/dia antes de 2026-09-10.)

-- current_date usa o fuso da sessao do Postgres, que em projetos Supabase
-- e UTC por padrao -- uma edicao feita entre ~21h e 23h59 (horario de
-- Brasilia, UTC-3) ja cairia no "dia seguinte" em UTC, deslocando a
-- fronteira do snapshot diario em ate 3h em relacao ao expediente real da
-- equipe (achado real de auditoria, 2026-09-10). Usa o fuso de Brasilia
-- explicitamente em vez de depender do fuso da sessao.
create table if not exists public.cronograma_state_history (
  id bigserial primary key,
  state_id int not null,
  data jsonb not null,
  snapshot_date date not null default ((now() at time zone 'America/Sao_Paulo')::date),
  snapshot_hour timestamptz not null default date_trunc('hour', now()),
  created_at timestamptz not null default now(),
  unique (state_id, snapshot_hour)
);

-- MIGRACAO (2026-09-10): troca a granularidade de "1 backup por dia" pra
-- "1 backup por hora-relogio" -- reduz a maior perda possivel de ~1 dia
-- de trabalho pra ~1 hora, crescendo no maximo 24 linhas/dia (poucas
-- centenas de KB). So faz alguma coisa se a tabela ja existia de uma
-- rodada anterior (sem a coluna snapshot_hour); em uma instalacao nova a
-- tabela ja nasce certa, acima, e os comandos abaixo nao encontram nada
-- pra alterar.
alter table public.cronograma_state_history
  add column if not exists snapshot_hour timestamptz;
update public.cronograma_state_history
  set snapshot_hour = date_trunc('hour', created_at)
  where snapshot_hour is null;
alter table public.cronograma_state_history
  alter column snapshot_hour set not null;
alter table public.cronograma_state_history
  alter column snapshot_hour set default date_trunc('hour', now());
-- remove a trava antiga de "1x por dia" -- procura pelo nome real da
-- constraint em vez de adivinhar (o Postgres gera esse nome sozinho),
-- pra nao arriscar deixar a trava velha ativa por engano: se ela
-- continuasse ali, o 2o backup de cada dia falharia com erro de banco e
-- destruiria (por estar num gatilho BEFORE) o UPDATE/DELETE junto.
do $$
declare
  conname text;
begin
  select con.conname into conname
  from pg_constraint con
  join pg_class rel on rel.oid = con.conrelid
  where rel.relname = 'cronograma_state_history'
    and con.contype = 'u'
    and pg_get_constraintdef(con.oid) like '%snapshot_date%';
  if conname is not null then
    execute format('alter table public.cronograma_state_history drop constraint %I', conname);
  end if;
end $$;
alter table public.cronograma_state_history
  drop constraint if exists cronograma_state_history_state_id_snapshot_hour_key;
alter table public.cronograma_state_history
  add constraint cronograma_state_history_state_id_snapshot_hour_key unique (state_id, snapshot_hour);

alter table public.cronograma_state_history enable row level security;

drop policy if exists "authenticated can read history" on public.cronograma_state_history;
create policy "authenticated can read history" on public.cronograma_state_history
  for select using (auth.role() = 'authenticated');

-- IMPORTANTE (achado real de auditoria, 2026-09-10): a versao anterior
-- desta funcao sempre terminava com "return new" -- mas em contexto de
-- DELETE, NEW e NULL, e um gatilho BEFORE ROW que devolve NULL CANCELA a
-- operacao pra aquela linha (comportamento documentado do Postgres). Ou
-- seja, o gatilho de DELETE criado mais abaixo nunca de fato excluia a
-- linha: virava um no-op silencioso (o UPDATE continuava funcionando
-- normalmente, so o DELETE que ficava neutralizado). Corrigido pra
-- devolver OLD em contexto de DELETE.
create or replace function public.cronograma_snapshot_before_write()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.cronograma_state_history(state_id, data, snapshot_date, snapshot_hour)
  values (old.id, old.data, (now() at time zone 'America/Sao_Paulo')::date, date_trunc('hour', now()))
  on conflict (state_id, snapshot_hour) do nothing;
  if TG_OP = 'DELETE' then
    return old;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_cronograma_snapshot on public.cronograma_state;
create trigger trg_cronograma_snapshot
  before update on public.cronograma_state
  for each row execute function public.cronograma_snapshot_before_write();

-- O app nunca deleta essa linha (so usa upsert), e nao ha policy de RLS de
-- DELETE pro papel 'authenticated' -- entao esse caminho ja esta bloqueado
-- pela API publica. Mas o SQL Editor do Supabase Dashboard roda como
-- 'postgres' e ignora RLS: um DELETE manual feito por ali (ex: alguem
-- tentando "resetar" o cronograma) passaria batido pelo gatilho de UPDATE.
-- Esse segundo gatilho cobre esse caso tambem. (TRUNCATE continua fora do
-- alcance -- Postgres nao dispara gatilho por linha nesse caso -- mas e
-- uma acao rara e deliberada, nao um caminho que o app usa.)
drop trigger if exists trg_cronograma_snapshot_delete on public.cronograma_state;
create trigger trg_cronograma_snapshot_delete
  before delete on public.cronograma_state
  for each row execute function public.cronograma_snapshot_before_write();
