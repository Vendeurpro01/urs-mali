-- =====================================================================
-- URS Mali · Closing des commandes de la boutique en ligne (PROWIN STORES)
-- À exécuter dans l'éditeur SQL de Supabase. Peut être relancé sans rien casser.
--
-- Circuit :
--   PROWIN STORES envoie la commande (fonction prowin_commande, protégée par un code secret)
--   → statut « closing », état « disponible » : tous les vendeurs la voient et sont notifiés
--   → le premier vendeur qui appuie sur « Prendre » l'a (en_cours)
--   → il appelle le client puis : valider (part chez les livreurs), à relancer, rejeter (reprenable par tous), annuler
--   → une commande prise sans suite pendant N minutes (30 par défaut) redevient disponible pour les autres
--   PROWIN STORES récupère les changements (fonction prowin_statuts) pour mettre ses commandes à jour.
-- Les ventes saisies par les vendeurs ne changent pas.
-- =====================================================================

-- ------------------------------------------------------------------ Colonnes
alter table public.commandes add column if not exists source text not null default 'vendeur';
alter table public.commandes add column if not exists ext_ref text;
alter table public.commandes add column if not exists ext_numero text;
alter table public.commandes add column if not exists closing text;
alter table public.commandes add column if not exists closing_le timestamptz;
alter table public.commandes add column if not exists relance_le timestamptz;
alter table public.commandes add column if not exists rejets jsonb not null default '[]'::jsonb;
alter table public.commandes alter column vendeur_id drop not null; -- une commande en ligne n'a pas de vendeur tant que personne ne l'a prise
-- Le statut « closing » s'ajoute aux statuts des ventes (contrainte d'origine : nouvelle → annulee)
alter table public.commandes drop constraint if exists commandes_statut_check;
alter table public.commandes add constraint commandes_statut_check
  check (statut = any (array['nouvelle', 'prise', 'en_route', 'livree', 'echec', 'annulee', 'closing']));
create unique index if not exists commandes_source_ext_ref_uq on public.commandes (source, ext_ref) where ext_ref is not null;
create index if not exists commandes_closing_idx on public.commandes (closing) where statut = 'closing';
create index if not exists commandes_source_maj_idx on public.commandes (source, maj_le);

-- ------------------------------------------------------------------ Délai avant qu'une commande prise redevienne disponible
create or replace function public.closing_minutes() returns integer
language sql stable security definer set search_path to 'public' as $$
select coalesce((select case when (data ->> 'closingMinutes') ~ '^[0-9]+$' then greatest(5, (data ->> 'closingMinutes')::int) end
  from public.docs where collection = 'config' and id = 'main'), 30)
$$;

-- ------------------------------------------------------------------ Création d'une commande (vendeur ou boutique en ligne)
create or replace function public.commande_avant_ajout() returns trigger
language plpgsql security definer set search_path to 'public' as $function$
begin
if jsonb_typeof(new.articles) <> 'array' or jsonb_array_length(new.articles) = 0 then raise exception 'Ajoutez au moins un produit'; end if;
if length(regexp_replace(coalesce(new.client_tel, ''), '\D', '', 'g')) < 8 then raise exception 'Numéro du client manquant'; end if;
new.cree_le := now(); new.maj_le := now();
new.livreur_id := null; new.pris_le := null; new.livre_le := null;
new.uexpress_statut := null; new.uexpress_ref := null; new.uexpress_le := null;
new.montant := coalesce((select sum(coalesce((a ->> 'qte')::numeric, 0) * coalesce((a ->> 'prix')::numeric, 0)) from jsonb_array_elements(new.articles) a), 0);
new.messages := '[]'::jsonb;
new.rejets := '[]'::jsonb; new.relance_le := null;
if coalesce(current_setting('urs.import_prowin', true), '') = '1' then
  -- Commande de la boutique en ligne (uniquement via prowin_commande) : à closer par un vendeur
  new.source := 'prowin'; new.vendeur_id := null;
  new.statut := 'closing'; new.closing := 'disponible'; new.closing_le := now();
  new.historique := jsonb_build_array(jsonb_build_object('action', 'creer', 'statut', 'closing', 'par', null, 'le', now(), 'texte', 'Commande en ligne n°' || coalesce(new.ext_numero, '')));
else
  new.source := 'vendeur'; new.ext_ref := null; new.ext_numero := null; new.closing := null; new.closing_le := null;
  new.vendeur_id := auth.uid();
  new.statut := 'nouvelle';
  new.historique := jsonb_build_array(jsonb_build_object('action', 'creer', 'statut', 'nouvelle', 'par', auth.uid(), 'le', now()));
end if;
return new;
end $function$;

-- ------------------------------------------------------------------ Notification à la création
create or replace function public.notif_commande_ajout() returns trigger
language plpgsql security definer set search_path to 'public' as $function$
declare
tot text := public.fmt_f(new.montant + new.frais_livraison);
cli text := coalesce(nullif(trim(new.client_prenom || ' ' || new.client_nom), ''), 'Client');
begin
if new.statut = 'closing' then
  perform public.notifier(public.ids_role('vendeur'), 'closing', 'Nouvelle commande à closer #' || new.numero,
    cli || ' · ' || new.destination || ' · ' || tot || ' · le premier qui la prend la close', new.id, 'closing');
  perform public.notifier(public.ids_role('pdg', 'coordo'), 'vente', 'Commande en ligne #' || new.numero || ' · ' || tot,
    cli || ' · ' || new.destination || ' · en attente d''un vendeur', new.id, 'closing');
  return null;
end if;
perform public.notifier(public.ids_role('livreur'), 'course', 'Nouvelle course #' || new.numero,
new.destination || coalesce(', ' || nullif(new.ville, ''), '') || ' · ' || tot || ' à encaisser', new.id);
perform public.notifier(public.ids_role('pdg', 'coordo'), 'vente', 'Nouvelle vente #' || new.numero || ' · ' || tot,
coalesce(public.nom_membre(new.vendeur_id), 'Vendeur') || ' · ' || cli || ' · ' || new.destination, new.id);
return null;
end $function$;

-- ------------------------------------------------------------------ Notifications aux changements (version d'origine + closing)
create or replace function public.notif_commande_maj() returns trigger
language plpgsql security definer set search_path to 'public' as $function$
declare
num text := '#' || new.numero;
tot text := public.fmt_f(new.montant + new.frais_livraison);
cli text := coalesce(nullif(trim(new.client_prenom || ' ' || new.client_nom), ''), 'Client');
liv text := coalesce(public.nom_membre(new.livreur_id), 'le livreur');
acteur text := coalesce(public.nom_membre(auth.uid()), 'Quelqu''un');
n_old int := jsonb_array_length(coalesce(old.historique, '[]'::jsonb));
h jsonb;
m jsonb;
begin
if new.statut is distinct from old.statut then
if old.statut = 'closing' and new.statut = 'nouvelle' then
-- Commande en ligne validée par le vendeur : elle part chez les livreurs
perform public.notifier(public.ids_role('livreur'), 'course', 'Nouvelle course #' || new.numero,
new.destination || coalesce(', ' || nullif(new.ville, ''), '') || ' · ' || tot || ' à encaisser', new.id);
perform public.notifier(public.ids_role('pdg', 'coordo'), 'vente', 'Commande en ligne ' || num || ' validée · ' || tot,
'Closée par ' || coalesce(public.nom_membre(new.vendeur_id), 'un vendeur') || ' · ' || cli, new.id);
elsif old.statut = 'closing' and new.statut = 'annulee' then
perform public.notifier(public.ids_role('pdg', 'coordo'), 'annulee', 'Commande en ligne ' || num || ' annulée',
'Par ' || acteur || ' · ' || cli || coalesce(' · ' || nullif(new.motif, ''), ''), new.id, 'closing');
elsif new.statut = 'prise' then
perform public.notifier(array[new.vendeur_id], 'prise', 'Vente ' || num || ' prise en charge', 'Par ' || liv || ' · ' || cli, new.id);
if new.livreur_id is distinct from auth.uid() then
perform public.notifier(array[new.livreur_id], 'attribuee', 'Course ' || num || ' attribuée à toi', new.destination || ' · ' || tot || ' à encaisser', new.id);
end if;
elsif new.statut = 'en_route' then
perform public.notifier(array[new.vendeur_id], 'en_route', 'Vente ' || num || ' en route', liv || ' est en route vers ' || cli, new.id);
elsif new.statut = 'livree' then
perform public.notifier(array[new.vendeur_id], 'livree', 'Vente ' || num || ' livrée', 'Par ' || liv || ' · ta commission est acquise', new.id);
perform public.notifier(public.ids_role('pdg', 'coordo'), 'livree', 'Vente ' || num || ' livrée · ' || tot,
'Par ' || liv || ' · vendeur ' || coalesce(public.nom_membre(new.vendeur_id), ''), new.id);
elsif new.statut = 'echec' then
perform public.notifier(array[new.vendeur_id] || public.ids_role('pdg', 'coordo'), 'echec', 'Échec de la vente ' || num,
coalesce(new.motif, '') || ' · ' || liv, new.id);
elsif new.statut = 'annulee' then
perform public.notifier(array[old.livreur_id, new.vendeur_id], 'annulee', 'Vente ' || num || ' annulée', 'Par ' || acteur || ' · ' || cli, new.id);
elsif new.statut = 'nouvelle' then
perform public.notifier(public.ids_role('livreur'), 'course', 'Course ' || num || ' de nouveau disponible',
new.destination || ' · ' || tot || ' à encaisser', new.id);
end if;
end if;

-- Closing : commande rejetée par un vendeur → les autres vendeurs peuvent la reprendre
if new.statut = 'closing' and new.closing is distinct from old.closing and new.closing = 'rejetee' then
perform public.notifier(public.ids_role('vendeur'), 'closing', 'Commande ' || num || ' rejetée : à reprendre',
'Rejetée par ' || acteur || coalesce(' · ' || nullif(new.rejets -> -1 ->> 'motif', ''), '') || ' · ' || cli || ' · ' || tot, new.id, 'closing');
end if;

-- Vente modifiée : le livreur (et le vendeur si quelqu'un d'autre a modifié)
if jsonb_array_length(coalesce(new.historique, '[]'::jsonb)) > n_old then
for h in select e.value from jsonb_array_elements(new.historique) with ordinality e(value, i) where e.i > n_old loop
if h ->> 'action' = 'modifier' then
perform public.notifier(array[new.livreur_id, new.vendeur_id], 'modifiee', 'Vente ' || num || ' modifiée',
'Par ' || acteur || ' · ouvre la course pour voir les changements', new.id);
end if;
end loop;
end if;

-- Nouveau message dans la vente
if jsonb_array_length(coalesce(new.messages, '[]'::jsonb)) > jsonb_array_length(coalesce(old.messages, '[]'::jsonb)) then
m := new.messages -> (jsonb_array_length(new.messages) - 1);
perform public.notifier(array[new.vendeur_id, new.livreur_id], 'message', 'Message · vente ' || num,
acteur || ' : ' || left(coalesce(m ->> 'texte', ''), 160), new.id);
end if;
return null;
end $function$;

-- ------------------------------------------------------------------ Qui voit quoi
drop policy if exists commandes_lire on public.commandes;
create policy commandes_lire on public.commandes for select to authenticated using (
  public.mon_role() in ('pdg', 'coordo')
  or (public.mon_role() = 'vendeur' and (
       vendeur_id = auth.uid()
       or (statut = 'closing' and closing in ('disponible', 'rejetee'))
       or (statut = 'closing' and closing = 'en_cours' and closing_le < now() - make_interval(mins => public.closing_minutes()))))
  or (public.mon_role() = 'livreur' and (livreur_id = auth.uid() or (statut = 'nouvelle' and livreur_id is null)))
);

-- ------------------------------------------------------------------ Actions du vendeur dans l'espace closing
create or replace function public.closing_action(p_id uuid, p_action text, p_texte text default '', p_relance timestamptz default null)
returns void language plpgsql security definer set search_path to 'public' as $function$
declare
c public.commandes;
r text := public.mon_role();
me uuid := auth.uid();
chef boolean := public.mon_role() in ('pdg', 'coordo');
txt text := left(trim(coalesce(p_texte, '')), 500);
expire boolean;
nv text;
tot numeric; det jsonb;
begin
if me is null then raise exception 'Connexion requise'; end if;
if not (r = 'vendeur' or chef) then raise exception 'Réservé aux vendeurs'; end if;
select * into c from public.commandes where id = p_id for update;
if not found or c.source <> 'prowin' then raise exception 'Commande introuvable'; end if;
if c.statut <> 'closing' then raise exception 'Cette commande n''est plus en closing'; end if;
expire := c.closing = 'en_cours' and c.closing_le < now() - make_interval(mins => public.closing_minutes());

if p_action = 'prendre' then
  if not (c.closing in ('disponible', 'rejetee') or (expire and c.vendeur_id is distinct from me)) then
    raise exception 'Déjà prise par %', coalesce(public.nom_membre(c.vendeur_id), 'un autre vendeur');
  end if;
  update public.commandes set vendeur_id = me, closing = 'en_cours', closing_le = now(), relance_le = null where id = p_id;
  nv := 'en_cours';
else
  if c.closing not in ('en_cours', 'a_relancer') then raise exception 'Prends d''abord la commande'; end if;
  if not (c.vendeur_id = me or chef) then raise exception 'Cette commande est suivie par %', coalesce(public.nom_membre(c.vendeur_id), 'un autre vendeur'); end if;
  if p_action = 'relancer' then
    update public.commandes set closing = 'a_relancer', closing_le = now(),
      relance_le = coalesce(p_relance, now() + interval '1 hour') where id = p_id;
    nv := 'a_relancer';
  elsif p_action = 'valider' then
    -- Le client a confirmé : la vente part chez les livreurs, la commission du vendeur est en attente de livraison
    update public.commandes set statut = 'nouvelle', closing = 'validee', closing_le = now(), relance_le = null, cree_le = now() where id = p_id;
    if (select role from public.membres where id = c.vendeur_id) = 'vendeur' then
      select x.total, x.details into tot, det from public.calcul_commission(c.articles) x;
      if tot > 0 then
        insert into public.gains (commande_id, membre_id, type, montant, details, statut)
        values (c.id, c.vendeur_id, 'commission', tot, det, 'attente')
        on conflict (commande_id, type) do nothing;
      end if;
    end if;
    nv := 'validee';
  elsif p_action = 'rejeter' then
    update public.commandes set vendeur_id = null, closing = 'rejetee', closing_le = now(), relance_le = null,
      rejets = rejets || jsonb_build_array(jsonb_build_object('par', me, 'nom', public.nom_membre(me), 'le', now(), 'motif', nullif(txt, '')))
    where id = p_id;
    nv := 'rejetee';
  elsif p_action = 'annuler' then
    if txt = '' then raise exception 'Indique pourquoi le client ne veut pas la commande'; end if;
    update public.commandes set statut = 'annulee', closing = 'annulee', closing_le = now(), relance_le = null, motif = txt where id = p_id;
    nv := 'annulee';
  else
    raise exception 'Action inconnue';
  end if;
end if;

update public.commandes
set historique = historique || jsonb_build_array(jsonb_build_object('action', 'closing_' || p_action, 'statut', nv, 'par', me, 'le', now(),
      'texte', nullif(txt, ''), 'relance', case when nv = 'a_relancer' then coalesce(p_relance, now() + interval '1 hour') end)),
    maj_le = now()
where id = p_id;
end $function$;
revoke all on function public.closing_action(uuid, text, text, timestamptz) from public, anon;
grant execute on function public.closing_action(uuid, text, text, timestamptz) to authenticated;

-- ------------------------------------------------------------------ Entrée des commandes PROWIN STORES (code secret obligatoire)
create or replace function public.prowin_commande(p_secret text, p_cmd jsonb) returns jsonb
language plpgsql security definer set search_path to 'public' as $function$
declare
sec text;
ex record;
arts jsonb;
nid uuid; n bigint;
begin
select valeur into sec from public.secrets where cle = 'prowin_secret';
if sec is null or coalesce(p_secret, '') = '' or p_secret <> sec then raise exception 'Accès refusé'; end if;
if coalesce(p_cmd ->> 'ref', '') = '' then raise exception 'Référence de commande manquante'; end if;
select id, numero into ex from public.commandes where source = 'prowin' and ext_ref = p_cmd ->> 'ref';
if found then return jsonb_build_object('id', ex.id, 'numero', ex.numero, 'deja', true); end if;
-- Produits : même identifiant PROWIN (champ prowinId du produit) ou même nom que dans le catalogue URS Mali
select jsonb_agg(jsonb_build_object(
  'produitId', (select d.id from public.docs d where d.collection = 'produits'
                 and (d.data ->> 'prowinId' = i ->> 'productId' or lower(trim(d.data ->> 'nom')) = lower(trim(i ->> 'title')))
                 order by (d.data ->> 'prowinId' = i ->> 'productId') desc nulls last limit 1),
  'nom', left(coalesce(i ->> 'title', 'Produit') || coalesce(' (' || nullif(i ->> 'variant', '') || ')', ''), 200),
  'qte', greatest(1, coalesce((i ->> 'quantity')::numeric, 1)),
  'prix', greatest(0, coalesce((i ->> 'unitPrice')::numeric, 0))))
into arts from jsonb_array_elements(coalesce(p_cmd -> 'items', '[]'::jsonb)) i;
perform set_config('urs.import_prowin', '1', true);
insert into public.commandes (client_nom, client_tel, destination, ville, articles, frais_livraison, note, ext_ref, ext_numero)
values (left(coalesce(nullif(trim(p_cmd ->> 'customerName'), ''), 'Client'), 120), left(coalesce(p_cmd ->> 'phone', ''), 40),
  left(coalesce(nullif(trim(p_cmd ->> 'address'), ''), nullif(trim(p_cmd ->> 'city'), ''), 'À préciser au téléphone'), 300),
  left(coalesce(nullif(trim(p_cmd ->> 'city'), ''), ''), 80), coalesce(arts, '[]'::jsonb),
  greatest(0, coalesce((p_cmd ->> 'deliveryFee')::numeric, 0)), left(coalesce(p_cmd ->> 'note', ''), 1000),
  p_cmd ->> 'ref', left(coalesce(p_cmd ->> 'number', ''), 40))
returning id, numero into nid, n;
perform set_config('urs.import_prowin', '', true);
return jsonb_build_object('id', nid, 'numero', n, 'deja', false);
end $function$;
revoke all on function public.prowin_commande(text, jsonb) from public;
grant execute on function public.prowin_commande(text, jsonb) to anon, authenticated;

-- ------------------------------------------------------------------ Retour des statuts vers PROWIN STORES
create or replace function public.prowin_statuts(p_secret text, p_depuis timestamptz default null)
returns table (ref text, numero bigint, statut text, closing text, vendeur text, vendeur_tel text, motif text, maj_le timestamptz)
language plpgsql stable security definer set search_path to 'public' as $function$
declare sec text;
begin
select valeur into sec from public.secrets where cle = 'prowin_secret';
if sec is null or coalesce(p_secret, '') = '' or p_secret <> sec then raise exception 'Accès refusé'; end if;
return query
select c.ext_ref, c.numero, c.statut, c.closing, public.nom_membre(c.vendeur_id), m.tel, c.motif, c.maj_le
from public.commandes c left join public.membres m on m.id = c.vendeur_id
where c.source = 'prowin' and c.maj_le > coalesce(p_depuis, '-infinity'::timestamptz)
order by c.maj_le
limit 300;
end $function$;
revoke all on function public.prowin_statuts(text, timestamptz) from public;
grant execute on function public.prowin_statuts(text, timestamptz) to anon, authenticated;

-- ------------------------------------------------------------------ Code secret de connexion (à recopier dans PROWIN STORES)
-- Créé automatiquement une seule fois (64 caractères aléatoires), jamais remplacé par une nouvelle exécution.
insert into public.secrets (cle, valeur)
values ('prowin_secret', replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', ''))
on conflict (cle) do nothing;

-- Le PDG le lit dans l'application (Closing en ligne → « Code de connexion PROWIN ») pour le coller dans PROWIN STORES.
create or replace function public.prowin_code() returns text
language plpgsql stable security definer set search_path to 'public' as $function$
begin
if coalesce(public.mon_role(), '') <> 'pdg' then raise exception 'Réservé au PDG'; end if;
return (select valeur from public.secrets where cle = 'prowin_secret');
end $function$;
revoke all on function public.prowin_code() from public;
grant execute on function public.prowin_code() to authenticated;
