-- Reconstitution locale minimale de la base URS Mali (Supabase) pour tester la migration closing.
drop schema if exists public cascade; create schema public;
drop schema if exists auth cascade; create schema auth;
create extension if not exists pgcrypto;
do $$ begin
  if not exists (select 1 from pg_roles where rolname='anon') then create role anon nologin; end if;
  if not exists (select 1 from pg_roles where rolname='authenticated') then create role authenticated nologin; end if;
end $$;
grant usage on schema public, auth to anon, authenticated;
create table auth.users (id uuid primary key);
create or replace function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $$;

create table public.membres (id uuid primary key, role text not null default 'attente', nom text not null default '', tel text not null default '', ville text not null default '', fonction text not null default '', cree_le timestamptz not null default now(), nomme_le timestamptz, nomme_par uuid, role_demande text not null default 'coordo');
create table public.docs (collection text not null, id text not null, data jsonb not null default '{}', maj_le timestamptz not null default now(), maj_par uuid default auth.uid(), primary key (collection, id));
create table public.secrets (cle text primary key, valeur text not null);
create table public.commandes (
  id uuid primary key default gen_random_uuid(), numero bigint generated always as identity, cree_le timestamptz not null default now(),
  vendeur_id uuid not null default auth.uid(), client_prenom text not null default '', client_nom text not null default '', client_tel text not null default '',
  destination text not null default '', ville text not null default 'Bamako', articles jsonb not null default '[]', montant numeric not null default 0,
  frais_livraison numeric not null default 0, note text not null default '', statut text not null default 'nouvelle', livreur_id uuid, pris_le timestamptz,
  livre_le timestamptz, motif text, messages jsonb not null default '[]', historique jsonb not null default '[]', uexpress_statut text, uexpress_ref text,
  uexpress_le timestamptz, maj_le timestamptz not null default now());
create table public.gains (id uuid primary key default gen_random_uuid(), commande_id uuid not null, membre_id uuid not null, type text not null, montant numeric not null default 0, statut text not null default 'attente', details jsonb not null default '[]', cree_le timestamptz not null default now(), acquis_le timestamptz, unique (commande_id, type));
create table public.notifications (id bigint generated always as identity primary key, membre_id uuid not null, type text not null, titre text not null, corps text not null default '', commande_id uuid, lien text, lu boolean not null default false, cree_le timestamptz not null default now());
alter table public.commandes enable row level security; alter table public.notifications enable row level security; alter table public.gains enable row level security;
grant select, insert on public.commandes to authenticated; grant select on public.notifications, public.gains, public.membres to authenticated;

create or replace function public.mon_role() returns text language sql stable security definer set search_path to 'public' as $$
select coalesce((select role from public.membres where id = auth.uid()), 'aucun') $$;
create or replace function public.ids_role(variadic p_roles text[]) returns uuid[] language sql stable security definer set search_path to 'public' as $$
select coalesce(array_agg(id), '{}') from public.membres where role = any(p_roles) $$;
create or replace function public.nom_membre(p_id uuid) returns text language sql stable security definer set search_path to 'public' as $$
select nullif(nom, '') from public.membres where id = p_id $$;
create or replace function public.fmt_f(x numeric) returns text language sql immutable as $$ select to_char(round(coalesce(x,0)), 'FM999G999G999') || ' F' $$;
create or replace function public.notifier(p_ids uuid[], p_type text, p_titre text, p_corps text, p_commande uuid DEFAULT NULL::uuid, p_lien text DEFAULT NULL::text)
RETURNS void LANGUAGE sql SECURITY DEFINER SET search_path TO 'public' AS $function$
insert into public.notifications (membre_id, type, titre, corps, commande_id, lien)
select d.u, p_type, left(p_titre, 160), left(coalesce(p_corps, ''), 400), p_commande, p_lien
from (select distinct u from unnest(p_ids) u) d
join public.membres m on m.id = d.u and m.role in ('pdg', 'coordo', 'vendeur', 'livreur')
where d.u is distinct from auth.uid()
$function$;
create or replace function public.tarif_livraison() returns numeric language sql stable security definer set search_path to 'public' as $$ select 1000::numeric $$;
CREATE OR REPLACE FUNCTION public.calcul_commission(p_articles jsonb, OUT total numeric, OUT details jsonb)
RETURNS record LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $function$
select coalesce(sum(x.qte * x.com), 0),
coalesce(jsonb_agg(jsonb_build_object('produitId', x.pid, 'nom', x.nom, 'qte', x.qte, 'commission', x.com)), '[]'::jsonb)
from (
select a ->> 'produitId' as pid, a ->> 'nom' as nom,
coalesce(case when (a ->> 'qte') ~ '^[0-9]+(\.[0-9]+)?$' then (a ->> 'qte')::numeric end, 0) as qte,
coalesce((select case when (d.data ->> 'commission') ~ '^[0-9]+(\.[0-9]+)?$' then (d.data ->> 'commission')::numeric end
from public.docs d where d.collection = 'produits' and d.id = a ->> 'produitId'), 0) as com
from jsonb_array_elements(case when jsonb_typeof(p_articles) = 'array' then p_articles else '[]'::jsonb end) a
) x
$function$;

CREATE OR REPLACE FUNCTION public.commande_avant_ajout() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
begin
if jsonb_typeof(new.articles) <> 'array' or jsonb_array_length(new.articles) = 0 then raise exception 'Ajoutez au moins un produit'; end if;
if length(regexp_replace(coalesce(new.client_tel, ''), '\D', '', 'g')) < 8 then raise exception 'Numéro du client manquant'; end if;
new.vendeur_id := auth.uid();
new.cree_le := now(); new.maj_le := now();
new.statut := 'nouvelle'; new.livreur_id := null; new.pris_le := null; new.livre_le := null;
new.uexpress_statut := null; new.uexpress_ref := null; new.uexpress_le := null;
new.montant := coalesce((select sum(coalesce((a ->> 'qte')::numeric, 0) * coalesce((a ->> 'prix')::numeric, 0)) from jsonb_array_elements(new.articles) a), 0);
new.messages := '[]'::jsonb;
new.historique := jsonb_build_array(jsonb_build_object('action', 'creer', 'statut', 'nouvelle', 'par', auth.uid(), 'le', now()));
return new;
end $function$;

CREATE OR REPLACE FUNCTION public.commande_apres_ajout() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
declare tot numeric; det jsonb;
begin
if (select role from public.membres where id = new.vendeur_id) = 'vendeur' then
select c.total, c.details into tot, det from public.calcul_commission(new.articles) c;
if tot > 0 then
insert into public.gains (commande_id, membre_id, type, montant, details, statut)
values (new.id, new.vendeur_id, 'commission', tot, det, 'attente')
on conflict (commande_id, type) do nothing;
end if;
end if;
return null;
end $function$;

CREATE OR REPLACE FUNCTION public.commande_apres_maj() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
begin
if new.statut is not distinct from old.statut then return null; end if;
if new.statut = 'livree' then
update public.gains set statut = 'acquis', acquis_le = now() where commande_id = new.id and type = 'commission' and statut <> 'acquis';
if new.livreur_id is not null then
insert into public.gains (commande_id, membre_id, type, montant, statut, acquis_le)
values (new.id, new.livreur_id, 'livraison', public.tarif_livraison(), 'acquis', now())
on conflict (commande_id, type) do nothing;
end if;
elsif new.statut in ('echec', 'annulee') then
update public.gains set statut = 'annule' where commande_id = new.id and type = 'commission' and statut = 'attente';
elsif new.statut = 'nouvelle' and old.statut in ('echec', 'annulee') then
update public.gains set statut = 'attente' where commande_id = new.id and type = 'commission' and statut = 'annule';
end if;
return null;
end $function$;

CREATE OR REPLACE FUNCTION public.notif_commande_ajout() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
declare
tot text := public.fmt_f(new.montant + new.frais_livraison);
cli text := coalesce(nullif(trim(new.client_prenom || ' ' || new.client_nom), ''), 'Client');
begin
perform public.notifier(public.ids_role('livreur'), 'course', 'Nouvelle course #' || new.numero,
new.destination || coalesce(', ' || nullif(new.ville, ''), '') || ' · ' || tot || ' à encaisser', new.id);
perform public.notifier(public.ids_role('pdg', 'coordo'), 'vente', 'Nouvelle vente #' || new.numero || ' · ' || tot,
coalesce(public.nom_membre(new.vendeur_id), 'Vendeur') || ' · ' || cli || ' · ' || new.destination, new.id);
return null;
end $function$;

CREATE OR REPLACE FUNCTION public.commande_action(p_id uuid, p_action text, p_texte text DEFAULT ''::text, p_livreur uuid DEFAULT NULL::uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
declare c public.commandes; r text := public.mon_role(); me uuid := auth.uid(); chef boolean := public.mon_role() in ('pdg', 'coordo'); st text; txt text := trim(coalesce(p_texte, ''));
begin
if me is null then raise exception 'Connexion requise'; end if;
select * into c from public.commandes where id = p_id for update;
if not found then raise exception 'Vente introuvable'; end if;
st := c.statut;
if p_action = 'prendre' then
if r <> 'livreur' then raise exception 'Réservé aux livreurs'; end if;
if c.statut <> 'nouvelle' or c.livreur_id is not null then raise exception 'Cette course a déjà été prise'; end if;
update public.commandes set statut = 'prise', livreur_id = me, pris_le = now() where id = p_id; st := 'prise';
elsif p_action = 'en_route' then
if not ((r = 'livreur' and c.livreur_id = me) or chef) then raise exception 'Action non autorisée'; end if;
if c.statut <> 'prise' then raise exception 'La course doit d''abord être prise'; end if;
update public.commandes set statut = 'en_route' where id = p_id; st := 'en_route';
elsif p_action = 'livree' then
if not ((r = 'livreur' and c.livreur_id = me) or chef) then raise exception 'Action non autorisée'; end if;
if c.statut not in ('prise', 'en_route') then raise exception 'La course doit d''abord être prise'; end if;
update public.commandes set statut = 'livree', livre_le = now(), motif = null where id = p_id; st := 'livree';
elsif p_action = 'echec' then
if not ((r = 'livreur' and c.livreur_id = me) or chef) then raise exception 'Action non autorisée'; end if;
if c.statut not in ('prise', 'en_route') then raise exception 'La course doit d''abord être prise'; end if;
if txt = '' then raise exception 'Indiquez le motif de l''échec'; end if;
update public.commandes set statut = 'echec', motif = txt where id = p_id; st := 'echec';
else raise exception 'Action inconnue (version locale de test)';
end if;
update public.commandes set historique = historique || jsonb_build_array(jsonb_build_object('action', p_action, 'statut', st, 'par', me, 'le', now(), 'texte', nullif(txt, ''), 'livreur', p_livreur)), maj_le = now() where id = p_id;
end $function$;

-- notif_commande_maj d'origine (production)
CREATE OR REPLACE FUNCTION public.notif_commande_maj() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
declare num text := '#' || new.numero; tot text := public.fmt_f(new.montant + new.frais_livraison);
cli text := coalesce(nullif(trim(new.client_prenom || ' ' || new.client_nom), ''), 'Client'); liv text := coalesce(public.nom_membre(new.livreur_id), 'le livreur');
begin
if new.statut is distinct from old.statut then
if new.statut = 'prise' then perform public.notifier(array[new.vendeur_id], 'prise', 'Vente ' || num || ' prise en charge', 'Par ' || liv || ' · ' || cli, new.id);
elsif new.statut = 'nouvelle' then perform public.notifier(public.ids_role('livreur'), 'course', 'Course ' || num || ' de nouveau disponible', new.destination || ' · ' || tot || ' à encaisser', new.id);
end if;
end if;
return null;
end $function$;

create policy commandes_ajouter on public.commandes for insert to authenticated with check (mon_role() = any (array['pdg','coordo','vendeur']));
create policy commandes_lire on public.commandes for select to authenticated using ((mon_role() = any (array['pdg','coordo'])) or ((mon_role() = 'vendeur') and (vendeur_id = auth.uid())) or ((mon_role() = 'livreur') and ((livreur_id = auth.uid()) or ((statut = 'nouvelle') and (livreur_id is null)))));
create policy notifications_lire on public.notifications for select to authenticated using (membre_id = auth.uid());
create policy gains_lire on public.gains for select to authenticated using (membre_id = auth.uid() or mon_role() in ('pdg','coordo'));
create trigger commande_avant_ajout before insert on public.commandes for each row execute function commande_avant_ajout();
create trigger commande_apres_ajout after insert on public.commandes for each row execute function commande_apres_ajout();
create trigger commande_apres_maj after update of statut on public.commandes for each row execute function commande_apres_maj();
create trigger notif_commande_ajout after insert on public.commandes for each row execute function notif_commande_ajout();
create trigger notif_commande_maj after update on public.commandes for each row execute function notif_commande_maj();

-- Données de test
insert into public.membres (id, role, nom, tel) values
 ('00000000-0000-0000-0000-000000000001', 'pdg', 'Yannick PDG', '22675490747'),
 ('00000000-0000-0000-0000-0000000000a1', 'vendeur', 'Awa Vendeuse', '22370000001'),
 ('00000000-0000-0000-0000-0000000000a2', 'vendeur', 'Moussa Vendeur', '22370000002'),
 ('00000000-0000-0000-0000-0000000000b1', 'livreur', 'Issa Livreur', '22370000003');
insert into public.docs (collection, id, data) values
 ('produits', 'p-clim', '{"nom": "Nettoyant Clim (mousse nettoyante pour climatisation) 500 ml", "prixVente": 7000, "commission": 1000, "actif": true}'),
 ('config', 'main', '{}');
