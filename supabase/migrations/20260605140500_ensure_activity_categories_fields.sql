create extension if not exists pgcrypto with schema extensions;

create table if not exists public.activity_categories (
  id uuid primary key default extensions.gen_random_uuid(),
  slug text not null unique,
  title text not null,
  background_color text not null default '#eef2ff',
  foreground_color text not null default '#111827',
  icon_key text not null
);

alter table public.activity_categories
  add column if not exists slug text,
  add column if not exists title text,
  add column if not exists background_color text default '#eef2ff',
  add column if not exists foreground_color text default '#111827',
  add column if not exists icon_key text;

update public.activity_categories
set
  slug = coalesce(nullif(slug, ''), 'category-' || id::text),
  title = coalesce(nullif(title, ''), 'Categorie'),
  background_color = coalesce(nullif(background_color, ''), '#eef2ff'),
  foreground_color = coalesce(nullif(foreground_color, ''), '#111827'),
  icon_key = coalesce(nullif(icon_key, ''), 'tag');

alter table public.activity_categories
  alter column slug set not null,
  alter column title set not null,
  alter column background_color set not null,
  alter column foreground_color set not null,
  alter column icon_key set not null;

create unique index if not exists activity_categories_slug_key
  on public.activity_categories (slug);

grant select on table public.activity_categories to authenticated;

notify pgrst, 'reload schema';
