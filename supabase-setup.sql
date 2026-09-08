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
-- Backup automatico diario (independe do app / roda no banco)
-- ============================================================
-- Guarda, uma vez por dia, o estado de como o cronograma estava ANTES da
-- primeira alteracao daquele dia -- ou seja, sempre sobra uma foto do fim
-- do dia anterior. Dispara sozinho a cada UPDATE em cronograma_state,
-- direto no Postgres, entao protege ate contra um bug no painel (como o
-- que causou a perda de 21/08) -- nao depende do JS do app rodar certo.

create table if not exists public.cronograma_state_history (
  id bigserial primary key,
  state_id int not null,
  data jsonb not null,
  snapshot_date date not null default current_date,
  created_at timestamptz not null default now(),
  unique (state_id, snapshot_date)
);

alter table public.cronograma_state_history enable row level security;

drop policy if exists "authenticated can read history" on public.cronograma_state_history;
create policy "authenticated can read history" on public.cronograma_state_history
  for select using (auth.role() = 'authenticated');

create or replace function public.cronograma_snapshot_before_write()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.cronograma_state_history(state_id, data, snapshot_date)
  values (old.id, old.data, current_date)
  on conflict (state_id, snapshot_date) do nothing;
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
