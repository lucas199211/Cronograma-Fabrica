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
